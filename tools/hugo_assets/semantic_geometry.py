"""Объёмная реконструкция деталей, которые в оригинале были нарисованы плоско.

Этот этап работает с уже восстановленными кривыми поверхностями. Положение
детали привязано к исходному UV и треугольнику, включая ВСЕ morph-позы. Никакого
случайного scattering, изменения игровых координат или общего невидимого пола.
Новые треугольники сохраняют происхождение для анимации и типов коллизий.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import cos, pi, sin
from typing import Any

import numpy as np


@dataclass(frozen=True)
class Feature:
    kind: str
    center: tuple[float, float]
    size: tuple[float, float]
    depth: float
    collision: bool = False


def _feature(kind, u, v, width, height, depth, collision=False):
    return Feature(kind, (u, v), (width, height), depth, collision)


def _authored_pebbles(keys):
    # Explicit, inspected pebble centres on these six native material maps.
    # No broad luminance/height displacement is applied to soil or unrelated
    # textures. The fringe variants retain the same painted lower motifs.
    if keys & {(6,302),(6,303)}:
        motifs=[(57.2,28.4,5,5),(33.4,54.5,4,6),(30.6,36.5,4,6),
                (56.8,46.3,5,5),(4.2,56.4,5,4),(47.,44.,3,3),
                (21.6,46.5,4,4),(42.6,28.8,2,3)]
        if (6,303) in keys:motifs += [(22.7,19.2,5,5),(9.3,23.3,4,5)]
    elif keys & {(17,280),(17,285),(17,286),(17,287)}:
        motifs=[(6.2,40.5,7,7),(22.7,17.3,6,5),(60.7,48.9,5,5),
                (44.8,42.1,5,4),(42.1,54.6,4,5),(25.7,62.,5,3),
                (57.3,57.,4,3),(45.7,25.,4,3)]
        if (17,280) in keys:motifs += [(57.,6.2,4,5),(25.1,1.2,5,4)]
    else:
        return []
    return [_feature("pebble",(u+.5)/64.,(v+.5)/64.,w/64.,h/64.,.26,True)
            for u,v,w,h in motifs]


def features_for(aliases: list[dict[str, int]]) -> tuple[Feature, ...]:
    """UV соответствует мотивам материала, а не названию отдельного mesh."""
    keys = {(int(a["group"]), int(a["texture_id"])) for a in aliases}
    features: list[Feature] = []
    if keys & {(6, 313), (6, 314), (6, 315)}:
        for i, u in enumerate((0.10, 0.31, 0.52, 0.70, 0.88)):
            features.append(_feature("stone", u, .48, .14 if i != 1 else .18,
                                     .14 if i % 2 else .16, .48, True))
    elif keys & {(6,302),(6,303),(17,280),(17,285),(17,286),(17,287)}:
        features += _authored_pebbles(keys)
    elif keys & {(17, 284), (27, 297)}:
        narrow = (27, 297) in keys
        for v in (.21, .72):
            features.append(_feature("sleeper", .5, v, 1.0, .19, .10, True))
        for u in ((.255, .735) if narrow else (.265, .775)):
            features.append(_feature("rail", u, .5, .065 if narrow else .115,
                                     1.0, .72, True))
    elif (27, 360) in keys:
        for u in (.045, .955):
            features.append(_feature("frame", u, .5, .075, 1.0, .65))
        for v in (.045, .955):
            features.append(_feature("frame", .5, v, 1.0, .075, .65))
        features += [_feature("diagonal", .5, .5, .065, .92, .75),
                     _feature("diagonal_reverse", .5, .5, .065, .92, .75),
                     _feature("glass", .5, .5, .86, .86, .018)]
    elif keys & {(27, 304), (55, 267), (55, 268), (59, 292), (59, 293)}:
        for v in (.25, .75):
            features.append(_feature("gauge", .285, v, .38, .31, .10))
        for u in (.68, .79, .89):
            for v in (.13, .23, .33, .39, .63, .73, .83, .89):
                features.append(_feature("indicator", u, v, .065, .058, .30))
        features += _screws()
    elif (36, 251) in keys:
        for u in (.25, .75):
            for v in (.25, .75):
                features.append(_feature("gauge", u, v, .36, .28, .10))
        for u in (.16, .40, .65, .87):
            features.append(_feature("switch", u, .495, .060, .13, .30))
        features += _screws()
    elif keys & {(36, 252), (55, 269), (55, 270)}:
        for u in (.265, .73):
            features.append(_feature("screen", u, .285, .37, .30, .09))
        for u in (.165, .61):
            features.append(_feature("switch", u, .555, .07, .13, .32))
        for u in (.17, .38, .67, .87):
            features.append(_feature("knob", u, .82, .15, .16, .45))
        features += _screws()
    elif (59, 291) in keys:
        for u in (.16, .39, .62, .85):
            features.append(_feature("gauge", u, .16, .19, .14, .12))
        for u in (.50, .64):
            for v in (.40, .64, .85):
                features.append(_feature("knob", u, v, .12, .12, .40))
        features += _screws()
    elif any(g == 46 and t in range(279, 290) for g, t in keys):
        t = next(t for g, t in keys if g == 46 and t in range(279, 290))
        if t in (281, 287):
            features.append(_feature("pipe_vertical", .73, .5, .20, 1.0, .50))
        elif t in (283, 289):
            features.append(_feature("pipe", .76, .45, .48, .20, .50))
            features.append(_feature("collar", .535, .45, .065, .29, .45))
        elif t != 284:
            features.append(_feature("pipe", .5, .45, 1.0, .20, .50))
            for u in (.04, .96):
                features.append(_feature("collar", u, .45, .065, .25, .45))
        if t in (280, 286):
            features.append(_feature("valve", .49, .45, .31, .34, .40))
        features += _screws()
    elif (6, 255) in keys:
        for u in (.115, .38, .64, .885):
            features.append(_feature("pipe_vertical", u, .5, .205, 1.0, .48))
        for v in (.21, .56, .83):
            features.append(_feature("binding", .5, v, 1.0, .035, .65))
    elif (6, 307) in keys:
        for v in (.12, .31, .50, .69, .88):
            features.append(_feature("pipe", .5, v, 1.0, .155, .48))
        for u in (.07, .93):
            features.append(_feature("binding", u, .5, .04, 1.0, .65))
    elif keys & {(6, 254), (6, 288), (27, 264)}:
        for u in (.10, .30, .50, .70, .90):
            features.append(_feature("board", u, .5, .186, 1.0, .035))
        if (6, 254) in keys:
            for v in (.45, .80):
                features.append(_feature("binding", .5, v, 1.0, .04, .80))
    elif keys & {(27, 252), (27, 253), (36, 256), (36, 257)}:
        for v in (.165, .5, .835):
            features.append(_feature("board", .5, v, 1.0, .315, .025))
        features += _screws()
    return tuple(features)


def _screws() -> list[Feature]:
    return [_feature("screw", u, v, .035, .035, .36)
            for u, v in ((.055, .055), (.945, .055), (.055, .945), (.945, .945))]


def _unit(value: np.ndarray) -> np.ndarray:
    length = np.linalg.norm(value, axis=-1, keepdims=True)
    return value / np.maximum(length, 1e-12)


def _parameters(feature: Feature):
    """Возвращает UV-offset, относительную высоту и две реальные сетки LOD."""
    kind = feature.kind
    if kind in {"stone", "pebble", "gauge", "knob", "indicator", "screw", "glass", "screen"}:
        segments, rings = (10, 2) if kind == "pebble" else (16, 4)
        points = [(0., 0., 1.)]
        # Outer ring sits just inside the original footprint. A bottom collar
        # intersects the base by 0.5%, avoiding cracks at a steep viewing angle.
        for ring in range(1, rings + 1):
            q = ring / rings
            for segment in range(segments):
                angle = segment * 2 * pi / segments
                x, y = cos(angle) * q, sin(angle) * q
                if kind in {"screen", "glass", "indicator"}:
                    # Superellipse makes rectangular CRT glass/indicator housings.
                    x = np.sign(x) * abs(x) ** .40
                    y = np.sign(y) * abs(y) ** .40
                height = cos(q * pi / 2)
                if kind in {"stone", "pebble"}:
                    height *= 1.0 + .075 * sin(angle * 3 + .6) * q
                elif kind in {"gauge", "screen", "glass"}:
                    height = .76 + .24 * height if ring < rings else -.005
                points.append((x * .5, y * .5, height if ring < rings else -.005))
        high = _radial_indices(segments, rings, 1, 1)
        low = _radial_indices(segments, rings, 2, 2)
    elif kind == "valve":
        segments = 24
        points = []
        for radius, height in ((.35, .77), (.45, 1.0), (.50, .77), (.45, .55)):
            points.extend((cos(i * 2 * pi / segments) * radius,
                           sin(i * 2 * pi / segments) * radius, height)
                          for i in range(segments))
        high, low = [], []
        for step, dest in ((1, high), (2, low)):
            for ring in range(4):
                for i in range(0, segments, step):
                    a = ring * segments + i
                    b = ring * segments + (i + step) % segments
                    c = ((ring + 1) % 4) * segments + i
                    d = ((ring + 1) % 4) * segments + (i + step) % segments
                    dest += [(a, c, b), (b, c, d)]
    else:
        pipe = kind in {"pipe", "pipe_vertical"}
        # Sixteen segments across an actual cylindrical pipe; bevelled seven
        # point cross-section for metal rails, beams, timber and lamp bars.
        cross = [(q / 16 - .5, sin(q * pi / 16)) for q in range(17)] if pipe else [
            (-.5, -.005), (-.5, .68), (-.42, 1.), (0., 1.),
            (.42, 1.), (.5, .68), (.5, -.005)]
        vertical = kind in {"rail", "pipe_vertical"} or feature.size[1] > feature.size[0]
        points = []
        for along in (-.5, .5):
            for across, height in cross:
                x, y = (across, along) if vertical else (along, across)
                if kind.startswith("diagonal"):
                    # X bars use the authored diagonal UV, not a rotated child.
                    x, y = along + across * feature.size[0], along
                    if kind == "diagonal_reverse":
                        x = -x
                points.append((x, y, height))
        n = len(cross)
        high = []
        low = []
        for step, dest in ((1, high), (2 if pipe else 1, low)):
            for i in range(0, n - 1, step):
                j = min(n - 1, i + step)
                dest += [(i, i + n, j), (j, i + n, j + n)]
            # Actual end caps make the model solid at the end of a wall/rail.
            for side in (0, 1):
                order = list(range(0, n, step))
                if order[-1] != n - 1:
                    order.append(n - 1)
                for k in range(1, len(order) - 1):
                    face = (side * n, side * n + order[k], side * n + order[k + 1])
                    dest.append(face if side else tuple(reversed(face)))
    return np.asarray(points, np.float64), np.asarray(high, np.uint32), np.asarray(low, np.uint32)


def _radial_indices(segments, rings, angular_step, radial_step):
    def index(r, a):
        return 1 + (r - 1) * segments + a % segments
    result = []
    for a in range(0, segments, angular_step):
        result.append((0, index(radial_step, a), index(radial_step, a + angular_step)))
    for r in range(radial_step, rings, radial_step):
        next_r = min(rings, r + radial_step)
        for a in range(0, segments, angular_step):
            b = a + angular_step
            result += [(index(r, a), index(next_r, a), index(r, b)),
                       (index(r, b), index(next_r, a), index(next_r, b))]
    return result


class _Appender:
    def __init__(self, surface):
        self.surface = surface
        self.vertex_count = surface["positions"].shape[1]
        self.positions, self.normals, self.uv, self.colors = [], [], [], []
        self.ids, self.weights, self.faces, self.low_faces = [], [], [], []
        self.origin, self.collision, self.surface_types, self.uv2 = [], [], [], []
        self.counts: dict[str, int] = {}

    def add(self, positions, uv, colors, ids, weights, faces, low_faces,
            origin, collision, kind, surface_type=-1):
        if not np.isfinite(positions).all() or not np.isfinite(uv).all():
            raise ValueError("Non-finite semantic geometry")
        # Winding matches the actual source front normal in mesh-local space.
        normals = np.zeros_like(positions)
        for pose in range(positions.shape[0]):
            p = positions[pose]
            face_normals = np.cross(p[faces[:, 1]] - p[faces[:, 0]],
                                    p[faces[:, 2]] - p[faces[:, 0]])
            for corner in range(3):
                np.add.at(normals[pose], faces[:, corner], face_normals)
        normals = _unit(normals)
        self.positions.append(positions.astype(np.float32))
        self.normals.append(normals.astype(np.float32))
        self.uv.append(np.asarray(uv, np.float32))
        self.colors.append(np.asarray(colors, np.float32))
        self.ids.append(np.asarray(ids, np.int32))
        self.weights.append(np.asarray(weights, np.float32))
        if self.surface.get("uv2") is not None:
            self.uv2.append(np.tile([-1., float(self.surface.get("part_index", 0))],
                                    (positions.shape[1], 1)).astype(np.float32))
        self.faces.append(faces + self.vertex_count)
        self.low_faces.append(low_faces + self.vertex_count)
        self.origin.append(np.tile(origin, (len(faces), 1)).astype(np.int32))
        self.collision.append(np.full(len(faces), collision, bool))
        self.surface_types.append(np.full(len(faces), surface_type if collision else -1, np.int32))
        self.vertex_count += positions.shape[1]
        self.counts[kind] = self.counts.get(kind, 0) + 1

    def finish(self):
        if not self.positions:
            return self.surface
        out = dict(self.surface)
        for key, blocks, axis in (("positions", self.positions, 1),
                                   ("normals", self.normals, 1),
                                   ("uv", self.uv, 0), ("colors", self.colors, 0),
                                   ("source_ids", self.ids, 0),
                                   ("source_weights", self.weights, 0),
                                   ("indices", self.faces, 0),
                                   ("triangle_origin", self.origin, 0),
                                   ("collision_mask", self.collision, 0),
                                   ("collision_surface_types", self.surface_types, 0),
                                   ("uv2", self.uv2, 0)):
            base = out.get(key)
            if base is None:
                # A surface without UV is not eligible for motif geometry.
                continue
            out[key] = np.concatenate([base, *blocks], axis=axis)
        out["lod_indices"] = {threshold: np.concatenate([faces, *self.low_faces])
                              for threshold, faces in out.get("lod_indices", {}).items()}
        out["semantic_geometry"] = {"features": self.counts,
                                    "added_vertices": sum(p.shape[1] for p in self.positions),
                                    "added_triangles": sum(len(p) for p in self.faces),
                                    "added_collision_triangles": sum(int(p.sum()) for p in self.collision)}
        return out


def _uv_support(original):
    """Join only a shared geometric EDGE whose two UV endpoints also match.

    Repeated 0..1 tiles often touch in world space but are separate charts.
    Sharing one world vertex must never connect distant texture repetitions.
    """
    faces = np.asarray(original["indices"], np.int64)
    uv = np.asarray(original["uv"])[faces]
    matrices = np.stack((uv[:, 1] - uv[:, 0], uv[:, 2] - uv[:, 0]), axis=-1)
    valid = np.abs(np.linalg.det(matrices)) > 1e-10
    inverse = np.zeros_like(matrices)
    inverse[valid] = np.linalg.inv(matrices[valid])
    parent = list(range(len(faces)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    linked = {}
    signatures = np.round(original["positions"].transpose(1, 0, 2), 6)
    vertex_keys = [signatures[v].tobytes() + np.round(original["uv"][v], 6).tobytes()
                   for v in range(len(signatures))]
    for i, face in enumerate(faces):
        for side in range(3):
            a, b = vertex_keys[face[side]], vertex_keys[face[(side + 1) % 3]]
            edge = tuple(sorted((a, b)))
            if edge in linked:
                parent[root(i)] = root(linked[edge])
            else:
                linked[edge] = i
    groups = np.array([root(i) for i in range(len(faces))])
    return {"uv": uv, "inverse": inverse, "valid": valid, "groups": groups,
            "islands": {int(i): np.flatnonzero((groups == i) & valid) for i in set(groups)}}


def _sample_attachment(original, context, support, anchor, coordinates):
    """Re-anchor EACH vertex across a UV diagonal, without crossing world islands.

    At a real chart boundary the footprint is clipped to supported geometry.
    No tangent extrapolation and no jumps to a different repeated world tile.
    """
    faces = original["indices"]
    candidates = support["islands"][int(support["groups"][anchor])]
    anchor_uv = support["uv"][anchor, 0]
    anchor_inverse = support["inverse"][anchor]
    anchor_face = faces[anchor]
    positions, normals, colors, ids, weights = [], [], [], [], []
    for coordinate in coordinates:
        anchor_bc = anchor_inverse @ (coordinate - anchor_uv)
        expected = np.array([1 - anchor_bc.sum(), *anchor_bc]) @ original["positions"][0, anchor_face]
        delta = coordinate - support["uv"][candidates, 0]
        bc12 = np.einsum("tij,tj->ti", support["inverse"][candidates], delta)
        barys = np.column_stack((1 - bc12.sum(axis=1), bc12))
        contains = np.min(barys, axis=1) >= -1e-7
        available = np.flatnonzero(contains)
        if len(available):
            mapped = np.einsum("ti,tic->tc", barys[available],
                               original["positions"][0, faces[candidates[available]]])
            choice = available[np.argmin(np.linalg.norm(mapped - expected, axis=1))]
            face_index = int(candidates[choice])
            bary = np.maximum(barys[choice], 0.)
            bary /= bary.sum()
        else:
            # Every candidate belongs to this connected source island. Choose
            # the physically nearest clamped support, never an unrelated layer.
            clamped = np.maximum(barys, 0.)
            clamped /= np.maximum(clamped.sum(axis=1, keepdims=True), 1e-12)
            mapped = np.einsum("ti,tic->tc", clamped,
                               original["positions"][0, faces[candidates]])
            choice = int(np.argmin(np.linalg.norm(mapped - expected, axis=1)))
            face_index = int(candidates[choice])
            bary = clamped[choice]
        face = faces[face_index]
        point, normal = _evaluate(context, original, face_index, bary[None])
        source_weights = original["source_weights"][face]
        dominant = np.argmax(source_weights, axis=1)
        if not np.allclose(source_weights[np.arange(3), dominant], 1., atol=1e-5):
            raise ValueError("Semantic anchor requires the original source-vertex prefix")
        ids.append(original["source_ids"][face][np.arange(3), dominant])
        weights.append(bary)
        positions.append(point[:, 0])
        normals.append(normal[:, 0])
        colors.append(bary @ original["colors"][face])
    return (np.stack(positions, axis=1), np.stack(normals, axis=1),
            np.asarray(colors), np.asarray(ids), np.asarray(weights))


def _evaluate(context, original, triangle_index, barycentric):
    triangle = original["indices"][triangle_index]
    callback = context.get("surface_evaluator")
    normal_callback = context.get("normal_evaluator")
    if callback is not None:
        positions = np.stack([callback(triangle_index, bary) for bary in barycentric], axis=1)
    else:
        positions = np.einsum("ni,pic->pnc", barycentric, original["positions"][:, triangle])
    if normal_callback is not None:
        normals = np.stack([normal_callback(triangle_index, bary) for bary in barycentric], axis=1)
    else:
        normals = np.einsum("ni,pic->pnc", barycentric, original["normals"][:, triangle])
    return positions, _unit(normals)


def augment_surface(surface: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Add source-anchored solids; retain original indices, poses and provenance."""
    original = context.get("original_surface", surface)
    if original.get("uv") is None or not len(original.get("indices", [])):
        return surface
    features = features_for(context.get("source_texture_aliases", []))
    support = _uv_support(original) if features else None
    output = _Appender(surface)
    seen = set()
    for triangle_index, triangle in enumerate(original["indices"]):
        if not features:
            break
        uv = np.asarray(original["uv"])[triangle]
        uv_matrix = np.column_stack((uv[1] - uv[0], uv[2] - uv[0]))
        determinant = np.linalg.det(uv_matrix)
        if abs(determinant) < 1e-10:
            continue
        inverse = np.linalg.inv(uv_matrix)
        edges = original["positions"][0, triangle[1:]] - original["positions"][0, triangle[0]]
        tangents = edges.T @ inverse
        scale = np.linalg.norm(tangents, axis=0)
        if np.min(scale) < 1e-5 or np.max(scale) > 150.0:
            continue
        # Bound repeated UV enumeration for malformed/imported extreme coordinates.
        tile_min = np.floor(uv.min(axis=0)).astype(int)
        tile_max = np.ceil(uv.max(axis=0)).astype(int)
        if np.prod(np.maximum(tile_max - tile_min, 1)) > 256:
            continue
        for tile_u in range(tile_min[0], max(tile_min[0] + 1, tile_max[0])):
            for tile_v in range(tile_min[1], max(tile_min[1] + 1, tile_max[1])):
                for feature in features:
                    center = np.asarray(feature.center) + (tile_u, tile_v)
                    bc12 = inverse @ (center - uv[0])
                    center_bary = np.array([1 - bc12.sum(), bc12[0], bc12[1]])
                    if np.min(center_bary) < -1e-6:
                        continue
                    center_p, center_n = _evaluate(context, original, triangle_index, center_bary[None])
                    stamp = (feature.kind, *np.round(center_p[0, 0] * 100000).astype(int),
                             *np.round(center_n[0, 0] * 1000).astype(int))
                    if stamp in seen:
                        continue
                    seen.add(stamp)
                    params, faces, low_faces = _parameters(feature)
                    extent = np.asarray(feature.size)
                    # The diagonal's long dimensions are both the authored square.
                    if feature.kind.startswith("diagonal"):
                        extent = np.array([feature.size[1], feature.size[1]])
                    coordinates = center + params[:, :2] * extent
                    base, normal, colors, ids, weights = _sample_attachment(
                        original, context, support, triangle_index, coordinates)
                    depth = min(float(np.min(scale * feature.size)) * feature.depth,
                                .28 if feature.kind == "stone" else .40)
                    if feature.kind == "pebble":
                        depth=min(depth,.035)
                    if feature.kind.startswith("diagonal"):
                        depth = min(float(np.min(scale)) * feature.size[0] * feature.depth, .12)
                    positions = base + normal * (params[:, 2] * depth)[None, :, None]
                    average_front = center_n[0, 0]
                    normals = np.cross(positions[0, faces[:, 1]] - positions[0, faces[:, 0]],
                                       positions[0, faces[:, 2]] - positions[0, faces[:, 0]])
                    if np.dot(normals.sum(axis=0), average_front) < 0:
                        faces = faces[:, ::-1]
                        low_faces = low_faces[:, ::-1]
                    # Source vertex lighting remains continuous, including its alpha.
                    colors = np.clip(colors, 0.0, 1.0)
                    inherited = bool(original["collision_mask"][triangle_index])
                    collision = feature.collision and inherited and average_front[1] > .35
                    output.add(positions, coordinates, colors, ids, weights, faces, low_faces,
                               original["triangle_origin"][triangle_index], collision, feature.kind,
                               int(original.get("collision_surface_types", np.full(len(original["indices"]), -1))[triangle_index]))
    _add_skirts(output, original, context)
    return output.finish()


