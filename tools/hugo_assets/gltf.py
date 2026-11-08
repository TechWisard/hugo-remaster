"""Small self-contained glTF 2.0 writer for the recovered preview meshes."""
from __future__ import annotations

import io
import json
import struct

import numpy as np
from PIL import Image

from .binary import FormatError, Reader, require
from .catalog import Catalog
from .material_animation import ANIMATION_TOKEN, material_animation_binding
from .mesh import Selection, decode_material_flags

SOURCE_UNIT_SCALE = 0.01


def preview_colors(rgb: np.ndarray, textured: bool) -> np.ndarray:
    """PC mesh diffuse bytes use /255 for both plain and textured surfaces.

    The textured argument remains part of the caller API. The recovered PC
    renderer uses D3DTOP_MODULATE, not a PSX-style doubled texture modulation.
    Particle colors have their own decoder and are not changed here.
    """
    return np.clip(np.asarray(rgb, dtype=np.float32) / 255.0, 0, 1)


def scene_axes(v: np.ndarray) -> np.ndarray:
    return np.stack((v[..., 0], v[..., 2], -v[..., 1]), axis=-1) * SOURCE_UNIT_SCALE


def native_material_name(label: str, render: dict) -> str:
    """Godot preserves material names even when glTF material extras are lost."""
    selector = render["blend_selector"]
    require(isinstance(selector, int) and 0 <= selector <= 3, "Invalid native material blend selector")
    return f"{label}__hugo_blend_{selector}"


