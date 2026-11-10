"""Close a verified open metal canopy without changing unrelated geometry.

The roof of the original Mines lantern is an open sheet. Its front skin has
already been curved by the primary geometry bake. This final, scoped stage
adds an inner skin and a small rolled rim to that exact sheet in every pose
and every index LOD. Native vertex attributes and the existing front skin are
kept; no general solidification or collision inference is performed.
"""
from __future__ import annotations

from collections import defaultdict
from itertools import product

import numpy as np


def _unit(values):
    values = np.asarray(values, dtype=np.float64)
    return values / np.maximum(np.linalg.norm(values, axis=-1, keepdims=True), 1e-12)


def close_formed_canopy(surface: dict, native_ids: set[int], thickness: float = .03,
                       rim_steps: int = 6) -> tuple[dict, dict]:
    """Return one closed canopy skin; preserve all other faces and attributes.

    ``native_ids`` identifies the confirmed source canopy, not a coordinate
    box that might accidentally select a neighbouring prop. The original
    numerical prefix, source ID triples and interpolation weights survive.
    New vertices copy a valid native interpolation anchor and acquire only a
    geometric offset. Pose-local normals and measured scale transport it.
    """
    if thickness <= 0 or rim_steps < 2:
        raise ValueError("A formed canopy requires positive thickness and a curved rim")
    points = np.asarray(surface["positions"], dtype=np.float64)
    normals = np.asarray(surface["normals"], dtype=np.float64)
    ids = np.asarray(surface["source_ids"])
    weights = np.asarray(surface["source_weights"])
    permitted = np.all(np.isin(ids, list(native_ids)) | (weights < 1e-7), axis=1)
    appended_points, appended_normals, appended_anchors = [], [], []
    vertex_count = points.shape[1]
    details = []

    def vertex(position, normal, anchor):
        index = vertex_count + len(appended_points)
        appended_points.append(position)
        appended_normals.append(normal)
        appended_anchors.append(anchor)
        return index

    def shell(indices, label):
        indices = np.asarray(indices, dtype=np.int32)
        selected = indices[np.all(permitted[indices], axis=1)]
        if not len(selected):
            raise ValueError(f"The confirmed canopy is absent from {label}")
        used = np.unique(selected)
        # Weld spatially identical seam copies, checking all morph poses.
        # Neighbour buckets avoid round-to-decimal seam splits at a bucket edge.
        epsilon = max(float(np.ptp(points[0, used], axis=0).max()) * 1e-6, 1e-6)
        buckets = defaultdict(list)
        representatives, lookup = [], {}
        for source in used:
            key = tuple(np.floor(points[0, source] / epsilon).astype(np.int64))
            found = None
            for delta in product((-1, 0, 1), repeat=3):
                candidate_key = tuple(a+b for a, b in zip(key, delta))
                for candidate in buckets.get(candidate_key, []):
                    representative = representatives[candidate]
                    if np.max(np.abs(points[:, source] - points[:, representative])) <= epsilon:
                        found = candidate
                        break
                if found is not None:
                    break
            if found is None:
                found = len(representatives)
                representatives.append(int(source))
                buckets[key].append(found)
            lookup[int(source)] = found
        welded = np.asarray([[lookup[int(v)] for v in face] for face in selected], np.int32)
        position = points[:, representatives]
        face_points = position[:, welded]
        cross = np.cross(face_points[:, :, 1] - face_points[:, :, 0],
                         face_points[:, :, 2] - face_points[:, :, 0])
        smooth = np.zeros_like(position)
        edges = defaultdict(list)
        for face, triangle in enumerate(welded):
            for corner, value in enumerate(triangle):
                smooth[:, value] += cross[:, face]
                a, b = int(value), int(triangle[(corner+1) % 3])
                if a != b:
                    edges[tuple(sorted((a, b)))].append((a, b))
        if any(len(uses) > 2 for uses in edges.values()):
            raise ValueError(f"Nonmanifold canopy in {label}; refusing to invent a shell")
        boundary = [uses[0] for uses in edges.values() if len(uses) == 1]
        if not boundary:
            raise ValueError(f"Canopy in {label} is already closed")
        smooth = _unit(smooth)
        outward = np.zeros_like(position)
        degree = defaultdict(int)
        for a, b in boundary:
            tangent = _unit(position[:, b]-position[:, a])
            edge_out = _unit(np.cross(tangent, _unit(smooth[:, a]+smooth[:, b])))
            outward[:, a] += edge_out
            outward[:, b] += edge_out
            degree[a] += 1
            degree[b] += 1
        if any(count != 2 for count in degree.values()):
            raise ValueError(f"Canopy boundary is not a closed simple loop in {label}")
        outward = _unit(outward)
        centered = position - position.mean(axis=1, keepdims=True)
        span = np.linalg.norm(centered, axis=-1).max(axis=1)
        scale = span / max(float(span[0]), 1e-12)
        depth = thickness * scale
        back = {}
        for i, source in enumerate(representatives):
            back[i] = vertex(position[:, i]-smooth[:, i]*depth[:, None],
                             -smooth[:, i], source)
        added = [[back[int(c)], back[int(b)], back[int(a)]] for a, b, c in welded]
        rim = {}
        for point in degree:
            anchor = representatives[point]
            rim[point, 0] = anchor
            rim[point, rim_steps] = back[point]
            for step in range(1, rim_steps):
                angle = np.pi * step / rim_steps
                direction = smooth[:, point]*np.cos(angle) + outward[:, point]*np.sin(angle)
                curved = position[:, point] - smooth[:, point]*depth[:, None]*.5 \
                    + direction*depth[:, None]*.5
                rim[point, step] = vertex(curved, _unit(direction), anchor)
        for a, b in boundary:
            for step in range(rim_steps):
                # Boundary order follows the front triangle. The rolled wall
                # uses the opposite front edge, closing the oriented surface.
                a0, b0 = rim[a, step], rim[b, step]
                a1, b1 = rim[a, step+1], rim[b, step+1]
                added.extend(((b0, a0, a1), (b0, a1, b1)))
        details.append({"lod": label, "front_triangles": len(selected),
                        "inner_triangles": len(selected), "rim_triangles": len(boundary)*rim_steps*2,
                        "boundary_edges": len(boundary)})
        return np.concatenate((indices, np.asarray(added, np.int32)))

    result = dict(surface)
    result["indices"] = shell(surface["indices"], "near")
    result["lod_indices"] = {}
    previous = 0.
    for threshold, indices in sorted(surface.get("lod_indices", {}).items()):
        error = max(float(threshold), thickness*2, previous+1e-6)
        result["lod_indices"][error] = shell(indices, str(threshold))
        previous = error
    if not appended_points:
        raise ValueError("A canopy shell produced no new vertices")
    anchors = np.asarray(appended_anchors, np.int32)
    result["positions"] = np.concatenate((points, np.stack(appended_points, axis=1)), axis=1).astype(np.float32)
    result["normals"] = np.concatenate((normals, np.stack(appended_normals, axis=1)), axis=1).astype(np.float32)
    for key in ("colors", "uv", "uv2", "source_ids", "source_weights"):
        if surface.get(key) is not None:
            value = np.asarray(surface[key])
            result[key] = np.concatenate((value, value[anchors]), axis=0)
    extra = len(result["indices"]) - len(surface["indices"])
    result["collision_mask"] = np.concatenate((surface.get("collision_mask", np.zeros(len(surface["indices"]), bool)), np.zeros(extra, bool)))
    result["collision_surface_types"] = np.concatenate((surface.get("collision_surface_types", np.full(len(surface["indices"]), -1, np.int32)), np.full(extra, -1, np.int32)))
    if "triangle_origin" in surface:
        # The extra skin is decorative. Vertex weights are its authoritative
        # provenance; no native collision or material triangle is invented.
        result["triangle_origin"] = np.concatenate((surface["triangle_origin"], np.full((extra, 2), -1, np.int32)))
    metadata = {"method": "verified_canopy_inner_skin_and_rolled_metal_rim", "applied": True,
                "thickness_metres": thickness, "rim_arc_segments": rim_steps,
                "native_anchor_ids": sorted(int(i) for i in native_ids),
                "added_vertices": len(anchors), "added_triangles": extra,
                "morph_poses": points.shape[0], "index_lods": details,
                "source_front_skin_unchanged": True, "collision_added": False}
    return result, metadata