def _add_skirts(output: _Appender, original: dict, context: dict):
    """Finish real exterior edges vertically; never cover a pit or add a floor."""
    edges = context.get("exterior_edges", [])
    down = context.get("world_down_local")
    if not edges or down is None or original["positions"].shape[0] != 1:
        return
    down = _unit(np.asarray(down, np.float64))
    if not np.isfinite(down).all() or np.linalg.norm(down) < .5:
        return
    for edge in edges:
        a, b = map(int, edge)
        p = original["positions"][0, [a, b]]
        length = np.linalg.norm(p[1] - p[0])
        if length < .05 or abs(np.dot(_unit(p[1] - p[0]), down)) > .8:
            continue
        depth = min(max(length * .6, 1.25), 8.0)
        # Two steps taper the underside instead of extending a single paper quad.
        inset = _unit(np.cross(p[1] - p[0], down)) * min(length * .08, .6)
        positions = np.stack([p[0], p[1], p[0] + down * depth * .45 + inset,
                              p[1] + down * depth * .45 + inset,
                              p[0] + down * depth + inset * .4,
                              p[1] + down * depth + inset * .4])[None]
        source_rows = [a, b, a, b, a, b]
        uv = original["uv"][source_rows].copy()
        uv[2:4, 1] += .45
        uv[4:6, 1] += 1.0
        faces = np.asarray([(0, 2, 1), (1, 2, 3), (2, 4, 3), (3, 4, 5)], np.uint32)
        output.add(positions, uv, original["colors"][source_rows],
                   original["source_ids"][source_rows], original["source_weights"][source_rows],
                   faces, faces, np.array([context.get("surface_index", 0), -1]), False,
                   "exterior_rock_skirt")
