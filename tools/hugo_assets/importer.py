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
    "The three preview files retain their initial-pose purpose. The campaign export reconstructs all eight original playable scene graphs separately.",
    "Actor actions use recovered morph samples, transform tracks, Q12 timelines and native state tables; no skeletal rig or skin weights are invented.",
    "Byte UVs use the recovered PC-renderer divisor 255 and nearest sampling. Native material-animation data is exported separately from the initial glTF pose.",
    "Ordinary PC mesh materials use source RGB/255. Vertex alpha is 1 for textured surfaces and 128/255 for untextured surfaces; the fourth source color byte is not alpha. Particle RGB/128 is a separate source path.",
    "Source triangle order and native blend selectors are preserved. The Godot adapter implements alpha, additive, inverse-source multiplication and opaque draw modes. Preview geometry remains double-sided; native lighting and exact culling are not fully reconstructed.",
    "GLB axes are (x,z,-y), with fixed scale 0.01. Native speeds, gravity, cameras and collision geometry are converted consistently to that scale.",
    "Native collision selection and parameters are recovered, while contact resolution uses Godot physics rather than the legacy solver.",
    "Movie conversion retains source resolution/frame rate; re-encoding to Theora/Vorbis is not byte-identical to the Bink source.",
    "Source particle equations are sampled at 60 Hz. Legacy frame-dependent drag/gravity, spatial audio panning and some material effects can differ.",
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


def generated_output_files(output: Path) -> list[Path]:
    """Reject unfinished working files before any generated set is published."""
    files = []
    for path in sorted(output.rglob("*")):
        require(not path.is_symlink(), f"Generated output contains a symlink: {path.relative_to(output)}")
        if not path.is_file():
            continue
        relative = path.relative_to(output)
        require(not any(part.startswith(".") for part in relative.parts),
                f"Generated output contains unfinished working files: {relative}")
        files.append(path)
    return files


def import_original(source: Path, project_root: Path, progress: Callable[[str], None] | None = None,
                    *, include_campaign: bool = True, media_dir: Path | None = None,
                    music_dir: Path | None = None, ffmpeg: str = "ffmpeg") -> dict:
    say = progress or (lambda message: None)
    root = project_root.resolve()
    source = source.resolve()
    require(root.is_dir(), f"Project root does not exist: {root}")
    generated = managed_path(root, "game/assets/generated")
    work = managed_path(root, ".work")
    imports = managed_path(root, ".work/imports")
    require(not source.is_relative_to(generated.resolve()) and not source.is_relative_to(imports.resolve()),
            "Keep the original HUGO4.CD outside game/assets/generated and .work/imports; those directories are managed outputs")
    for media_source in [media_dir, music_dir]:
        if media_source is not None:
            require(not media_source.resolve().is_relative_to(generated.resolve())
                    and not media_source.resolve().is_relative_to(imports.resolve()),
                    "Keep original movie/music inputs outside the managed generated/import directories")
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
            campaign_report = None
            animation_report = None
            material_report = None
            gameplay_report = None
            media_report = None
            if include_campaign:
                from .levels import export_campaign
                from .animation import export_animations
                from .material_animation import export_material_animations
                from .gameplay import export_gameplay
                say("Reconstructing original level instances and source scene graphs...")
                campaign_report = export_campaign(catalog, output)
                say("Recovering original gameplay records, event targets and sound resources...")
                gameplay_report = export_gameplay(catalog, output)
                say("Exporting original actor animation samples and native timelines...")
                animation_report = export_animations(catalog, output)
                say("Exporting original texture, color and UV animation samples...")
                material_report = export_material_animations(catalog, output)
            if media_dir is not None:
                from .media import convert_media
                media_report = convert_media(media_dir, output, music_dir, ffmpeg, say, cache_dir=generated)
            elif music_dir is not None:
                raise FormatError("--music-dir requires --media-dir pointing to the local game directory")
            for path in generated_output_files(output):
                relative = path.relative_to(output).as_posix()
                if relative not in files:
                    files[relative] = {"sha256": sha256(path.read_bytes()), "size_bytes": path.stat().st_size}
            manifest = {
                "schema_version": 2,
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
                "material_preview": {"unlit": True, "textured_rgb_divisor": 255,
                                     "untextured_rgb_divisor": 255, "color_range_clamped": [0, 1],
                                     "uv_divisor": 255, "filter": "nearest", "double_sided": True,
                                     "texture_alpha": "source opaque: MASK; source nonopaque: BLEND with native runtime adapter",
                                     "alpha_cutoff": 8 / 255,
                                     "vertex_alpha": {"textured": 1, "untextured": 128 / 255},
                                     "native_blend_selector": "(flags >> 29) & 3"},
                "files": files,
                "work_cache": f".work/imports/{source_hash}",
                "fidelity_limits": FIDELITY_NOTES,
                "campaign": campaign_report,
                "animations": animation_report,
                "materials": material_report,
                "gameplay": gameplay_report,
                "media": media_report,
            }
            write_json(output / "asset_manifest.json", manifest)
            cache = imports / source_hash
            publish_directory(staged_work, cache)

            assets_parent = generated.parent
            assets_parent.mkdir(parents=True, exist_ok=True)
            require(assets_parent.resolve().is_relative_to(root), "Asset parent escaped the project root")
            staged_assets = Path(tempfile.mkdtemp(prefix=".generated-staging-", dir=assets_parent))
            shutil.copytree(cache / "outputs", staged_assets, dirs_exist_ok=True)
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
