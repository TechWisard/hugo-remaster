"""Bounded, pose-aware convex edge fillets for hard mechanical meshes.

Flat panels are trimmed toward a local fillet centre; sampled curved strips
join their new edges and spherical corner fans close the remaining vertices.
This changes the silhouette and surface geometry, rather than smoothing only
normals. Open/nonmanifold/concave rims remain explicit unsupported cases.
"""
from __future__ import annotations

from collections import defaultdict

import numpy as np


def _unit(value):
    value = np.asarray(value, np.float64)
    length = np.linalg.norm(value, axis=-1, keepdims=True)
    return np.divide(value, length, out=np.zeros_like(value), where=length > 1e-12)


def _arc(first, second, fraction):
    a, b = _unit(first), _unit(second)
    cosine = np.clip(np.sum(a * b, axis=-1), -.999999, .999999)
    angle = np.arccos(cosine)
    sine = np.maximum(np.sin(angle), 1e-10)
    direction = (a * (np.sin((1. - fraction) * angle) / sine)[:, None]
                 + b * (np.sin(fraction * angle) / sine)[:, None])
    radius = (1. - fraction) * np.linalg.norm(first, axis=-1) + fraction * np.linalg.norm(second, axis=-1)
    return _unit(direction) * radius[:, None]


class _Surface:
    def __init__(self, original, refined):
        self.original, self.refined = original, refined
        self.count = refined["positions"].shape[1]
        self.positions, self.normals, self.uv, self.uv2 = [], [], [], []
        self.colors, self.ids, self.weights = [], [], []
        self.faces, self.origins, self.solid, self.types = [], [], [], []
        self.changed_vertices = {}
        self.extra_triangles = 0

    def vertex(self, positions, normals, ids, weights, uv, colors, uv2):
        at = self.count + len(self.positions)
        self.positions.append(positions)
        self.normals.append(normals)
        self.ids.append(ids)
        self.weights.append(weights)
        self.colors.append(colors)
        if self.refined.get("uv") is not None:
            self.uv.append(uv)
        if self.refined.get("uv2") is not None:
            self.uv2.append(uv2)
        return at

    def from_source_corner(self, vertex, positions, normals):
        source = self.original
        return self.vertex(positions, normals, source["source_ids"][vertex], source["source_weights"][vertex],
                           source["uv"][vertex] if source.get("uv") is not None else None,
                           source["colors"][vertex],
                           [-1., source.get("part_index", -1)])

    def moved(self, vertex, positions, normals):
        key = (int(vertex), np.round(positions, 8).tobytes(), np.round(normals, 6).tobytes())
        if key not in self.changed_vertices:
            source = self.refined
            self.changed_vertices[key] = self.vertex(positions, normals, source["source_ids"][vertex],
                                                     source["source_weights"][vertex],
                                                     source["uv"][vertex] if source.get("uv") is not None else None,
                                                     source["colors"][vertex], [-1., source.get("part_index", -1)])
        return self.changed_vertices[key]

    def triangle(self, triangle, origin, solid, surface_type, *, orient=None):
        if orient is not None:
            positions = np.asarray([self.positions[int(v) - self.count][0] for v in triangle])
            normal = np.cross(positions[1] - positions[0], positions[2] - positions[0])
            if np.linalg.norm(normal) < 1e-12:
                return
            if np.dot(normal, orient) < 0:
                triangle = [triangle[0], triangle[2], triangle[1]]
            self.extra_triangles += 1
        self.faces.append(triangle)
        self.origins.append(origin)
        self.solid.append(solid)
        self.types.append(surface_type if solid else -1)

    def finish(self, maximum_radius):
        if not self.positions:
            return self.refined
        result = dict(self.refined)
        for key, values, axis, dtype in (("positions", self.positions, 1, np.float32),
                                         ("normals", self.normals, 1, np.float32),
                                         ("colors", self.colors, 0, np.float32),
                                         ("source_ids", self.ids, 0, np.int32),
                                         ("source_weights", self.weights, 0, np.float32),
                                         ("uv", self.uv, 0, np.float32), ("uv2", self.uv2, 0, np.float32)):
            if result.get(key) is not None:
                extra = np.asarray(values, dtype=dtype)
                if axis == 1:
                    extra = extra.transpose(1, 0, 2)
                result[key] = np.concatenate((result[key], extra), axis=axis)
        result["indices"] = np.asarray(self.faces, np.uint32)
        result["triangle_origin"] = np.asarray(self.origins, np.int32)
        result["collision_mask"] = np.asarray(self.solid, bool)
        result["collision_surface_types"] = np.asarray(self.types, np.int32)
        if not result["lod_indices"]:
            result["lod_indices"] = {max(2. * maximum_radius, .01): self.refined["indices"].copy()}
        else:
            # These index levels predate the fillet/eye reconstruction. They
            # may omit it only when its radius also falls below pixel error.
            clamped, previous = {}, 0.
            for threshold, indices in sorted(result["lod_indices"].items()):
                threshold=max(float(threshold),2.*maximum_radius,previous+1e-6)
                clamped[threshold]=indices
                previous=threshold
            result["lod_indices"]=clamped
        result["bevel_geometry"] = {"method": "trimmed_panels_curved_convex_strips_and_spherical_corners",
                                     "added_vertices": len(self.positions), "fillet_triangles": self.extra_triangles,
                                     "maximum_radius": maximum_radius}
        return result


