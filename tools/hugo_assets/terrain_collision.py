"""Explicit remaster contacts for solid geometry omitted by native XY queries.

The original quadtree remains byte-for-byte source data in its existing fields.
This extension reuses authored triangles; it never creates a floor across a gap.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import numpy as np

from .gltf import scene_axes
from .mesh import Mesh, decode_material_flags
from .scene_graph import CollisionMesh


def complete_terrain_collision(mesh: Mesh, collision: CollisionMesh,
                               opaque_texture, surface_damage: dict | None = None) -> dict:
    """Return only missing static opaque faces, with separate provenance.

    ``opaque_texture(group, texture_id)`` verifies the entire original alpha
    channel. A texture animation is solid only when its exact ordered sequence
    already belongs to native contact faces with explicitly non-damaging surface
    IDs in this mesh. Unknown animations, water and cutouts remain excluded.
    Known per-part surface IDs survive; unknown parts use -1, not a guessed ID.
    """
    if mesh.sample_count != 1:
        return {"faces": [], "surface_types": [], "source_triangles": [],
                "triangle_count": 0, "excluded": {"animated_mesh": mesh.triangle_count}}
    native_faces = {(t.submesh, t.triangle) for t in collision.triangles}
    by_part = defaultdict(set)
    existing = set()

    def face_key(vertices):
        return tuple(sorted(tuple(float(v) for v in row) for row in np.round(vertices, 4)))

    for triangle in collision.triangles:
        by_part[triangle.submesh].add(triangle.surface_type)
        existing.add(face_key(triangle.vertices))
    # Texture animation alone does not imply a liquid: the factory's ore belts
    # use ten-frame sequences on both native collision faces and omitted faces.
    # Require source contact evidence for the whole sequence, never appearance
    # or a guessed material name. Damage must be explicitly decoded, not absent.
    animated_evidence = defaultdict(lambda: {"parts": set(), "surfaces": set()})
    for part in mesh.parts:
        if len(part.materials) > 1 and part.index in by_part:
            sequence = tuple(ref.texture_id for ref in part.materials)
            animated_evidence[sequence]["parts"].add(part.index)
            animated_evidence[sequence]["surfaces"].update(by_part[part.index])
    damage = surface_damage or {}
    solid_sequences = {
        sequence: evidence for sequence, evidence in animated_evidence.items()
        if evidence["surfaces"] and all(
            surface in damage and damage[surface] == 0.0
            for surface in evidence["surfaces"])
    }
    faces, surfaces, source_triangles = [], [], []
    accepted_animated_parts = set()
    excluded = Counter()
    for part in mesh.parts:
        flags = decode_material_flags(part.flags, textured=bool(part.materials))
        reason = None
        if flags["native_draw_skipped"]:
            reason = "not_rendered"
        elif flags["blend_selector"] != 3:
            reason = "blended"
        elif len(part.materials) > 1 and tuple(ref.texture_id for ref in part.materials) not in solid_sequences:
            reason = "animated_texture"
        elif any(not opaque_texture(mesh.group, ref.texture_id) for ref in part.materials):
            reason = "cutout_or_translucent_texture"
        for index, indices in enumerate(part.faces):
            if (part.index, index) in native_faces:
                continue
            if reason:
                excluded[reason] += 1
                continue
            vertices = part.vertices[0, indices].astype(np.float64)
            if np.linalg.norm(np.cross(vertices[1]-vertices[0], vertices[2]-vertices[0])) < 1e-8:
                excluded["degenerate"] += 1
                continue
            key = face_key(vertices)
            if key in existing:
                excluded["duplicate_geometry"] += 1
                continue
            existing.add(key)
            if len(part.materials) > 1:
                accepted_animated_parts.add(part.index)
            faces.extend(scene_axes(vertices).tolist())
            source_triangles.append([part.index, index])
            known = by_part.get(part.index, set())
            surfaces.append(next(iter(known)) if len(known) == 1 else -1)
    return {"schema_version": 1, "policy": "authored_opaque_triangles_with_verified_animated_solids",
            "faces": faces, "surface_types": surfaces, "source_triangles": source_triangles,
            "triangle_count": len(source_triangles), "excluded": dict(excluded),
            "coordinate_space": "mesh local, same axes/scale as GLB",
            "surface_type_semantics": "native same-part ID when unambiguous; -1 means unclassified remaster contact",
            "animated_solid_evidence": [
                {"texture_ids": list(sequence), "native_source_parts": sorted(evidence["parts"]),
                 "native_surface_types": sorted(evidence["surfaces"]), "ground_damage": 0.0}
                for sequence, evidence in sorted(solid_sequences.items())],
            "accepted_animated_parts": sorted(accepted_animated_parts),
            "native_quadtree_modified": False, "invented_triangles": 0}