def export_glb(catalog: Catalog, selections: list[Selection], include_samples: bool = False) -> bytes:
    doc = dict(asset=dict(version="2.0", generator="hugo-remaster original asset importer 0.1.0"),
               scene=0, scenes=[dict(nodes=[])], nodes=[], meshes=[], materials=[],
               accessors=[], bufferViews=[], buffers=[], images=[], textures=[],
               samplers=[dict(magFilter=9728, minFilter=9728, wrapS=33071, wrapT=33071)],
               extensionsUsed=["KHR_materials_unlit"])
    binary = bytearray()
    texture_indices = {}

    def add_view(raw: bytes, target: int | None = None) -> int:
        binary.extend(b"\0" * (-len(binary) % 4))
        view = dict(buffer=0, byteOffset=len(binary), byteLength=len(raw))
        binary.extend(raw)
        if target is not None:
            view["target"] = target
        doc["bufferViews"].append(view)
        return len(doc["bufferViews"]) - 1

    def add_accessor(array: np.ndarray, kind: str, component: int = 5126,
                     bounds: bool = False, target: int = 34962) -> int:
        a = np.asarray(array, dtype="<f4" if component == 5126 else "<u2")
        require(bool(np.isfinite(a).all()), "Cannot export non-finite geometry")
        accessor = dict(bufferView=add_view(a.tobytes(), target), componentType=component, count=len(a), type=kind)
        if bounds:
            accessor.update(min=a.min(axis=0).tolist(), max=a.max(axis=0).tolist())
        doc["accessors"].append(accessor)
        return len(doc["accessors"]) - 1

    for selected in selections:
        mesh = selected.mesh
        primitives = []
        for part in mesh.parts:
            vertices = scene_axes(part.vertices @ selected.rotation.T + selected.translation)
            textured = bool(part.materials)
            render = decode_material_flags(part.flags, textured=textured)
            animation = material_animation_binding(mesh, part)
            colors = np.column_stack((preview_colors(part.colors[0, :, :3], textured),
                                      np.full(vertices.shape[1], render["vertex_alpha"], dtype=np.float32)))
            attributes = dict(POSITION=add_accessor(vertices[0], "VEC3", bounds=True),
                              COLOR_0=add_accessor(colors, "VEC4"))
            material_label = f"{selected.label}_part_{part.index:03d}"
            if animation:
                material_label += ANIMATION_TOKEN + animation["key"]
                if animation["source_vertex_index_attribute"] is not None:
                    # UV2 is a metadata carrier, not an authored visual channel.
                    # It survives Godot's vertex reordering/deduplication.
                    source_ids = np.column_stack((np.arange(vertices.shape[1], dtype=np.float32),
                                                  np.full(vertices.shape[1], part.index, dtype=np.float32)))
                    attributes["TEXCOORD_1"] = add_accessor(source_ids, "VEC2")
            material = dict(name=native_material_name(material_label, render),
                            doubleSided=True,
                            extensions={"KHR_materials_unlit": {}},
                            pbrMetallicRoughness=dict(baseColorFactor=[1, 1, 1, 1], metallicFactor=0, roughnessFactor=1),
                            extras=dict(source_flags=part.flags, native_render=render,
                                        native_blend_runtime_required=render["blend_selector"] in (1, 2),
                                        preview_culling="double_sided_until_winding_verified",
                                        color_divisor=render["color_divisor"]))
            if animation:
                material["extras"]["native_material_animation"] = animation
            # glTF has no additive or inverse-source-color material equation.
            # Keep these in the transparent pass and retain the exact native
            # selector for the runtime adapter. Do not guess a black discard.
            if render["alpha_blend_enabled"]:
                material["alphaMode"] = "BLEND"
            if textured:
                reference = part.materials[0]
                texture = catalog.texture(mesh.group, reference.texture_id)
                key = (texture.sha256, texture.width, texture.height)
                pixels = catalog.container.payload(texture)
                if key not in texture_indices:
                    png = io.BytesIO()
                    Image.frombytes("RGBA", (texture.width, texture.height), pixels).save(png, format="PNG")
                    image_index = len(doc["images"])
                    doc["images"].append(dict(bufferView=add_view(png.getvalue()), mimeType="image/png"))
                    texture_indices[key] = len(doc["textures"])
                    doc["textures"].append(dict(source=image_index, sampler=0))
                material["pbrMetallicRoughness"]["baseColorTexture"] = dict(index=texture_indices[key])
                material["extras"].update(source_texture_group=texture.group, source_texture_id=texture.resource_id,
                                           source_texture_payload_sha256=texture.sha256)
                if not render["alpha_blend_enabled"] and any(alpha < 255 for alpha in pixels[3::4]):
                    material.update(alphaMode="MASK", alphaCutoff=render["alpha_cutoff"])
                attributes["TEXCOORD_0"] = add_accessor(part.uv_bytes[0].astype(np.float32)
                                                       * np.float32(1 / 255), "VEC2")
            doc["materials"].append(material)
            primitive = dict(attributes=attributes,
                             indices=add_accessor(part.faces.reshape(-1), "SCALAR", 5123, target=34963),
                             material=len(doc["materials"]) - 1, mode=4)
            if animation:
                primitive["extras"] = dict(native_material_animation=animation)
            if include_samples and mesh.sample_count > 1:
                primitive["targets"] = [dict(POSITION=add_accessor(vertices[i] - vertices[0], "VEC3", bounds=True))
                                        for i in range(1, mesh.sample_count)]
            primitives.append(primitive)
        out_mesh = dict(name=selected.label, primitives=primitives,
                        extras=dict(source_group=mesh.group, source_record=mesh.record_index,
                                    source_transform_records=list(selected.transform_records),
                                    source_sha256=mesh.raw_sha256, stored_vertex_samples=mesh.sample_count,
                                    native_timeline_words=list(mesh.timeline_words),
                                    native_animation_timing_decoded=False))
        if include_samples and mesh.sample_count > 1:
            out_mesh["weights"] = [0.0] * (mesh.sample_count - 1)
            out_mesh["extras"]["targetNames"] = [f"sample_{i:03d}" for i in range(1, mesh.sample_count)]
        doc["meshes"].append(out_mesh)
        doc["scenes"][0]["nodes"].append(len(doc["nodes"]))
        doc["nodes"].append(dict(name=selected.label, mesh=len(doc["meshes"]) - 1))
    doc["buffers"].append(dict(byteLength=len(binary)))
    if not doc["images"]:
        for optional in ("images", "textures", "samplers"):
            del doc[optional]
    raw_json = json.dumps(doc, separators=(",", ":"), allow_nan=False).encode("utf-8")
    raw_json += b" " * (-len(raw_json) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    size = 12 + 8 + len(raw_json) + 8 + len(binary)
    return (struct.pack("<4sII", b"glTF", 2, size)
            + struct.pack("<II", len(raw_json), 0x4E4F534A) + raw_json
            + struct.pack("<II", len(binary), 0x004E4942) + bytes(binary))


def verify_glb(raw: bytes) -> dict:
    """Independently read generated buffers and embedded PNGs before publication."""
    r = Reader(raw, "Generated GLB")
    magic, version, length = r.unpack("<4sII", 0)
    require(magic == b"glTF" and version == 2 and length == len(raw), "Generated GLB header is invalid")
    json_size, json_type = r.unpack("<II", 12)
    require(json_type == 0x4E4F534A and json_size % 4 == 0, "Generated GLB JSON chunk is invalid")
    try:
        doc = json.loads(r.bytes(20, json_size))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise FormatError("Generated GLB JSON is invalid") from exc
    bin_size, bin_type = r.unpack("<II", 20 + json_size)
    require(bin_type == 0x004E4942 and 28 + json_size + bin_size == len(raw), "Generated GLB binary chunk is invalid")
    binary = r.bytes(28 + json_size, bin_size)
    declared = doc["buffers"][0]["byteLength"]
    require(len(doc["buffers"]) == 1 and declared <= bin_size <= declared + 3, "Generated GLB buffer length mismatch")
    views = doc["bufferViews"]
    for view in views:
        offset = view.get("byteOffset", 0)
        require(view["buffer"] == 0 and offset >= 0 and offset % 4 == 0
                and 0 < view["byteLength"] <= declared - offset, "Generated GLB view is out of bounds")
    dimensions = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}
    components = {5126: "<f4", 5123: "<u2"}
    arrays = []
    for acc in doc["accessors"]:
        view = views[acc["bufferView"]]
        dtype, k = np.dtype(components[acc["componentType"]]), dimensions[acc["type"]]
        require(acc["count"] > 0 and acc["count"] * k * dtype.itemsize <= view["byteLength"],
                "Generated GLB accessor exceeds its buffer view")
        array = np.frombuffer(binary, dtype=dtype, count=acc["count"] * k,
                              offset=view.get("byteOffset", 0)).reshape(-1, k)
        require(bool(np.isfinite(array).all()), "Generated GLB contains non-finite coordinates")
        if "min" in acc:
            require(bool(np.allclose(array.min(0), acc["min"]) and np.allclose(array.max(0), acc["max"])),
                    "Generated GLB accessor bounds do not match its data")
        arrays.append(array)
    vertices = triangles = primitives = targets = 0
    all_positions = []
    for mesh in doc["meshes"]:
        for primitive in mesh["primitives"]:
            attrs = primitive["attributes"]
            pos = arrays[attrs["POSITION"]]
            indices = arrays[primitive["indices"]].reshape(-1)
            require(primitive["mode"] == 4 and len(indices) % 3 == 0 and int(indices.max()) < len(pos),
                    "Generated GLB triangle index is out of bounds")
            require(all(len(arrays[a]) == len(pos) for a in attrs.values()), "Generated GLB attribute count mismatch")
            color = arrays[attrs["COLOR_0"]]
            require(bool((color >= 0).all() and (color <= 1).all()), "Generated GLB color is outside [0,1]")
            for target in primitive.get("targets", []):
                require(arrays[target["POSITION"]].shape == pos.shape, "Generated GLB morph target count mismatch")
                targets += 1
            require(len(mesh.get("weights", [])) == len(primitive.get("targets", [])), "Generated GLB morph weights mismatch")
            vertices += len(pos)
            triangles += len(indices) // 3
            primitives += 1
            all_positions.append(pos)
    image_sizes = []
    for image in doc.get("images", []):
        require("uri" not in image and image["mimeType"] == "image/png", "Generated GLB has an external image")
        view = views[image["bufferView"]]
        start = view.get("byteOffset", 0)
        with Image.open(io.BytesIO(binary[start:start + view["byteLength"]])) as png:
            png.load()
            image_sizes.append(list(png.size))
    points = np.concatenate(all_positions)
    return dict(bytes=len(raw), meshes=len(doc["meshes"]), submeshes=primitives, vertices=vertices,
                triangles=triangles, morph_target_accessors=targets, embedded_texture_sizes=image_sizes,
                bounds=[points.min(0).tolist(), points.max(0).tolist()],
                checked_buffer_lengths=True, checked_indices=True, checked_embedded_images=True)
