"""Curved mesh reconstruction with explicit native attribute provenance.

Semantic extension contract (``semantic_geometry.augment_surface``):

``surface`` is a dict of NumPy arrays, in mesh-local Godot axes and metres:

* positions / normals: [P, N, 3], P = base plus every ABSOLUTE morph pose.
* uv: [N, 2] or None; colors: [N, 4], linear vertex RGBA in [0, 1].
* source_ids: [N, 3] int32, original native vertex IDs (not rounded UV2).
* source_weights: [N, 3] float32, barycentric weights summing to one.
* indices: [T, 3] uint32; triangle_origin: [T, 2] int32, source surface/face.
* collision_mask: [T] bool; collision_surface_types: [T] int32.
* lod_indices: {float: [T_lod, 3] uint32}.
* uv2: [N, 2] or None, retained as metadata; weights are authoritative.

Original vertices occupy an unchanged prefix for the coarse LOD. A semantic
extension appends vertices to every pose/attribute array together, or replaces
the arrays consistently. It may append solid faces but must not make a floor
across an authored opening. All added faces need an original anchor triangle
or [-1, -1] and an explicit collision decision. New vertices are stored in all
poses; the runtime therefore uses the original morph weights and phase.

``context`` includes scene_path, mesh_name, source_group, source_record,
surface_index, material (the original glTF dictionary), source_texture_key,
source_texture_size, source_texture_aliases, owner_classes, owner_ids,
original_surface, and exterior_edges (original-surface vertex-index pairs).
Optional surface_evaluator(face, bary3) and normal_evaluator(face, bary3)
return [P, 3] arrays on the reconstructed surface for attachment placement.

The PN patch construction follows Vlachos, Peters, Boyd and Mitchell,
"Curved PN Triangles", I3D 2001, DOI 10.1145/364338.364387. This is a geometric
reconstruction stage, not a claim that subdivision alone authors new anatomy.
Semantic volume construction is a separate, explicit extension stage.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Callable

import numpy as np


def normalize(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=np.float64)
    length = np.linalg.norm(values, axis=-1, keepdims=True)
    return np.divide(values, length, out=np.zeros_like(values), where=length > 1e-14)


def geometry_profile(owner_classes: list[str]) -> dict[str, float]:
    """Choose geometry rules by role; machinery and organic forms differ."""
    roles = set(owner_classes)
    if roles & {"Hugo", "CSimpleStateActor"}:
        return {"crease_degrees": 145.0, "rounding": 0.24, "bevel_fraction": 0.0}
    if "CDefaultSegment" in roles:
        return {"crease_degrees": 115.0, "rounding": 0.10, "bevel_fraction": 0.0}
    return {"crease_degrees": 65.0, "rounding": 0.0, "bevel_fraction": 0.055}


class DisjointSet:
    def __init__(self, size: int):
        self.parent = list(range(size))

    def root(self, value: int) -> int:
        while self.parent[value] != value:
            self.parent[value] = self.parent[self.parent[value]]
            value = self.parent[value]
        return value

    def join(self, a: int, b: int) -> None:
        a, b = self.root(a), self.root(b)
        if a != b:
            self.parent[b] = a


@dataclass
class MeshTopology:
    offsets: list[int]
    face_offsets: list[int]
    positions: np.ndarray
    faces: np.ndarray
    weld_ids: np.ndarray
    edges: dict[tuple[int, int], list[tuple[int, int]]]
    hard_edges: set[tuple[int, int]]
    corner_groups: np.ndarray


def mesh_topology(surfaces: list[dict], crease_degrees: float,
                  face_crease_degrees: np.ndarray | None = None) -> MeshTopology:
    """Weld geometry across UV/material seams only when ALL poses coincide.

    Matching only bind-pose positions would merge unrelated moving parts.
    Crease groups are fixed once so animation cannot change seam topology.
    """
    offsets, face_offsets = [], []
    vertex_at = face_at = 0
    positions, faces = [], []
    for surface in surfaces:
        offsets.append(vertex_at)
        face_offsets.append(face_at)
        positions.append(np.asarray(surface["positions"], dtype=np.float64))
        faces.append(np.asarray(surface["indices"], dtype=np.int64) + vertex_at)
        vertex_at += surface["positions"].shape[1]
        face_at += len(surface["indices"])
    points = np.concatenate(positions, axis=1)
    triangles = np.concatenate(faces, axis=0)
    signatures = points.transpose(1, 0, 2).reshape(vertex_at, -1).astype("<f4")
    signatures[np.abs(signatures) < 1e-9] = 0.0
    records = np.ascontiguousarray(signatures).view(np.dtype((np.void, signatures.shape[1] * 4))).reshape(-1)
    _, weld_ids = np.unique(records, return_inverse=True)
    welded_faces = weld_ids[triangles]
    normals = normalize(np.cross(points[0, triangles[:, 1]] - points[0, triangles[:, 0]],
                                 points[0, triangles[:, 2]] - points[0, triangles[:, 0]]))
    edges: dict[tuple[int, int], list[tuple[int, int]]] = defaultdict(list)
    for face, vertices in enumerate(welded_faces):
        for side in range(3):
            a, b = int(vertices[side]), int(vertices[(side + 1) % 3])
            edges[min(a, b), max(a, b)].append((face, side))
    hard_edges = set()
    groups = DisjointSet(len(triangles) * 3)
    limit = np.cos(np.deg2rad(crease_degrees))
    for key, uses in edges.items():
        if len(uses) != 2 or key[0] == key[1]:
            hard_edges.add(key)
            continue
        (a, _), (b, _) = uses
        edge_limit = limit if face_crease_degrees is None else np.cos(np.deg2rad(min(face_crease_degrees[a], face_crease_degrees[b])))
        if np.dot(normals[a], normals[b]) < edge_limit:
            hard_edges.add(key)
            continue
        for endpoint in key:
            corners_a = np.flatnonzero(welded_faces[a] == endpoint)
            corners_b = np.flatnonzero(welded_faces[b] == endpoint)
            if len(corners_a) == len(corners_b) == 1:
                groups.join(a * 3 + int(corners_a[0]), b * 3 + int(corners_b[0]))
    roots = np.asarray([groups.root(i) for i in range(len(triangles) * 3)], dtype=np.int64)
    _, compact = np.unique(roots, return_inverse=True)
    return MeshTopology(offsets, face_offsets, points, triangles, weld_ids, dict(edges),
                        hard_edges, compact.reshape(-1, 3))


def rounded_positions(topology: MeshTopology, strength: float) -> np.ndarray:
    """Round organic cage corners before constructing the curved patches.

    Boundary/crease vertices stay fixed. Two opposed Laplacian passes reduce
    corner bias with limited shrinkage; displacement is bounded by the shortest
    incident edge. The identical topology/weights are applied to every pose.
    """
    if strength <= 0:
        return topology.positions.copy()
    unique_count = int(topology.weld_ids.max()) + 1
    representative = np.full(unique_count, -1, dtype=np.int64)
    for index, welded in enumerate(topology.weld_ids):
        representative[welded] = index
    original = topology.positions[:, representative].copy()
    points = original.copy()
    neighbours: dict[int, set[int]] = defaultdict(set)
    fixed: set[int] = set()
    for a, b in topology.edges:
        neighbours[a].add(b)
        neighbours[b].add(a)
        if (a, b) in topology.hard_edges:
            fixed.update((a, b))
    movable = [i for i in range(unique_count) if i not in fixed and neighbours[i]]
    if not movable:
        return topology.positions.copy()
    for factor in (strength, -strength * 0.72):
        updated = points.copy()
        for index in movable:
            linked = sorted(neighbours[index])
            mean = points[:, linked].mean(axis=1)
            updated[:, index] += factor * (mean - points[:, index])
        points = updated
    for index in movable:
        linked = sorted(neighbours[index])
        shortest = np.min(np.linalg.norm(original[:, linked] - original[:, index, None], axis=-1), axis=1)
        delta = points[:, index] - original[:, index]
        length = np.linalg.norm(delta, axis=-1)
        scale = np.minimum(1.0, shortest * 0.10 / np.maximum(length, 1e-14))
        points[:, index] = original[:, index] + delta * scale[:, None]
    return points[:, topology.weld_ids]


def corner_normals(topology: MeshTopology, positions: np.ndarray) -> np.ndarray:
    triangles = positions[:, topology.faces]
    cross = np.cross(triangles[:, :, 1] - triangles[:, :, 0], triangles[:, :, 2] - triangles[:, :, 0])
    faces = normalize(cross)
    groups = topology.corner_groups.reshape(-1)
    group_count = int(groups.max()) + 1
    result = np.zeros((*triangles.shape[:3], 3), dtype=np.float64)
    for pose in range(len(positions)):
        weighted = np.empty((len(topology.faces), 3, 3), dtype=np.float64)
        for corner in range(3):
            a = normalize(triangles[pose, :, (corner + 1) % 3] - triangles[pose, :, corner])
            b = normalize(triangles[pose, :, (corner + 2) % 3] - triangles[pose, :, corner])
            angle = np.arccos(np.clip(np.sum(a * b, axis=-1), -1.0, 1.0))
            weighted[:, corner] = faces[pose] * angle[:, None]
        sums = np.zeros((group_count, 3), dtype=np.float64)
        np.add.at(sums, groups, weighted.reshape(-1, 3))
        result[pose] = normalize(sums)[groups].reshape(-1, 3, 3)
    return result


def patch_controls(points: np.ndarray, normals: np.ndarray,
                   hard: np.ndarray) -> np.ndarray:
    """Return the ten cubic PN control points for every pose and triangle."""
    a, b, c = (points[:, :, i] for i in range(3))
    na, nb, nc = (normals[:, :, i] for i in range(3))

    def edge(start, end, normal, sharp):
        projection = np.sum((end - start) * normal, axis=-1)[..., None] * normal
        return (2.0 * start + end - projection * (~sharp)[None, :, None]) / 3.0

    ab = edge(a, b, na, hard[:, 0])
    ba = edge(b, a, nb, hard[:, 0])
    bc = edge(b, c, nb, hard[:, 1])
    cb = edge(c, b, nc, hard[:, 1])
    ca = edge(c, a, nc, hard[:, 2])
    ac = edge(a, c, na, hard[:, 2])
    average = (ab + ba + bc + cb + ca + ac) / 6.0
    middle = average + 0.5 * (average - (a + b + c) / 3.0)
    return np.stack((a, b, c, ab, ba, bc, cb, ca, ac, middle), axis=2)


def evaluate_patch(controls: np.ndarray, barycentric: np.ndarray) -> np.ndarray:
    a, b, c = np.asarray(barycentric, dtype=np.float64)
    coefficients = np.array((a**3, b**3, c**3, 3*a*a*b, 3*a*b*b,
                             3*b*b*c, 3*b*c*c, 3*c*c*a, 3*c*a*a, 6*a*b*c))
    return np.sum(controls * coefficients[..., None], axis=-2)


def refine_mesh(surfaces: list[dict], contexts: list[dict], subdivisions: int = 4,
                augment: Callable[[dict, dict], dict] | None = None) -> tuple[list[dict], dict]:
    if not surfaces or subdivisions < 1:
        raise ValueError("A mesh needs surfaces and at least one subdivision")
    roles = sorted({role for context in contexts for role in context.get("owner_classes", [])})
    profile = geometry_profile(roles)
    from .aircraft_geometry import is_aircraft, curvature_roles, solidify_sheets
    aircraft = is_aircraft(contexts)
    face_limits, aircraft_roles = None, {}
    if aircraft:
        face_limits, aircraft_roles = curvature_roles(surfaces, contexts)
        profile = {"crease_degrees": 65.0, "rounding": 0.18, "bevel_fraction": 0.035}
    topology = mesh_topology(surfaces, profile["crease_degrees"], face_limits)
    positions = rounded_positions(topology, profile["rounding"])
    normals = corner_normals(topology, positions)
    hard = np.zeros((len(topology.faces), 3), dtype=bool)
    for face, vertices in enumerate(topology.weld_ids[topology.faces]):
        for side in range(3):
            a, b = sorted((int(vertices[side]), int(vertices[(side + 1) % 3])))
            hard[face, side] = (a, b) in topology.hard_edges
    controls = patch_controls(positions[:, topology.faces], normals, hard)
    output, evaluated_contexts = [], []
    max_displacement = 0.0
    for index, source in enumerate(surfaces):
        offset = topology.face_offsets[index]
        count = len(source["indices"])
        local_controls = controls[:, offset:offset + count]
        local_normals = normals[:, offset:offset + count]
        context = dict(contexts[index])
        context["original_surface"] = source
        context["surface_evaluator"] = lambda face, bary, p=local_controls: evaluate_patch(p[:, int(face)], bary)
        context["normal_evaluator"] = lambda face, bary, n=local_normals: normalize(np.sum(n[:, int(face)] * np.asarray(bary)[None, :, None], axis=1))
        refined, displacement = refine_surface(source, local_controls, local_normals, subdivisions, index)
        max_displacement = max(max_displacement, displacement)
        output.append(refined)
        evaluated_contexts.append(context)
    bevel_report = {"enabled": False, "eligible_edges": 0}
    if profile["bevel_fraction"] > 0:
        from .bevel_geometry import bevel_mesh
        output, bevel_report = bevel_mesh(surfaces, output, evaluated_contexts, topology, normals,
                                          fraction=profile["bevel_fraction"])
    aircraft_thickness = {"applied": False}
    if aircraft:
        output, aircraft_thickness = solidify_sheets(surfaces, output, evaluated_contexts, topology)
    from .face_geometry import round_eyes
    output, eye_report = round_eyes(surfaces, output, evaluated_contexts)
    for index, source in enumerate(surfaces):
        if augment is not None:
            output[index] = augment(output[index], evaluated_contexts[index])
        validate_surface(output[index], source["positions"].shape[0])
    return output, {"method": "role_aware_cage_rounding_and_curved_pn_surfaces",
                    "profile": profile, "subdivisions_per_edge": subdivisions,
                    "bevel_geometry": bevel_report,
                    "aircraft_roles": aircraft_roles, "aircraft_thickness": aircraft_thickness,
                    "eye_geometry": eye_report,
                    "curved_intermediate_lod_surfaces": sum(bool(s.get("curved_intermediate_lod")) for s in output),
                    "max_curvature_displacement": max_displacement,
                    "source_vertices": sum(s["positions"].shape[1] for s in surfaces),
                    "vertices": sum(s["positions"].shape[1] for s in output),
                    "source_triangles": sum(len(s["indices"]) for s in surfaces),
                    "triangles": sum(len(s["indices"]) for s in output)}


def refine_surface(source: dict, controls: np.ndarray, normals: np.ndarray,
                   subdivisions: int, surface_index: int) -> tuple[dict, float]:
    original = np.asarray(source["positions"], dtype=np.float64)
    count = original.shape[1]
    faces = np.asarray(source["indices"], dtype=np.int64)
    points = [original[:, i].copy() for i in range(count)]
    # Source vertices remain an exact coarse LOD. The high-resolution surface
    # has separate corners when organic rounding moves the control cage.
    original_normals = np.zeros_like(original)
    for pose in range(len(original)):
        np.add.at(original_normals[pose], faces.reshape(-1), normals[pose].reshape(-1, 3))
    original_normals = normalize(original_normals)
    normal_values = [original_normals[:, i].copy() for i in range(count)]
    uv = list(source["uv"].copy()) if source.get("uv") is not None else None
    uv2 = list(source["uv2"].copy()) if source.get("uv2") is not None else None
    colors = list(np.asarray(source["colors"], dtype=np.float64).copy())
    ids = list(np.asarray(source["source_ids"], dtype=np.int32).copy())
    weights = list(np.asarray(source["source_weights"], dtype=np.float64).copy())
    result_faces, origins, collision, surface_types = [], [], [], []
    coarse_faces, coarse_error = [], 0.0
    vertices: dict[tuple, int] = {}
    displacement = 0.0
    for face_index, face in enumerate(faces):
        lattice: dict[tuple[int, int], int] = {}
        for i in range(subdivisions + 1):
            for j in range(subdivisions + 1 - i):
                bary = np.array((subdivisions - i - j, i, j), dtype=np.float64) / subdivisions
                source_weights = defaultdict(float)
                for corner, amount in enumerate(bary):
                    if amount:
                        source_weights[int(face[corner])] += float(amount)
                signature = tuple(sorted(source_weights.items()))
                target = evaluate_patch(controls[:, face_index], bary)
                linear = np.sum(original[:, face] * bary[None, :, None], axis=1)
                displacement = max(displacement, float(np.linalg.norm(target - linear, axis=-1).max()))
                # Position is part of the key: deliberate hard seams may have
                # distinct normals, but shared edge positions must not crack.
                signature += (tuple(np.round(target.reshape(-1), 9)),)
                if signature not in vertices:
                    at = len(points)
                    vertices[signature] = at
                    points.append(target)
                    normal_values.append(normalize(np.sum(normals[:, face_index] * bary[None, :, None], axis=1)))
                    if uv is not None:
                        uv.append(np.sum(source["uv"][face] * bary[:, None], axis=0))
                    if uv2 is not None:
                        # x is an explicit sentinel; runtime uses the IDs and
                        # weights below, never rounding an interpolated UV2 ID.
                        uv2.append(np.array((-1.0, source["uv2"][face[0], 1])))
                    colors.append(np.sum(source["colors"][face] * bary[:, None], axis=0))
                    ids.append(source["source_ids"][face, 0].astype(np.int32))
                    weights.append(bary)
                lattice[i, j] = vertices[signature]
        for i in range(subdivisions):
            for j in range(subdivisions - i):
                result_faces.append((lattice[i, j], lattice[i + 1, j], lattice[i, j + 1]))
                origins.append((surface_index, face_index))
                collision.append(bool(source["collision_mask"][face_index]))
                surface_types.append(int(source["collision_surface_types"][face_index]))
                if i + j < subdivisions - 1:
                    result_faces.append((lattice[i + 1, j], lattice[i + 1, j + 1], lattice[i, j + 1]))
                    origins.append((surface_index, face_index))
                    collision.append(bool(source["collision_mask"][face_index]))
                    surface_types.append(int(source["collision_surface_types"][face_index]))
        # This index-only middle level still uses the rounded cage and curved
        # PN samples. A distant LOD may use the original native cage only after
        # its larger projected error becomes subpixel. No new per-frame work.
        if subdivisions >= 4 and subdivisions % 2 == 0:
            stride = 2
            for i in range(0, subdivisions, stride):
                for j in range(0, subdivisions-i, stride):
                    triangles = [[(i,j),(i+stride,j),(i,j+stride)]]
                    if i+j < subdivisions-stride:
                        triangles.append([(i+stride,j),(i+stride,j+stride),(i,j+stride)])
                    for triangle in triangles:
                        ids_here = [lattice[p] for p in triangle]
                        coarse_faces.append(ids_here)
                        bary_here = np.asarray([(subdivisions-a-b,a,b) for a,b in triangle],np.float64)/subdivisions
                        points_here = np.stack([points[v] for v in ids_here],axis=1)
                        for amount in ((1/3,1/3,1/3),(.5,.5,0),(.5,0,.5),(0,.5,.5)):
                            amount=np.asarray(amount)
                            expected=evaluate_patch(controls[:,face_index],amount@bary_here)
                            linear=(points_here*amount[None,:,None]).sum(axis=1)
                            coarse_error=max(coarse_error,float(np.linalg.norm(expected-linear,axis=-1).max()))
    result = {"positions": np.asarray(points, dtype=np.float32).transpose(1, 0, 2),
              "normals": np.asarray(normal_values, dtype=np.float32).transpose(1, 0, 2),
              "uv": np.asarray(uv, dtype=np.float32) if uv is not None else None,
              "uv2": np.asarray(uv2, dtype=np.float32) if uv2 is not None else None,
              "colors": np.asarray(colors, dtype=np.float32),
              "source_ids": np.asarray(ids, dtype=np.int32),
              "source_weights": np.asarray(weights, dtype=np.float32),
              "indices": np.asarray(result_faces, dtype=np.uint32),
              "triangle_origin": np.asarray(origins, dtype=np.int32),
              "collision_mask": np.asarray(collision, dtype=bool),
              "collision_surface_types": np.asarray(surface_types, dtype=np.int32),
              "lod_indices": {max(displacement * 2.0, 0.02): faces.astype(np.uint32)},
              "source_vertex_count": count, "part_index": source.get("part_index", -1),
              "native_material_key": source.get("native_material_key", "")}
    middle_threshold=max(coarse_error*2.,.004)
    if coarse_faces and middle_threshold < max(displacement*2.,.02)*.95:
        result["lod_indices"][middle_threshold]=np.asarray(coarse_faces,np.uint32)
        result["curved_intermediate_lod"]={"triangles":len(coarse_faces),"measured_patch_error":coarse_error,
                                           "projected_error_threshold":middle_threshold}
    # Exact planes need no redundant geometry. Semantic extension still runs
    # and can create rocks, brackets, foliage volume, rails and other features.
    if displacement < 1e-7:
        result = dict(source)
        result["positions"] = original.astype(np.float32)
        result["normals"] = original_normals.astype(np.float32)
        result["triangle_origin"] = np.column_stack((np.full(len(faces), surface_index), np.arange(len(faces)))).astype(np.int32)
        result["lod_indices"] = {}
        result["source_vertex_count"] = count
    return result, displacement


def validate_surface(surface: dict, pose_count: int) -> None:
    positions = np.asarray(surface["positions"])
    if positions.ndim != 3 or positions.shape[0] != pose_count or positions.shape[2] != 3:
        raise ValueError("Semantic surface changed the morph pose contract")
    count = positions.shape[1]
    for key, width in (("normals", 3),):
        if np.asarray(surface[key]).shape != positions.shape:
            raise ValueError(f"{key} must have one value for every vertex and pose")
    for key, width in (("colors", 4), ("source_ids", 3), ("source_weights", 3)):
        if np.asarray(surface[key]).shape != (count, width):
            raise ValueError(f"{key} must follow every appended vertex")
    for key in ("uv", "uv2"):
        if surface.get(key) is not None and np.asarray(surface[key]).shape != (count, 2):
            raise ValueError(f"{key} must follow every appended vertex")
    if not np.isfinite(positions).all() or not np.isfinite(surface["normals"]).all():
        raise ValueError("Non-finite rebuilt geometry")
    weights = np.asarray(surface["source_weights"])
    if not np.isfinite(weights).all() or (weights < -1e-6).any() or not np.allclose(weights.sum(axis=1), 1.0, atol=1e-5):
        raise ValueError("Invalid native attribute provenance weights")
    faces = np.asarray(surface["indices"])
    if faces.ndim != 2 or faces.shape[1] != 3 or (len(faces) and (faces.min() < 0 or faces.max() >= count)):
        raise ValueError("Triangle index outside rebuilt geometry")
    for key, shape in (("triangle_origin", (len(faces), 2)),
                       ("collision_mask", (len(faces),)),
                       ("collision_surface_types", (len(faces),))):
        if np.asarray(surface[key]).shape != shape:
            raise ValueError(f"{key} must follow every appended triangle")
    for indices in surface.get("lod_indices", {}).values():
        indices = np.asarray(indices)
        if indices.ndim != 2 or indices.shape[1] != 3 or (len(indices) and (indices.min() < 0 or indices.max() >= count)):
            raise ValueError("LOD index outside rebuilt geometry")
