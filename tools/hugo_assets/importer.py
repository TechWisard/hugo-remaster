"""Validate, stage, and publish locally supplied original resources."""
from __future__ import annotations

from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import tempfile
from typing import Callable
import uuid

from . import __version__
from .binary import FormatError, require
from .catalog import Catalog
from .gltf import SOURCE_UNIT_SCALE, export_glb, verify_glb
from .mdic import MAX_SOURCE_BYTES, extract, parse_mdic, sha256, write_json
from .mesh import audit_meshes, proof_profile

KNOWN_SOURCES = {
    "fac39256dfdeedc4b19e07c171048e8c4e72a4fbe37cb4a8b8791239972aaa58": "Russian Windows edition, examined resource file",
    "f63291730ebe1b07b5d8c140919e2e5f6c69a2afee0166d877b1626facac3e99": "Portuguese Windows edition, examined resource file",
}

FIDELITY_NOTES = [
    "Exports are recovered original low-poly assets, not remastered geometry.",
    "The Hugo preview uses the first stored local pose and three verified actor-reference links; full actor graphs and levels are not reconstructed.",
    "hugo_body.glb contains stored vertex-sample morph targets, with no invented playback timing, animation state machine, skeletal rig or skin weights.",
    "Only the first texture/color sample is displayed. Byte UVs use /256 and nearest sampling; native interpolation and texel-edge rules remain unverified.",
    "Preview materials are unlit: textured RGB uses /128 with values clamped to [0,1], untextured RGB uses /255. Above-neutral highlights may differ from the native renderer.",
    "Source triangle order is preserved; previews use double-sided geometry and alpha masking where PNG alpha is present. Native culling, blending, lighting and normals are not reconstructed.",
    "GLB axes are (x,z,-y), with a fixed 0.01 preview scale. This is a presentation scale, not a claim about the original game's unit system.",
]


def managed_path(root: Path, relative: str) -> Path:
    path = root / relative
    require(path.resolve().is_relative_to(root), f"Managed path escapes the project root: {relative}")
    return path


@contextmanager
def import_lock(work: Path):
    lock = work / "import.lock"
    token = f"pid={os.getpid()} token={uuid.uuid4().hex}\n"
    try:
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise FormatError("An import lock already exists at .work/import.lock. Another import may be running; an interrupted run may have left the lock.") from exc
    try:
        with os.fdopen(fd, "w", encoding="ascii") as out:
            out.write(token)
        yield
    finally:
        if lock.exists() and lock.read_text(encoding="ascii") == token:
            lock.unlink()


def publish_directory(staged: Path, target: Path) -> None:
    """Promote a complete directory; restore the old directory if promotion fails.

    Directory renames are atomic individually. Portable replacement of an existing
    non-empty directory requires two renames, so readers can see a brief absence.
    No partially generated set of files is published.
    """
    require(not target.is_symlink(), f"Refusing to replace a symlink: {target}")
    require(not target.exists() or target.is_dir(), f"Output path is not a directory: {target}")
    require(staged.is_dir() and staged.parent.resolve() == target.parent.resolve(),
            "Staged output must be on the same parent directory as its destination")
    backup = target.with_name(f".{target.name}-previous-{uuid.uuid4().hex}")
    had_previous = target.exists()
    if had_previous:
        os.replace(target, backup)
    try:
        os.replace(staged, target)
    except BaseException:
        if had_previous:
            os.replace(backup, target)
        raise
    if had_previous:
        # A cleanup failure after commit must not misreport a successful import as
        # a failed one. The uniquely named old directory is safe to remove later.
        shutil.rmtree(backup, ignore_errors=True)


def read_source(source: Path) -> bytes:
    require(source.is_file(), f"Source is not a regular file: {source}")
    require(source.stat().st_size <= MAX_SOURCE_BYTES, "Source exceeds the 256 MiB HUGO4.CD importer limit; pass the resource file, not a disc image")
    with source.open("rb") as handle:
        data = handle.read(MAX_SOURCE_BYTES + 1)
    require(len(data) <= MAX_SOURCE_BYTES, "Source grew beyond the importer size limit")
    require(data.startswith(b"MDIC"),
            "Expected a HUGO4.CD resource file beginning with MDIC. ISO/ZIP/installers are not inputs to this version; extract HUGO4.CD first.")
    return data


