#!/usr/bin/env python3
"""Build the optional Windows/OpenGL DLSS 5 pack from pinned publishers.

Only data is downloaded and extracted. No downloaded installer, DLL or game is
executed. The resulting private pack contains third-party components and is not
the public source release. See README.md for licensing and runtime limits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import struct
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent
USER_AGENT = "hugo-remaster-dlss5-pack/1"


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def checked_path(root: Path, relative: str) -> Path:
    """A lockfile/archive must not write outside the fresh staging directory."""
    name = PurePosixPath(relative)
    if not relative or name.is_absolute() or ".." in name.parts or "\\" in relative or ":" in relative:
        raise ValueError(f"Unsafe relative path: {relative!r}")
    destination = root.joinpath(*name.parts)
    if not destination.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escapes output: {relative!r}")
    return destination


def verify_file(path: Path, expected: dict) -> None:
    if path.stat().st_size != expected["size"]:
        raise ValueError(f"Size mismatch: {path.name}")
    if digest_file(path) != expected["sha256"]:
        raise ValueError(f"SHA-256 mismatch: {path.name}")


def request(url: str):
    if not url.startswith("https://"):
        raise ValueError("Only HTTPS publisher URLs are accepted")
    headers = {"User-Agent": USER_AGENT}
    response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)
    return response


def cached_download(artifact: dict, cache: Path) -> Path:
    path = checked_path(cache, artifact["cache_name"])
    if path.is_file():
        verify_file(path, artifact)
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".partial")
    try:
        with request(artifact["url"]) as source, partial.open("wb") as target:
            received = 0
            while block := source.read(1024 * 1024):
                received += len(block)
                if received > artifact["size"]:
                    raise ValueError("Download exceeds its pinned size")
                target.write(block)
        verify_file(partial, artifact)
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    return path


def inspect_pe(path: Path) -> dict:
    """Read architecture, DLL exports and version resources without loading PE."""
    blob = path.read_bytes()
    if len(blob) < 64 or blob[:2] != b"MZ":
        raise ValueError(f"Not a PE image: {path.name}")
    pe = struct.unpack_from("<I", blob, 0x3C)[0]
    if blob[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE signature: {path.name}")
    machine, count = struct.unpack_from("<HH", blob, pe + 4)
    optional_size = struct.unpack_from("<H", blob, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", blob, optional)[0]
    if machine != 0x8664 or magic != 0x20B:
        raise ValueError(f"Expected Windows x64 PE32+: {path.name}")
    sections = []
    for index in range(count):
        base = optional + optional_size + index * 40
        virtual_size, virtual, raw_size, raw = struct.unpack_from("<4I", blob, base + 8)
        sections.append((virtual, max(virtual_size, raw_size), raw))

    def raw_offset(rva: int) -> int:
        for virtual, size, raw in sections:
            if virtual <= rva < virtual + size:
                value = raw + rva - virtual
                if value >= len(blob):
                    break
                return value
        raise ValueError("PE RVA outside file sections")

    exports = []
    export_rva, _ = struct.unpack_from("<II", blob, optional + 112)
    if export_rva:
        base = raw_offset(export_rva)
        name_count = struct.unpack_from("<I", blob, base + 24)[0]
        table = raw_offset(struct.unpack_from("<I", blob, base + 32)[0])
        if name_count > 65536:
            raise ValueError("Unreasonable PE export count")
        for index in range(name_count):
            name = raw_offset(struct.unpack_from("<I", blob, table + 4 * index)[0])
            end = blob.find(b"\0", name, name + 1024)
            if end < 0:
                raise ValueError("Unterminated PE export name")
            exports.append(blob[name:end].decode("ascii"))
    version = None
    key = "VS_VERSION_INFO\0".encode("utf-16le")
    index = blob.find(key)
    while index >= 0:
        fixed = (index + len(key) + 3) & ~3
        if blob[fixed:fixed + 4] == b"\xbd\x04\xef\xfe":
            major, minor = struct.unpack_from("<II", blob, fixed + 8)
            version = ".".join(str(v) for v in (major >> 16, major & 0xFFFF, minor >> 16, minor & 0xFFFF))
            break
        index = blob.find(key, index + len(key))
    return {"machine": "x86_64", "format": "PE32+", "file_version": version, "exports": exports}


def build(lock: dict, output: Path, cache: Path) -> dict:
    if output.exists():
        raise FileExistsError("Output must be a new directory; existing packs are never overwritten")
    # These authored entrypoints are a contract of the pack, including the
    # optional desktop A/B checker. Do not silently publish a payload built
    # from an older or partial templates directory.
    for relative in lock.get("required_authored_files", []):
        source = checked_path(ROOT / "templates", relative)
        if not source.is_file() or source.is_symlink():
            raise ValueError(f"Missing required authored template: {relative}")
    output.parent.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schema": 1,
        "pack_id": "hugo-dlss5-gitc-opengl-v1",
        "backend": "GITC-Uplift 1.8.0 / external ReShade OpenGL to D3D12 DLSS-NR",
        "hardware_validation": "not_run",
        "model_execution": "not_run",
        "launch_profile": {"user_argument": "--dlss5-profile", "msaa": 4, "render_scale": 1.0},
        "sources": lock["components"],
        "lock_sha256": hashlib.sha256(json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "authored_templates": [],
        "files": [],
        "pe": {},
    }
    with tempfile.TemporaryDirectory(prefix=".dlss5-stage-", dir=output.parent) as temporary:
        stage = Path(temporary)
        payload = stage / "payload"
        payload.mkdir()
        for component in lock["components"]:
            print(f"Preparing {component['id']} ({component['version']})", flush=True)
            artifact = component["artifact"]
            if component["type"] == "zip":
                archive_path = cached_download(artifact, cache)
                with zipfile.ZipFile(archive_path) as archive:
                    for member in component["members"]:
                        destination = checked_path(payload, member["destination"])
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        info = archive.getinfo(member["member"])
                        if info.file_size != member["size"]:
                            raise ValueError("ZIP member size differs from lock")
                        with archive.open(info) as source, destination.open("wb") as target:
                            shutil.copyfileobj(source, target)
                        verify_file(destination, member)
            elif component["type"] == "file":
                source = cached_download(artifact, cache)
                destination = checked_path(payload, component["destination"])
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            else:
                raise ValueError(f"Unknown component format: {component['type']}")
        for source in sorted((ROOT / "templates").iterdir()):
            if not source.is_file() or source.is_symlink():
                raise ValueError(f"Unexpected authored template entry: {source.name}")
            shutil.copy2(source, payload / source.name)
            manifest["authored_templates"].append({"path": source.name, "size": source.stat().st_size,
                                                   "sha256": digest_file(source)})
        shutil.copy2(ROOT / "Install-Hugo-DLSS5.ps1", stage / "Install-Hugo-DLSS5.ps1")
        shutil.copy2(ROOT / "README.md", stage / "README_RU.md")
        for relative, required in lock["required_pe_exports"].items():
            report = inspect_pe(checked_path(payload, relative))
            missing = set(required) - set(report["exports"])
            if missing:
                raise ValueError(f"Missing actual NR/ReShade API exports in {relative}: {sorted(missing)}")
            manifest["pe"][relative] = report
        mutable = {"ReShade.ini", "ReShadePreset_DLSS5.ini"}
        for path in sorted(payload.rglob("*")):
            if path.is_file():
                relative = path.relative_to(payload).as_posix()
                manifest["files"].append({"path": relative, "size": path.stat().st_size, "sha256": digest_file(path), "mutable": relative in mutable})
        (stage / "pack-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        stage.rename(output)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New private pack directory")
    parser.add_argument("--cache", type=Path, required=True, help="Download cache outside public assets")
    args = parser.parse_args()
    lock = json.loads((ROOT / "dependencies.lock.json").read_text(encoding="utf-8"))
    report = build(lock, args.output.resolve(), args.cache.resolve())
    print(json.dumps({"output": str(args.output), "files": len(report["files"]), "hardware_validation": report["hardware_validation"], "model_execution": report["model_execution"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
