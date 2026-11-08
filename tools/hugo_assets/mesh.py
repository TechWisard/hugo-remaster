"""Decode the proven type-2001 mesh subset, including stored vertex samples."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import struct

import numpy as np

from .binary import Reader, require
from .catalog import Catalog, Record
from .mdic import sha256


@dataclass(frozen=True)
class TextureRef:
    texture_id: int
    width: int
    height: int
    unresolved_bytes: tuple[int, int]


@dataclass
class Part:
    index: int
    kind: int
    flags: int
    vertices: np.ndarray
    uv_bytes: np.ndarray
    faces: np.ndarray
    colors: np.ndarray
    materials: tuple[TextureRef, ...]


@dataclass
class Mesh:
    group: int
    record_index: int
    payload_offset: int
    raw_sha256: str
    sample_count: int
    timeline_words: tuple[int, ...]
    animation_flags: int
    extra_offset: int
    bounds: np.ndarray
    parts: tuple[Part, ...]

    @property
    def vertex_count(self) -> int:
        return sum(p.vertices.shape[1] for p in self.parts)

    @property
    def triangle_count(self) -> int:
        return sum(len(p.faces) for p in self.parts)


def parse_mesh(record: Record) -> Mesh:
    r = Reader(record.data, record.label)
    require(record.kind == 2001 and record.header_size == 104, f"{r.label}: unsupported mesh header")
    r.check(0, 112, "mesh header")
    require(r.u32(0) == 2001 and r.u32(4) == 0x01010101 and r.u32(32) == 0x02020202,
            f"{r.label}: invalid mesh signature")
    _, count = r.unpack("<HH", 36)
    animation_header, part_table, timeline, extra = r.unpack("<IIII", 40)
    require(animation_header == 104 and part_table == 112, f"{r.label}: unsupported mesh table layout")
    samples, timeline_count = r.unpack("<HH", animation_header)
    require(samples > 0 and timeline_count > 0 and count > 0, f"{r.label}: empty mesh/animation counts")
    r.check(timeline, timeline_count * 4, "native timeline")
    require(extra == 0 or timeline + timeline_count * 4 == extra,
            f"{r.label}: extra-data pointer overlaps the timeline")
    if extra:
        r.check(extra, 1, "extra-data block")
    r.check(part_table, count * 4, "submesh pointer table")
    pointers = [r.u32(part_table + 4 * i) for i in range(count)]
    require(pointers[0] == part_table + count * 4, f"{r.label}: first submesh does not follow pointer table")
    require(all(p % 4 == 0 for p in pointers) and all(a < b for a, b in zip(pointers, pointers[1:]))
            and pointers[-1] < timeline, f"{r.label}: invalid submesh pointer order")
    bounds = np.array(r.unpack("<6f", 72), dtype=np.float32).reshape(2, 3)
    require(bool(np.isfinite(bounds).all() and (bounds[0] <= bounds[1]).all()), f"{r.label}: invalid bounding box")
    parts = []
    decoded_vertices = 0
    for i, offset in enumerate(pointers):
        label = f"{r.label}, submesh {i}"
        end = pointers[i + 1] if i + 1 < count else timeline
        kind, flags, nv, nt, face_offset, vertex_offset = r.unpack("<IIHHII", offset, "submesh header")
        vertex_kind = kind & 65535
        require(vertex_kind in (1, 3) and kind >> 16 in (0, 1), f"{label}: unsupported vertex kind 0x{kind:x}")
        header_size = 40 if vertex_kind == 3 else 36
        require(offset + header_size <= end, f"{label}: truncated header")
        require(0 < nv <= 1024 and nt > 0, f"{label}: invalid vertex or triangle count")
        decoded_vertices += nv * samples
        require(decoded_vertices <= 2_000_000, f"{label}: mesh exceeds the decoded-vertex limit")
        require(vertex_offset == offset + header_size, f"{label}: invalid vertex offset")
        require(face_offset == vertex_offset + nv * 8 * samples, f"{label}: vertex sample size mismatch")
        color_offset = r.u32(offset + 32)
        require(color_offset == face_offset + nt * 4, f"{label}: triangle buffer size mismatch")
        material_offset = r.u32(offset + 36) if vertex_kind == 3 else end
        require(vertex_offset <= face_offset <= color_offset < material_offset <= end <= len(record.data),
                f"{label}: overlapping or out-of-bounds data blocks")
        color_size = material_offset - color_offset
        require(color_size % (nv * 4) == 0, f"{label}: invalid vertex-color buffer length")
        color_samples = color_size // (nv * 4)
        r.check(vertex_offset, nv * 8 * samples, "vertex samples")
        raw = np.frombuffer(record.data, dtype=np.uint8, count=nv * 8 * samples, offset=vertex_offset).reshape(samples, nv, 8)
        vertices = raw[:, :, :6].copy().view("<i2").reshape(samples, nv, 3).astype(np.float32)
        uv = raw[:, :, 6:8].copy()
        words = np.frombuffer(record.data, dtype="<u4", count=nt, offset=face_offset)
        require(bool(np.all(words >> 30 == 0)), f"{label}: unexpected high bits in triangle indices")
        faces = np.stack((words & 1023, (words >> 10) & 1023, (words >> 20) & 1023), axis=1)
        require(int(faces.max()) < nv, f"{label}: triangle index exceeds {nv} vertices")
        colors = np.frombuffer(record.data, dtype=np.uint8, count=color_size, offset=color_offset).reshape(color_samples, nv, 4).copy()
        materials = []
        if vertex_kind == 3:
            material_flags, nmat = r.unpack("<HH", material_offset, "material header")
            table = r.u32(material_offset + 4)
            require(material_flags == 0 and nmat > 0 and table == material_offset + 8
                    and table + nmat * 4 <= end, f"{label}: invalid texture reference table")
            for j in range(nmat):
                mp = r.u32(table + 4 * j)
                require(mp >= table + nmat * 4 and mp + 8 <= end, f"{label}: texture reference outside material data")
                tex_id = r.u32(mp)
                a, b, width, height = r.unpack("<4B", mp + 4)
                materials.append(TextureRef(tex_id, width or 256, height or 256, (a, b)))
        minimum, maximum = vertices.min(axis=(0, 1)), vertices.max(axis=(0, 1))
        require(bool((minimum >= bounds[0] - 1.001).all() and (maximum <= bounds[1] + 1.001).all()),
                f"{label}: decoded samples lie outside the source bounding box")
        parts.append(Part(i, kind, flags, vertices, uv, faces, colors, tuple(materials)))
    return Mesh(record.group, record.index, record.offset, sha256(record.data), samples,
                tuple(r.u32(timeline + 4 * i) for i in range(timeline_count)),
                r.u32(animation_header + 4), extra, bounds, tuple(parts))


def audit_meshes(catalog: Catalog) -> tuple[dict, list[dict]]:
    stats = Counter()
    raw_hashes, buffer_hashes = set(), set()
    histogram = Counter()
    inventory = []
    for scene in catalog.scenes.values():
        for record in scene.records:
            if record.kind != 2001:
                continue
            mesh = parse_mesh(record)
            stats["mesh_records"] += 1
            stats["mesh_records_with_multiple_vertex_samples"] += int(mesh.sample_count > 1)
            raw_hashes.add(mesh.raw_sha256)
            histogram[mesh.sample_count] += 1
            digest = hashlib.sha256()
            changed = False
            for part in mesh.parts:
                v, f = part.vertices, part.faces
                stats["submeshes"] += 1
                stats["vertices_first_sample"] += v.shape[1]
                stats["vertices_all_stored_samples"] += v.shape[0] * v.shape[1]
                stats["triangles"] += len(f)
                stats["submeshes_valid_vertex_buffers"] += 1
                stats["submeshes_valid_index_buffers"] += 1
                stats["submeshes_multiple_color_samples"] += int(len(part.colors) > 1)
                stats["degenerate_index_triangles"] += int(np.sum(
                    (f[:, 0] == f[:, 1]) | (f[:, 1] == f[:, 2]) | (f[:, 2] == f[:, 0])))
                changed |= bool(np.any(v != v[:1]))
                for array in (v, f, part.colors, part.uv_bytes):
                    digest.update(array.tobytes())
                for reference in part.materials:
                    texture = catalog.texture(mesh.group, reference.texture_id)
                    require((texture.width, texture.height) == (reference.width, reference.height),
                            f"{record.label}: texture {reference.texture_id} dimensions do not match its PNG")
                    stats["resolved_texture_references"] += 1
            stats["models_with_changing_vertex_positions"] += int(changed)
            stats["meshes_valid_all_sample_bounds"] += 1
            buffer_hashes.add(digest.hexdigest())
            inventory.append(dict(group=mesh.group, record_index=mesh.record_index, payload_offset=mesh.payload_offset,
                                  raw_sha256=mesh.raw_sha256, geometry_color_uv_sha256=digest.hexdigest(),
                                  submeshes=len(mesh.parts), vertices=mesh.vertex_count, triangles=mesh.triangle_count,
                                  stored_vertex_samples=mesh.sample_count, timeline_elements=len(mesh.timeline_words),
                                  bounds=mesh.bounds.tolist()))
    require(stats["mesh_records"] > 0, "No supported type-2001 geometry was found")
    return dict(stats, unique_raw_mesh_records=len(raw_hashes),
                unique_geometry_color_uv_buffers=len(buffer_hashes),
                sample_count_histogram=dict(sorted(histogram.items()))), inventory


@dataclass
class Selection:
    mesh: Mesh
    label: str
    translation: np.ndarray
    rotation: np.ndarray
    transform_records: tuple[int, ...] = ()


def first_transform(record: Record) -> tuple[np.ndarray, np.ndarray]:
    require(record.kind in (3000, 3001, 3002, 3003), f"{record.label}: expected transform record")
    r = Reader(record.data, record.label)
    require(r.u32(0) == record.kind, f"{record.label}: transform signature mismatch")
    translation = np.array(r.unpack("<3f", 4))
    rotation = np.array(r.unpack("<9f", 16)).reshape(3, 3)
    require(bool(np.isfinite(translation).all() and np.isfinite(rotation).all()), f"{record.label}: non-finite transform")
    require(bool(np.allclose(rotation @ rotation.T, np.eye(3), atol=1e-4))
            and abs(float(np.linalg.det(rotation)) - 1) < 1e-4,
            f"{record.label}: transform is not a supported rotation")
    return translation, rotation


def proof_profile(catalog: Catalog) -> tuple[dict[str, list[Selection]], list[dict]]:
    """This export profile deliberately matches the inspected scene-6 actor layout."""
    body = parse_mesh(catalog.record(6, 18, 2001))
    head = parse_mesh(catalog.record(6, 121, 2001))
    palm = parse_mesh(catalog.record(6, 1, 2001))
    for label, mesh, expected in (("body", body, (360, 376, 10, 4)),
                                   ("head", head, (214, 220, 7, 1)),
                                   ("palm", palm, (160, 80, 4, 1))):
        actual = (mesh.vertex_count, mesh.triangle_count, len(mesh.parts), mesh.sample_count)
        require(actual == expected, f"Unsupported source edition: {label} layout {actual} differs from {expected}")
    evidence = []
    for owner, owner_kind, transform, target, target_kind in ((183, 10000, 21, 18, 2001),
                                                            (183, 10000, 20, 158, 8003),
                                                            (158, 8003, 122, 121, 2001)):
        record = catalog.record(6, owner, owner_kind)
        catalog.record(6, target, target_kind)
        pattern = struct.pack("<5I", 0x03030303, 0, 0x80000000 | transform, 0, 0x80000000 | target)
        node = record.data.find(pattern)
        require(node >= 0 and node % 4 == 0, f"Unsupported actor graph: {owner} does not link transform {transform} to object {target}")
        tr, rot = first_transform(catalog.record(6, transform))
        evidence.append(dict(group=6, owner_record=owner, node_offset=node,
                             transform_record=transform, target_record=target,
                             translation=tr.tolist(), rotation=rot.tolist()))
    body_tr, body_rot = first_transform(catalog.record(6, 21))
    head_tr, head_rot = first_transform(catalog.record(6, 20))
    inner_tr, inner_rot = first_transform(catalog.record(6, 122))
    selections = {
        "hugo": [Selection(body, "hugo_body", body_tr, body_rot, (21,)),
                 Selection(head, "hugo_head", head_tr + head_rot @ inner_tr, head_rot @ inner_rot, (20, 122))],
        "hugo_body": [Selection(body, "hugo_body", np.zeros(3), np.eye(3))],
        "palm": [Selection(palm, "palm", np.zeros(3), np.eye(3))],
    }
    return selections, evidence