def bevel_mesh(originals, refined, contexts, topology, corner_normals, fraction=.055, segments=6):
    """Return a rebuilt surface list and report; inputs remain immutable.

    Three native source IDs/weights per vertex remain sufficient because every
    trim vertex retains one original triangle's barycentric attributes, and
    each strip/corner vertex samples its original edge endpoint. Geometry
    offsets are evaluated independently in every authored morph pose.
    """
    if fraction <= 0:
        return refined, {"enabled": False, "eligible_edges": 0}
    points = topology.positions
    faces = topology.faces
    welded = topology.weld_ids[faces]
    triangles = points[:, faces]
    face_normals = _unit(np.cross(triangles[:, :, 1] - triangles[:, :, 0], triangles[:, :, 2] - triangles[:, :, 0]))
    eligible = {}
    unsupported_vertices = set()
    for edge in topology.hard_edges:
        uses = topology.edges[edge]
        if len(uses) != 2 or edge[0] == edge[1]:
            unsupported_vertices.update(edge)
            continue
        (a, _), (b, _) = uses
        other = next((int(c) for c in range(3) if int(welded[b, c]) not in edge), None)
        if other is None:
            unsupported_vertices.update(edge)
            continue
        dot = np.sum(face_normals[:, a] * face_normals[:, b], axis=-1)
        convex = np.sum(face_normals[:, a] * (triangles[:, b, other] - triangles[:, a, 0]), axis=-1)
        if np.any(dot < -.985) or np.any(convex > 1e-6) or np.all(np.abs(convex) < 1e-8):
            unsupported_vertices.update(edge)
            continue
        eligible[edge] = (a, b)
    if not eligible:
        return refined, {"enabled": True, "eligible_edges": 0, "open_or_concave_vertices": len(unsupported_vertices)}
    representative = {}
    groups = defaultdict(dict)
    neighbours = defaultdict(set)
    for index, vertex in enumerate(topology.weld_ids):
        representative[int(vertex)] = index
    for face, vertices in enumerate(welded):
        for corner, vertex in enumerate(vertices):
            groups[int(vertex)][int(topology.corner_groups[face, corner])] = (face, corner)
    for a, b in topology.edges:
        neighbours[a].add(b); neighbours[b].add(a)
    active_vertices = {v for edge in eligible for v in edge} - unsupported_vertices
    centers, rounded, radii = {}, {}, {}
    maximum_radius = 0.
    # A sphere diameter is invariant under a native rigid pose rotation; an
    # axis-aligned bounding-box diagonal would make the bevel breathe.
    diagonal = 2. * np.linalg.norm(points - points.mean(axis=1, keepdims=True), axis=-1).max(axis=1)
    for vertex in active_vertices:
        origin = points[:, representative[vertex]]
        adjacent = sorted(neighbours[vertex])
        lengths = np.linalg.norm(points[:, [representative[v] for v in adjacent]] - origin[:, None], axis=-1)
        shortest = lengths.min(axis=1)
        radius = np.minimum(shortest * fraction, diagonal * .018)
        if np.any(radius < 1e-7) or len(groups[vertex]) < 2:
            continue
        ordered = list(groups[vertex].values())
        normal = np.stack([corner_normals[:, face, corner] for face, corner in ordered], axis=1)
        center = origin.copy()
        for pose in range(len(points)):
            delta = np.linalg.lstsq(normal[pose], np.full(len(ordered), -radius[pose]), rcond=None)[0]
            length = float(np.linalg.norm(delta))
            if length > shortest[pose] * .25:
                scale = shortest[pose] * .25 / length
                delta *= scale; radius[pose] *= scale
            center[pose] += delta
        centers[vertex] = center
        radii[vertex] = radius
        maximum_radius = max(maximum_radius, float(radius.max()))
        for group, (face, corner) in groups[vertex].items():
            n = corner_normals[:, face, corner]
            projection = np.sum((center - origin) * n, axis=-1)
            rounded[vertex, group] = center - projection[:, None] * n
    if not centers:
        return refined, {"enabled": True, "eligible_edges": 0, "open_or_concave_vertices": len(unsupported_vertices)}
    offsets = np.zeros_like(triangles)
    for face, vertices in enumerate(welded):
        for corner, vertex in enumerate(vertices):
            key = (int(vertex), int(topology.corner_groups[face, corner]))
            if key in rounded:
                offsets[:, face, corner] = rounded[key] - triangles[:, face, corner]
    out = [_Surface(source, target) for source, target in zip(originals, refined)]
    face_surface = np.empty(len(faces), np.int32)
    face_local = np.empty(len(faces), np.int32)
    for surface, source in enumerate(originals):
        start = topology.face_offsets[surface]
        face_surface[start:start + len(source["indices"])] = surface
        face_local[start:start + len(source["indices"])] = np.arange(len(source["indices"]))
        target = refined[surface]
        for triangle_index, triangle in enumerate(target["indices"]):
            parent = int(target["triangle_origin"][triangle_index, 1])
            offset = offsets[:, start + parent]
            changed = []
            if np.max(np.abs(offset)) < 1e-10:
                changed = triangle.tolist()
            else:
                source_face = source["indices"][parent]
                native_ids = source["source_ids"][source_face, 0]
                for vertex in triangle:
                    bary = np.asarray([sum(float(w) for i, w in zip(target["source_ids"][vertex], target["source_weights"][vertex]) if int(i) == int(native)) for native in native_ids])
                    if abs(float(bary.sum()) - 1.) > 1e-4:
                        raise ValueError("Bevel source triangle cannot represent an existing vertex's native attributes")
                    position = target["positions"][:, vertex] + np.sum(offset * bary[None, :, None], axis=1)
                    normal = contexts[surface]["normal_evaluator"](parent, bary)
                    changed.append(out[surface].moved(vertex, position, normal))
            out[surface].triangle(changed, target["triangle_origin"][triangle_index],
                                  bool(target["collision_mask"][triangle_index]), int(target["collision_surface_types"][triangle_index]))
        previous = contexts[surface]["surface_evaluator"]
        local_offsets = offsets[:, start:start + len(source["indices"])]
        contexts[surface]["surface_evaluator"] = lambda face, bary, evaluate=previous, delta=local_offsets: evaluate(face, bary) + np.sum(delta[:, int(face)] * np.asarray(bary)[None, :, None], axis=1)
    corner_arcs = defaultdict(list)
    for edge, (first_face, second_face) in eligible.items():
        if not any(vertex in centers for vertex in edge):
            continue
        endpoints = []
        for vertex in edge:
            a = int(np.flatnonzero(welded[first_face] == vertex)[0])
            b = int(np.flatnonzero(welded[second_face] == vertex)[0])
            original = points[:, representative[vertex]]
            center = centers.get(vertex, original)
            first = rounded.get((vertex, int(topology.corner_groups[first_face, a])), original)
            second = rounded.get((vertex, int(topology.corner_groups[second_face, b])), original)
            arc = [center + _arc(first - center, second - center, t / segments) for t in range(segments + 1)]
            endpoints.append((arc, center, a, b))
            if vertex in centers and len(groups[vertex]) >= 3:
                corner_arcs[vertex].append((arc, first_face, second_face, a, b))
        for step in range(segments):
            owner_face = first_face if step < segments / 2 else second_face
            surface, parent = int(face_surface[owner_face]), int(face_local[owner_face])
            source = originals[surface]
            builder = out[surface]
            vertices = []
            normals = []
            for endpoint, sample in ((0, step), (1, step), (1, step + 1), (0, step + 1)):
                arc, center, a, b = endpoints[endpoint]
                corner = a if owner_face == first_face else b
                source_vertex = int(source["indices"][parent, corner])
                normal = _unit(arc[sample] - center)
                normals.append(normal)
                vertices.append(builder.from_source_corner(source_vertex, arc[sample], normal))
            outward = _unit(np.sum(normals, axis=0))[0]
            for triangle in ([vertices[0], vertices[1], vertices[2]], [vertices[0], vertices[2], vertices[3]]):
                builder.triangle(triangle, [surface, parent], bool(source["collision_mask"][parent]),
                                 int(source["collision_surface_types"][parent]), orient=outward)
    for vertex, arcs in corner_arcs.items():
        vectors = [rounded[vertex, group] - centers[vertex] for group in groups[vertex] if (vertex, group) in rounded]
        direction = _unit(np.sum([_unit(vector) for vector in vectors], axis=0))
        cap = centers[vertex] + direction * radii[vertex][:, None]
        for arc, first_face, second_face, a, b in arcs:
            for step in range(segments):
                owner_face = first_face if step < segments / 2 else second_face
                surface, parent = int(face_surface[owner_face]), int(face_local[owner_face])
                source = originals[surface]
                source_vertex = int(source["indices"][parent, a if owner_face == first_face else b])
                builder = out[surface]
                vertices = [builder.from_source_corner(source_vertex, value, _unit(value - centers[vertex]))
                            for value in (cap, arc[step], arc[step + 1])]
                outward = _unit(cap + arc[step] + arc[step + 1] - 3. * centers[vertex])[0]
                builder.triangle(vertices, [surface, parent], bool(source["collision_mask"][parent]),
                                 int(source["collision_surface_types"][parent]), orient=outward)
    result = [item.finish(maximum_radius) for item in out]
    return result, {"enabled": True, "eligible_edges": len(eligible), "rounded_vertices": len(centers),
                    "open_or_concave_vertices": len(unsupported_vertices), "maximum_radius": maximum_radius,
                    "fillet_triangles": sum(item.extra_triangles for item in out)}
