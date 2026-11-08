"""Export native texture, byte-color and byte-UV animation for local resources."""
from __future__ import annotations

from collections import Counter
import os
from pathlib import Path
import shutil
import tempfile

from PIL import Image

from .binary import require
from .catalog import Catalog
from .mdic import sha256, write_json
from .mesh import Mesh, Part, material_animation_manifest, parse_mesh, sample_material_animation


ANIMATION_TOKEN = "__hugo_anim_"
MANIFEST_PATH = "material_animation_manifest.json"
FIDELITY_LIMITS = [
    "Sampling follows the source visual phase, native Q12 mesh timeline and per-part texture sequence; no invented animation FPS is used.",
    "RGB and UV arrays are in original vertex order. TEXCOORD_1 carries source vertex/part indices through glTF import for runtime remapping.",
    "Repeated texture references are preserved as individual sequence slots; PNG storage alone is deduplicated by payload hash and dimensions.",
    "The runtime must sample each mesh instance at its own visual phase; exporting the data alone does not animate a generic glTF viewer.",
    "Native culling correspondence, transparent sorting, texture edge sampling and modern framebuffer conversion remain rendering limits.",
]


def material_animation_binding(mesh: Mesh, part: Part) -> dict | None:
    """Small identity used by glTF materials, without duplicating sample arrays."""
    info = material_animation_manifest(mesh, part)
    if not info["animated"]:
        return None
    attributes = info["source_color_animation"] or info["animate_uv"]
    return dict(key=info["id"], source_group=mesh.group, source_record=mesh.record_index,
                source_part_index=part.index, vertex_count=info["vertex_count"],
                source_color_animation=info["source_color_animation"],
                animate_uv=info["animate_uv"], animate_texture=info["animate_texture"],
                source_vertex_index_attribute="TEXCOORD_1" if attributes else None,
                texture_frame_count=len(info["texture_sequence"]),
                manifest_path=MANIFEST_PATH)


def export_material_animations(catalog: Catalog, output: Path) -> dict:
    """Write a finite manifest and lossless PNG frames to a fresh output stage.

    The caller owns ``output`` (normally the importer's unpublished stage).
    Existing material outputs are rejected. Validation and PNG roundtrips
    finish before this module promotes its new folder/manifest.
    """
    from .animation import decode_timeline

    output.mkdir(parents=True, exist_ok=True)
    target_folder, target_manifest = output / "materials", output / MANIFEST_PATH
    require(not target_folder.exists() and not target_manifest.exists(),
            "Material animation output already exists; use a fresh staging directory")
    materials = {}
    counts: Counter = Counter({key: 0 for key in (
        "mesh_records", "submeshes", "animated_materials", "texture_sequences",
        "color_animated_parts", "uv_animated_parts", "texture_frame_slots",
        "source_rgb_components", "source_uv_components")})
    png_records: dict[tuple[str, int, int], dict] = {}
    with tempfile.TemporaryDirectory(prefix=".material-animation-", dir=output) as temporary:
        stage = Path(temporary)
        frame_dir = stage / "materials" / "textures"
        frame_dir.mkdir(parents=True)
        for group in sorted(catalog.scenes):
            for record in catalog.scenes[group].records:
                if record.kind != 2001:
                    continue
                mesh = parse_mesh(record)
                counts["mesh_records"] += 1
                decode_timeline(mesh.timeline_words, mesh.sample_count, bool(mesh.animation_flags & 1))
                for part in mesh.parts:
                    counts["submeshes"] += 1
                    info = material_animation_manifest(mesh, part)
                    if not info["animated"]:
                        continue
                    require(info["id"] not in materials, "Duplicate source material animation key")
                    info["source_mesh_sha256"] = mesh.raw_sha256
                    info["source_scene_offset"] = record.offset
                    info["source_vertex_mapping"] = {
                        "attribute": "TEXCOORD_1" if info["source_color_animation"] or info["animate_uv"] else None,
                        "x": "source_vertex_index", "y": "source_part_index",
                        "integer_recovery": "round imported UV2 component",
                        "animated_surface_isolation": True,
                    }
                    # The strict reference sampler validates byte arrays and
                    # finite normalized results independently of JSON encoding.
                    for phase in (0.0, 0.25, 0.5, 0.75, 1.0):
                        sample_material_animation(info, phase)
                    for slot in info["texture_sequence"]:
                        texture = catalog.texture(mesh.group, slot["texture_id"])
                        require((texture.width, texture.height) == (slot["width"], slot["height"]),
                                "Material texture-sequence dimensions do not match the source image")
                        identity = (texture.sha256, texture.width, texture.height)
                        if identity not in png_records:
                            filename = f"{texture.sha256}_{texture.width}x{texture.height}.png"
                            relative = "materials/textures/" + filename
                            path = stage / relative
                            payload = catalog.container.payload(texture)
                            Image.frombytes("RGBA", (texture.width, texture.height), payload).save(path, format="PNG")
                            with Image.open(path) as recovered:
                                recovered.load()
                                require(recovered.mode == "RGBA" and recovered.size == (texture.width, texture.height)
                                        and recovered.tobytes() == payload,
                                        "Material animation PNG failed its lossless source roundtrip")
                            png_records[identity] = dict(path=relative, png_sha256=sha256(path.read_bytes()),
                                                         payload_sha256=texture.sha256,
                                                         width=texture.width, height=texture.height)
                        slot.update(png_records[identity], source_texture_group=texture.group,
                                    source_texture_container_offset=texture.offset)
                        counts["texture_frame_slots"] += 1
                    counts["animated_materials"] += 1
                    counts["texture_sequences"] += int(info["animate_texture"])
                    counts["color_animated_parts"] += int(info["source_color_animation"])
                    counts["uv_animated_parts"] += int(info["animate_uv"])
                    counts["source_rgb_components"] += sum(len(sample) * 3 for sample in info["color_samples"])
                    counts["source_uv_components"] += sum(len(sample) * 2 for sample in info["uv_samples"])
                    materials[info["id"]] = info
        validation = dict(counts, unique_texture_frames=len(png_records), png_roundtrips=len(png_records),
                          checked_native_timelines=True, checked_source_sample_arrays=True,
                          checked_sequence_reference_dimensions=True, preserved_texture_slot_order=True,
                          reference_phases_checked=[0.0, 0.25, 0.5, 0.75, 1.0])
        manifest = dict(schema_version=1, source_container_sha256=sha256(catalog.container.data),
                        materials=materials, validation=validation,
                        binding_contract=dict(material_name_token=ANIMATION_TOKEN,
                                              name_suffix="__hugo_anim_<source_key>__hugo_blend_<selector>",
                                              source_vertex_index_attribute="TEXCOORD_1",
                                              texture_paths_relative_to_generated_root=True),
                        fidelity_limits=FIDELITY_LIMITS)
        write_json(stage / MANIFEST_PATH, manifest)
        os.replace(stage / "materials", target_folder)
        try:
            os.replace(stage / MANIFEST_PATH, target_manifest)
        except BaseException:
            # This folder was just created by this call, never pre-existing data.
            shutil.rmtree(target_folder)
            raise
    return dict(schema_version=1, manifest_path=MANIFEST_PATH,
                source_container_sha256=manifest["source_container_sha256"],
                validation=validation, fidelity_limits=FIDELITY_LIMITS)