def import_original(source: Path, project_root: Path, progress: Callable[[str], None] | None = None) -> dict:
    say = progress or (lambda message: None)
    root = project_root.resolve()
    source = source.resolve()
    require(root.is_dir(), f"Project root does not exist: {root}")
    generated = managed_path(root, "game/assets/generated")
    work = managed_path(root, ".work")
    imports = managed_path(root, ".work/imports")
    require(not source.is_relative_to(generated.resolve()) and not source.is_relative_to(imports.resolve()),
            "Keep the original HUGO4.CD outside game/assets/generated and .work/imports; those directories are managed outputs")
    say("Reading local HUGO4.CD; no downloads or game executables are used.")
    raw = read_source(source)
    source_hash = sha256(raw)
    say("Validating MDIC groups, image sizes, audio and scene directories...")
    container = parse_mdic(raw)
    catalog = Catalog(container)
    say("Validating all mesh samples, triangle indices, bounds and texture references...")
    mesh_report, mesh_inventory = audit_meshes(catalog)
    selections, assembly = proof_profile(catalog)

    work.mkdir(parents=True, exist_ok=True)
    imports.mkdir(parents=True, exist_ok=True)
    with import_lock(work):
        staged_work = Path(tempfile.mkdtemp(prefix=".staging-", dir=imports))
        staged_assets: Path | None = None
        try:
            say("Extracting and checking PNG, WAV and scene payloads in .work/...")
            extracted = staged_work / "extracted"
            extract(container, extracted)
            write_json(staged_work / "scene_catalog.json", catalog.summary)
            write_json(staged_work / "mesh_audit.json", mesh_report)
            write_json(staged_work / "mesh_inventory.json", mesh_inventory)
            write_json(staged_work / "hugo_assembly_evidence.json", assembly)
            output = staged_work / "outputs"
            output.mkdir()
            files = {}
            say("Building Hugo, palm and vertex-sample GLB previews...")
            for name, selected in selections.items():
                encoded = export_glb(catalog, selected, include_samples=name == "hugo_body")
                verified = verify_glb(encoded)
                path = output / f"{name}.glb"
                path.write_bytes(encoded)
                require(sha256(path.read_bytes()) == sha256(encoded), f"Failed to verify output {path.name}")
                files[path.name] = dict(verified, sha256=sha256(encoded), source_meshes=[
                    dict(group=s.mesh.group, record_index=s.mesh.record_index,
                         payload_offset=s.mesh.payload_offset, raw_sha256=s.mesh.raw_sha256,
                         transform_records=list(s.transform_records), stored_vertex_samples=s.mesh.sample_count)
                    for s in selected])
            manifest = {
                "schema_version": 1,
                "importer_version": __version__,
                "source": {
                    "filename": source.name, "size_bytes": len(raw), "sha256": source_hash,
                    "known_examined_source": source_hash in KNOWN_SOURCES,
                    "edition": KNOWN_SOURCES.get(source_hash, "Unrecognized hash; inspected export layout and structural checks passed"),
                    "provenance": "Local file supplied to the importer; no network retrieval",
                },
                "validation": {"container": container.summary, "catalog": {
                    "scenes": len(catalog.scenes), "object_records": catalog.summary["object_record_count"]},
                    "geometry": mesh_report,
                    "extraction_roundtrips": dict(png=sum(c.kind == 2 for c in container.chunks),
                                                  wav=sum(c.kind == 5 for c in container.chunks),
                                                  scene=sum(c.kind == 4 for c in container.chunks))},
                "coordinate_conversion": {"axes": ["x", "z", "-y"], "scale": SOURCE_UNIT_SCALE,
                                          "world_scene_transform_applied": False},
                "material_preview": {"unlit": True, "textured_rgb_divisor": 128,
                                     "untextured_rgb_divisor": 255, "color_range_clamped": [0, 1],
                                     "uv_divisor": 256, "filter": "nearest", "double_sided": True,
                                     "texture_alpha": "MASK when non-opaque", "alpha_cutoff": 0.5},
                "files": files,
                "work_cache": f".work/imports/{source_hash}",
                "fidelity_limits": FIDELITY_NOTES,
            }
            write_json(output / "asset_manifest.json", manifest)
            cache = imports / source_hash
            publish_directory(staged_work, cache)

            assets_parent = generated.parent
            assets_parent.mkdir(parents=True, exist_ok=True)
            require(assets_parent.resolve().is_relative_to(root), "Asset parent escaped the project root")
            staged_assets = Path(tempfile.mkdtemp(prefix=".generated-staging-", dir=assets_parent))
            for path in (cache / "outputs").iterdir():
                shutil.copyfile(path, staged_assets / path.name)
            for filename, info in files.items():
                require(sha256((staged_assets / filename).read_bytes()) == info["sha256"],
                        f"Staged asset hash mismatch: {filename}")
            say("Publishing the complete generated asset set...")
            publish_directory(staged_assets, generated)
            return manifest
        finally:
            if staged_work.exists():
                shutil.rmtree(staged_work, ignore_errors=True)
            if staged_assets is not None and staged_assets.exists():
                shutil.rmtree(staged_assets, ignore_errors=True)
