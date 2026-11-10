"""Source-anchored volume for explicitly identified organic cutout cards.

The existing card preserves the authored alpha fringe exactly. An additional
closed, curved shell gives its opaque interior a front, back and contour walls.
Transparent holes are excluded from the shell; no collision or pit cap is added.
Every new vertex is evaluated in every absolute native morph pose and retains
three native source IDs plus barycentric weights. Known world foliage, timber frames, chains and grilles use the same constrained
volume. Unknown masks, UI, functional markers and tools are outside the allowlist.
"""
from __future__ import annotations

from collections import OrderedDict, defaultdict
import hashlib
from typing import Any

import numpy as np


# Verified material identities, not guesses based on an arbitrary alpha image.
CUTOUT_PROFILES = {
    "16x32:62fcc7d71dbdc27cddb5dfd486a0a2514baf7882eb1c37d1d8d0349b09245ccc": "ear",
    "16x32:d30820700766a5e23e1db3950e6841d72e492667ac372097a9f43b3ff6c713c6": "ear",
    "26x32:a919140779285b5a6a1723928cca2aea00305a2cf47f83f927cab712fa94d9dc": "ear",
    "32x32:1560d0163dba5792ef6256bcbbd9d93a33404dd9a505d3a8452ff4f655d7aab7": "ear",
    "32x32:585360369a3c903d3643702115a8842be498cf192d73752ab6e44378d9b7a6ff": "ear",
    "32x32:0a0678c1752ecaa661f8a1ead25d1d2b7460faf597f8bc0b01354bc0d07445e5": "tuft",
    "32x32:428f362cfa9d3688f490f24d5a5f29d2e861462ada53bee32dadb907c306e3e1": "tuft",
    "32x32:723597fd9a0d817b0a3bf19fccb30ab11793b80073a2aaa0b1259073ad32d27c": "tuft",
    "32x32:28d40af1404d26cda8c0e6a471edbc23c16bf6abc92840fbd71c703fa9f1d8cc": "leaf",
    "32x32:56d3e1670d08f766686c37346d4aeb918b2744d345de5e7cb4d5c4bfa8e25043": "leaf",
}

WORLD_CUTOUT_PROFILES = {
    "42x64:06afe1a39cd87f94bd0243054790e4df3451172b6513859cb5c84b29342d6e1c": "leaf",  # g003_t0270_06afe1a39cd8
    "32x64:371cc4ab240c4fc49e29b2dfde89414088ce2d915813cecd900e4249d35b34a5": "leaf",  # g003_t0273_371cc4ab240c
    "64x64:da69678480c228369e05351ccdb878773848dcab36b1cb359516934ef6c1f2be": "wood",  # g006_t0288_da69678480c2
    "32x53:f56c73f169e21fad592f378cf699135e7437d72389928147a366c6c06f497a56": "leaf",  # g006_t0337_f56c73f169e2
    "64x25:9ce5be40ac4ab168af80a42feb4cfee9130e44b55dd6f0a773009ed62afc672e": "leaf",  # g006_t0387_9ce5be40ac4a
    "64x64:dc80421ca63e4be7749a070f7355a258aaf1546caa0bca0fc912e8c3207861b1": "wood",  # g027_t0263_dc80421ca63e
    "64x64:ae12001f14540610881fb308d02676cbe4157dec1b0f4b952c2c1b0162602e87": "wood",  # g027_t0298_ae12001f1454
    "64x32:ecc844844ff0a77f84a916c4e0d6899936c1c9a4e7f6cdb34a0ed2724936a3c6": "chain",  # g027_t0354_ecc844844ff0
    "64x64:62e76df527b61eb4d6fd58807b243e745449ff9164ec7fda2c526c3d77aec75d": "wood",  # g036_t0262_62e76df527b6
    "64x64:2df903197100ba121da142a06c20607d8850bea7d0161dece30485c9d1c31836": "wood",  # g036_t0263_2df903197100
    "42x64:4a10e95887d1054ebe40d0dec843eae33343175dc3790ea396fbcc81f268f68f": "leaf",  # g046_t0309_4a10e95887d1
    "32x64:7e4b514f1474dc47d8d2c82de86aea6aa51dd8018d165465ab73cf9db4d70693": "leaf",  # g046_t0313_7e4b514f1474
    "64x64:ba6ae54390aef57cf95958d4214bc6f8bd62c6ecee33320fafc97fe4cb21725f": "metal",  # g055_t0293_ba6ae54390ae
}
SCULPTED_CUTOUT_PROFILES = {
    # Exact owner/mesh bindings distinguish these from arbitrary UI/FX masks.
    "64x32:d1d69ffd119b5c366ba4ae3e4416b36c2eedf5dfab89bc7ae2ea33f60922078f": "fruit_cluster",  # g024 ornamental card
    "64x64:b64be15c766a9b146a08be4f0ac09ee7e7cd9087e9ba0c7ef3c0cd5f766c99f0": "warning_badge",  # platform/ornament, shallow relief
    "64x64:5abf2a47a760293405758847a4b7ceabcffe130de263e52d8701066b5b3fe845": "hanging_lobes",  # static g048/g049 terrain
    "64x64:71e63c3ce38eb4fa2a424817dfc3cd487aa451a3652a0c58a9f1bc7e36f1e665": "end_ornament",  # vertical g073 terrain end face
    "32x32:0c621fd25441be77e33dacd1184cae8e9396cd8b166c0a5c0dfa4c0c2f622679": "stone_fragments",
    "32x32:51c8d050edd0f9cdd2dc606df723e860ed1d982ea3b0e8ac97e4022d292e11e7": "stone_fragments",
    "32x32:84bfb82534dd89dccc6e54729e7858d345ce096bbda9a686da17fa155e09ea8a": "stone_fragments",
    "64x64:84bdbcb8ac17b13bce5be416f9490cdd9d429c292d2639f0fe957ff8fe9746c2": "shield",  # g075 five actor shields
}
_DIMENSIONS = {"tuft": (0.060, 0.018), "ear": (0.040, -0.010), "leaf": (0.020, 0.006),
               "wood": (0.070, 0.0), "chain": (0.040, 0.004), "metal": (0.045, 0.0)}
# Longest grid edge and complete front/back/wall triangle budget per native
# card component. Fine authored alpha fringes stay on the original card.
_TESSELLATION = {
    "leaf": (10, 600), "ear": (12, 800), "tuft": (14, 1200),
    "wood": (14, 1200), "chain": (24, 1800), "metal": (22, 2200),
    "fruit_cluster": (16, 1800), "warning_badge": (12, 1000),
    "end_ornament": (14, 1400), "shield": (14, 1400),
    "hanging_lobes": (16, 1600), "stone_fragments": (20, 1800),
}
_ALPHA_CACHE: OrderedDict = OrderedDict()
_LAYOUT_CACHE: OrderedDict = OrderedDict()
_DEPTH_CACHE: OrderedDict = OrderedDict()


def _remember(cache: OrderedDict, key: Any, value: Any, limit: int = 24):
    cache[key] = value
    cache.move_to_end(key)
    while len(cache) > limit:
        cache.popitem(last=False)
    return value


def _unit(v):
    v = np.asarray(v, np.float64)
    length = np.linalg.norm(v, axis=-1, keepdims=True)
    return np.divide(v, length, out=np.zeros_like(v), where=length > 1e-12)


def _cross2(a, b):
    return a[..., 0] * b[..., 1] - a[..., 1] * b[..., 0]


def _sample_alpha(alpha, point):
    h, w = alpha.shape
    x, y = np.clip(np.asarray(point) * [w, h] - .5, [0., 0.], [w - 1., h - 1.])
    ix, iy = int(x), int(y)
    dx, dy = x - ix, y - iy
    jx, jy = min(ix + 1, w - 1), min(iy + 1, h - 1)
    return ((1-dy) * ((1-dx)*float(alpha[iy, ix]) + dx*float(alpha[iy, jx])) +
            dy * ((1-dx)*float(alpha[jy, ix]) + dx*float(alpha[jy, jx]))) / 255.


def _clip_alpha(triangle, alpha):
    polygon = []
    previous = triangle[-1]
    last = _sample_alpha(alpha, previous) - .45
    for point in triangle:
        value = _sample_alpha(alpha, point) - .45
        if (value >= 0) != (last >= 0):
            polygon.append(previous + (point - previous) * (last / (last - value)))
        if value >= 0:
            polygon.append(point)
        previous, last = point, value
    return polygon


def _covers_transparent_center(triangle, alpha):
    """Reject a solid triangle covering ANY transparent texel centre.

    This checks the full authored mask, not a blurred/downsampled proxy, so a
    small interior hole cannot accidentally receive a solid cap.
    """
    h, w = alpha.shape
    a = np.maximum(np.floor(triangle.min(axis=0) * [w, h] - .5).astype(int), 0)
    b = np.minimum(np.ceil(triangle.max(axis=0) * [w, h] - .5).astype(int), [w-1, h-1])
    if np.any(b < a):
        return False
    local = alpha[a[1]:b[1]+1, a[0]:b[0]+1]
    yy, xx = np.nonzero(local < 9)
    if not len(xx):
        return False
    points = np.column_stack(((xx + a[0] + .5) / w, (yy + a[1] + .5) / h))
    e, f = triangle[1] - triangle[0], triangle[2] - triangle[0]
    determinant = _cross2(e, f)
    if abs(determinant) < 1e-14:
        return False
    rel = points - triangle[0]
    u, v = _cross2(rel, f) / determinant, _cross2(e, rel) / determinant
    return bool(np.any((u >= -1e-10) & (v >= -1e-10) & (u + v <= 1 + 1e-10)))


def _alpha_triangles(alpha, resolution):
    digest = hashlib.sha256(np.ascontiguousarray(alpha).tobytes()).digest()
    key = (alpha.shape, digest, resolution)
    if key in _ALPHA_CACHE:
        return key, _ALPHA_CACHE[key]
    triangles = []

    def append(triangle, depth):
        polygon = _clip_alpha(triangle, alpha)
        for i in range(1, len(polygon) - 1):
            clipped = np.asarray((polygon[0], polygon[i], polygon[i+1]), np.float64)
            if abs(_cross2(clipped[1]-clipped[0], clipped[2]-clipped[0])) < 1e-13:
                continue
            if _covers_transparent_center(clipped, alpha):
                if depth:
                    a, b, c = clipped
                    ab, bc, ca = (a+b)/2, (b+c)/2, (c+a)/2
                    for child in ((a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)):
                        append(np.asarray(child), depth - 1)
                continue
            triangles.append(clipped)

    nx, ny = resolution
    for y in range(ny):
        for x in range(nx):
            a, b = np.array((x/nx, y/ny)), np.array(((x+1)/nx, y/ny))
            c, d = np.array(((x+1)/nx, (y+1)/ny)), np.array((x/nx, (y+1)/ny))
            append(np.array((a, b, c)), 2)
            append(np.array((a, c, d)), 2)
    return key, _remember(_ALPHA_CACHE, key, np.asarray(triangles).reshape(-1, 3, 2))


def _clip_to_triangle(polygon, triangle):
    sign = 1. if _cross2(triangle[1]-triangle[0], triangle[2]-triangle[0]) > 0 else -1.
    for a, b in zip(triangle, np.roll(triangle, -1, axis=0)):
        if not len(polygon):
            break
        result = []
        previous = polygon[-1]
        last = sign * _cross2(b-a, previous-a)
        for point in polygon:
            value = sign * _cross2(b-a, point-a)
            if (value >= -1e-10) != (last >= -1e-10):
                result.append(previous + (point-previous) * (last/(last-value)))
            if value >= -1e-10:
                result.append(point)
            previous, last = point, value
        polygon = result
    return polygon


def _components(original):
    faces = np.asarray(original["indices"], np.int64)
    positions = original["positions"].transpose(1, 0, 2).reshape(original["positions"].shape[1], -1)
    signatures = np.column_stack((positions, original["uv"]))
    vertices = {}
    welded = []
    for row in signatures:
        key = tuple(np.round(row, 7))
        welded.append(vertices.setdefault(key, len(vertices)))
    edges = defaultdict(list)
    for i, face in enumerate(np.asarray(welded)[faces]):
        for a, b in zip(face, np.roll(face, -1)):
            edges[tuple(sorted((int(a), int(b))))].append(i)
    graph = defaultdict(set)
    for uses in edges.values():
        for face in uses:
            graph[face].update(uses)
    remaining, groups = set(range(len(faces))), []
    while remaining:
        pending, component = [min(remaining)], []
        while pending:
            face = pending.pop()
            if face not in remaining:
                continue
            remaining.remove(face)
            component.append(face)
            pending.extend(graph[face] & remaining)
        groups.append(sorted(component))
    return groups


def _layout(alpha_key, masked_triangles, face_uv):
    key = (alpha_key, hashlib.sha256(np.asarray(face_uv, '<f4').tobytes()).digest())
    if key in _LAYOUT_CACHE:
        return _LAYOUT_CACHE[key]
    points, anchors, weights, faces, triangle_anchors = [], [], [], [], []
    vertices, seen = {}, set()
    if not len(masked_triangles):
        return None
    lower, upper = masked_triangles.min(axis=1), masked_triangles.max(axis=1)
    for anchor, domain in enumerate(face_uv):
        matrix = np.column_stack((domain[1]-domain[0], domain[2]-domain[0]))
        if abs(np.linalg.det(matrix)) < 1e-12:
            continue
        inverse = np.linalg.inv(matrix)
        candidates = np.flatnonzero(np.all(upper >= domain.min(axis=0)-1e-9, axis=1) &
                                    np.all(lower <= domain.max(axis=0)+1e-9, axis=1))
        for candidate in candidates:
            polygon = _clip_to_triangle(list(masked_triangles[candidate]), domain)
            for i in range(1, len(polygon)-1):
                triangle = (polygon[0], polygon[i], polygon[i+1])
                if abs(_cross2(triangle[1]-triangle[0], triangle[2]-triangle[0])) < 1e-12:
                    continue
                indices = []
                for point in triangle:
                    signature = tuple(np.round(point, 8))
                    if signature not in vertices:
                        bc = inverse @ (point-domain[0])
                        bary = np.maximum((1-bc.sum(), bc[0], bc[1]), 0.)
                        bary /= bary.sum()
                        vertices[signature] = len(points)
                        points.append(point)
                        anchors.append(anchor)
                        weights.append(bary)
                    indices.append(vertices[signature])
                signature = tuple(sorted(indices))
                if len(set(indices)) == 3 and signature not in seen:
                    faces.append(indices)
                    triangle_anchors.append(anchor)
                    seen.add(signature)
    if not faces:
        return None
    # Adaptive alpha clipping can put a fine vertex in the middle of its
    # neighbour's coarse edge. Split both sides there before bending the shell;
    # otherwise the curved geometry could open a visible T-junction crack.
    bins = defaultdict(set)
    coordinates = np.asarray(points)
    for i, point in enumerate(coordinates):
        bins[tuple(np.floor(point*128).astype(int))].add(i)
    edge_cache = {}

    def edge_points(a, b):
        edge_key = (min(a, b), max(a, b))
        if edge_key not in edge_cache:
            start, finish = coordinates[list(edge_key)]
            lo = np.floor(np.minimum(start, finish)*128).astype(int)-1
            hi = np.floor(np.maximum(start, finish)*128).astype(int)+1
            candidates = set()
            for y in range(lo[1], hi[1]+1):
                for x in range(lo[0], hi[0]+1):
                    candidates.update(bins.get((x, y), ()))
            vector = finish-start
            denominator = float(np.dot(vector, vector))
            interior = []
            if denominator > 1e-16:
                for i in candidates:
                    offset = coordinates[i]-start
                    t = float(np.dot(offset, vector)/denominator)
                    if 1e-7 < t < 1-1e-7 and abs(_cross2(vector, offset)) < 1e-9:
                        interior.append((t, i))
            edge_cache[edge_key] = [edge_key[0], *(i for _, i in sorted(interior)), edge_key[1]]
        ordered = edge_cache[edge_key]
        return ordered if a == edge_key[0] else ordered[::-1]

    conformed = []
    for face, anchor in zip(faces, triangle_anchors):
        perimeter = []
        for a, b in zip(face, np.roll(face, -1)):
            perimeter.extend(edge_points(int(a), int(b))[:-1])
        if len(perimeter) == 3:
            conformed.append(face)
            continue
        center = coordinates[face].mean(axis=0)
        domain = face_uv[anchor]
        bc = np.linalg.solve(np.column_stack((domain[1]-domain[0], domain[2]-domain[0])), center-domain[0])
        bary = np.maximum((1-bc.sum(), bc[0], bc[1]), 0.)
        bary /= bary.sum()
        at = len(points)
        points.append(center)
        anchors.append(anchor)
        weights.append(bary)
        for a, b in zip(perimeter, np.roll(perimeter, -1)):
            conformed.append((at, int(a), int(b)))
    # A clipped mask can contain two regions touching only at one vertex.
    # They need distinct front/back vertex pairs: sharing the vertical pair
    # would give that contour edge four incident walls and a nonmanifold shell.
    conformed = np.asarray(conformed, np.uint32)
    incident = defaultdict(list)
    for face_index, face in enumerate(conformed):
        for vertex in face:
            incident[int(vertex)].append(face_index)
    for vertex, uses in incident.items():
        neighbour_faces = defaultdict(list)
        for face_index in uses:
            for neighbour in conformed[face_index]:
                if int(neighbour) != vertex:
                    neighbour_faces[int(neighbour)].append(face_index)
        graph = defaultdict(set)
        for neighbours in neighbour_faces.values():
            for face_index in neighbours:
                graph[face_index].update(neighbours)
        remaining, first = set(uses), True
        while remaining:
            pending, fan = [min(remaining)], []
            while pending:
                face_index = pending.pop()
                if face_index not in remaining:
                    continue
                remaining.remove(face_index)
                fan.append(face_index)
                pending.extend(graph[face_index] & remaining)
            if first:
                first = False
                continue
            replacement = len(points)
            points.append(points[vertex])
            anchors.append(anchors[vertex])
            weights.append(weights[vertex])
            for face_index in fan:
                conformed[face_index, conformed[face_index] == vertex] = replacement
    result = (np.asarray(points), np.asarray(anchors), np.asarray(weights), conformed)
    return _remember(_LAYOUT_CACHE, key, result)


def _provenance(original, triangles, bary):
    ids, weights = [], []
    for face, bc in zip(triangles, bary):
        contributions = defaultdict(float)
        for vertex, amount in zip(face, bc):
            for source_id, weight in zip(original["source_ids"][vertex], original["source_weights"][vertex]):
                if amount * weight > 1e-9:
                    contributions[int(source_id)] += float(amount * weight)
        if not contributions or len(contributions) > 3:
            return None
        items = sorted(contributions.items())
        source_ids = [item[0] for item in items]
        source_weights = [item[1] for item in items]
        source_ids += [source_ids[0]] * (3-len(source_ids))
        source_weights += [0.] * (3-len(source_weights))
        ids.append(source_ids)
        weights.append(np.asarray(source_weights) / sum(source_weights))
    return np.asarray(ids, np.int32), np.asarray(weights, np.float32)


def _bounded_layout(alpha, source_size, domain_uv, profile):
    """Spend geometry on the opaque form, with a bounded cost per source card."""
    longest, budget = _TESSELLATION[profile]
    aspect = np.asarray(source_size, np.float64) / max(max(source_size), 1)
    result = None
    while True:
        resolution = tuple(int(max(4, round(value*longest))) for value in aspect)
        alpha_key, masked = _alpha_triangles(alpha, resolution)
        layout = _layout(alpha_key, masked, domain_uv)
        if layout is None:
            # An extremely thin opaque part can vanish from a coarser grid.
            # Keep the last valid, hole-safe layout instead of losing volume.
            return result
        edges = defaultdict(int)
        for face in layout[3]:
            for a, b in zip(face, np.roll(face, -1)):
                edges[tuple(sorted((int(a), int(b))))] += 1
        triangles = 2*len(layout[3]) + 2*sum(count == 1 for count in edges.values())
        result = (alpha_key, layout, resolution, triangles, budget)
        if triangles <= budget or longest <= 4:
            return result
        longest = max(4, int(longest*.75))


def _rounded_mask_depth(alpha_key, alpha, uv):
    """Round the opaque lobes without using the colour image as displacement.

    The 96x96 helper only controls depth. The front topology still tests EVERY
    full-resolution transparent texel, so this helper cannot cap a small hole.
    """
    key = (alpha_key, hashlib.sha256(np.asarray(uv, '<f4').tobytes()).digest())
    if key in _DEPTH_CACHE:
        return _DEPTH_CACHE[key]
    grid = 96
    y = np.minimum(((np.arange(grid)+.5)*alpha.shape[0]/grid).astype(int), alpha.shape[0]-1)
    x = np.minimum(((np.arange(grid)+.5)*alpha.shape[1]/grid).astype(int), alpha.shape[1]-1)
    filled = alpha[y[:, None], x[None, :]] >= 115
    padded = np.pad(filled, 1)
    interior = filled.copy()
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        interior &= padded[1+dy:1+dy+grid, 1+dx:1+dx+grid]
    yy, xx = np.nonzero(filled & ~interior)
    if not len(xx):
        return np.zeros(len(uv))
    boundary = np.column_stack(((xx+.5)/grid, (yy+.5)/grid))
    distance = np.zeros(len(uv))
    for start in range(0, len(uv), 256):
        offsets = uv[start:start+256, None] - boundary[None]
        distance[start:start+256] = np.sqrt(np.sum(offsets*offsets, axis=2).min(axis=1))
    # Convex cross sections give stone chips and hanging forms a rounded body;
    # a small boundary thickness retains closed, nonzero contour walls.
    value = np.sqrt(np.maximum(distance - .35/grid, 0) / max(float(distance.max()), 1e-6))
    return _remember(_DEPTH_CACHE, key, np.clip(value, 0, 1))


def _sculpted_offsets(profile, span, uv, alpha_key, alpha):
    if profile == "fruit_cluster":
        # UV centres measured from the original three round coloured forms.
        lobes = []
        for cx, cy, rx, ry, bias in ((.49, .39, .22, .43, -.12),
                                   (.25, .67, .22, .43, 0.),
                                   (.76, .67, .22, .43, 0.)):
            radius2 = ((uv[:, 0]-cx)/rx)**2 + ((uv[:, 1]-cy)/ry)**2
            lobes.append(np.maximum(np.sqrt(np.maximum(1-radius2, 0))+bias, 0))
        rounded = np.max(lobes, axis=0)
        radius = min(span*.15, .36)
        return radius*(.025+rounded), -radius*(.025+.85*rounded)
    if profile in {"warning_badge", "end_ornament", "shield"}:
        cx, cy, rx, ry = ((.5, .5, .48, .48) if profile == "warning_badge"
                         else (.98, .5, .96, .51))
        rounded = np.sqrt(np.maximum(1-((uv[:, 0]-cx)/rx)**2-((uv[:, 1]-cy)/ry)**2, 0))
        radius = min(span*(.025 if profile == "warning_badge" else .080), .025 if profile == "warning_badge" else .18)
        thickness = min(span*.025, .045)
        return radius*rounded+thickness*.5, radius*rounded-thickness*.5
    rounded = _rounded_mask_depth(alpha_key, alpha, uv)
    radius = min(span*(.11 if profile == "stone_fragments" else .085), .20)
    if profile == "stone_fragments":
        # Low-frequency asymmetric planes, not a high-frequency bitmap bump.
        variation = .88 + .12*np.sin(uv[:, 0]*21.+uv[:, 1]*11.)*np.cos(uv[:, 1]*17.)
        return radius*(.035+rounded)*variation, -radius*(.035+.8*rounded)/variation
    return radius*(.03+rounded), -radius*(.03+rounded)


def augment_cutout_surface(surface: dict, context: dict) -> dict:
    """Append genuine alpha-constrained shells without changing source motion."""
    key = str(context.get("source_texture_key", ""))
    profile = CUTOUT_PROFILES.get(key, WORLD_CUTOUT_PROFILES.get(key, SCULPTED_CUTOUT_PROFILES.get(key)))
    if profile is None:
        return surface
    roles = set(context.get("owner_classes", []))
    if key in CUTOUT_PROFILES and roles and not roles.intersection({"Hugo", "CSimpleStateActor"}):
        return surface
    original = context.get("original_surface", surface)
    if original.get("uv") is None or not len(original.get("indices", [])):
        return surface
    replacement = context.get("replacement_alpha")
    alpha = replacement if replacement is not None else context.get("source_alpha")
    if alpha is None:
        result = dict(surface)
        result["cutout_geometry"] = {"profile": profile, "applied": False, "reason": "alpha_unavailable"}
        return result
    alpha = np.asarray(alpha, np.uint8)
    if alpha.ndim != 2 or not alpha.size:
        raise ValueError("Cutout alpha must be a nonempty HxW uint8 array")
    source_size = context.get("source_texture_size", (32, 32))
    groups = _components(original)
    arrays = {name: [np.asarray(surface[name])] for name in
              ("positions", "normals", "colors", "source_ids", "source_weights", "indices", "triangle_origin", "collision_mask", "collision_surface_types")}
    for name in ("uv", "uv2"):
        arrays[name] = [np.asarray(surface[name])] if surface.get(name) is not None else None
    next_vertex = surface["positions"].shape[1]
    added_front = added_walls = built = skipped = 0
    skipped_reasons = []
    tessellation = []
    max_offset = 0.
    for component in groups:
        domain_faces = np.asarray(original["indices"])[component]
        selected = np.unique(domain_faces)
        points = np.asarray(original["positions"])[:, selected]
        spread = points - points.mean(axis=1, keepdims=True)
        singular = np.linalg.svd(spread, compute_uv=False)
        if np.any(singular[:, -1] / np.maximum(singular[:, 0], 1e-12) > .20):
            skipped += 1
            skipped_reasons.append({"first_source_face": int(component[0]), "reason": "source_already_nonplanar"})
            continue
        span = float(np.linalg.norm(spread, axis=2).max() * 2)
        domain_uv = np.asarray(original["uv"])[domain_faces]
        if span < 1e-5 or domain_uv.min() < -1e-6 or domain_uv.max() > 1+1e-6:
            skipped += 1
            skipped_reasons.append({"first_source_face": int(component[0]),
                                    "reason": "collapsed_source" if span < 1e-5 else "uv_outside_unit_tile",
                                    "uv_min": domain_uv.min(axis=(0, 1)).tolist(), "uv_max": domain_uv.max(axis=(0, 1)).tolist()})
            continue
        bounded = _bounded_layout(alpha, source_size, domain_uv, profile)
        if bounded is None:
            skipped += 1
            skipped_reasons.append({"first_source_face": int(component[0]), "reason": "no_opaque_layout"})
            continue
        alpha_key, layout, resolution, triangle_cost, triangle_budget = bounded
        tessellation.append({"first_source_face": int(component[0]), "grid": list(resolution),
                             "triangles": triangle_cost, "triangle_budget": triangle_budget,
                             "over_budget_for_hole_preservation": triangle_cost > triangle_budget})
        uv, anchors, bary, front = layout
        anchors = np.asarray(component)[anchors]
        source_faces = np.asarray(original["indices"])[anchors]
        provenance = _provenance(original, source_faces, bary)
        if provenance is None:
            skipped += 1
            skipped_reasons.append({"first_source_face": int(component[0]), "reason": "native_provenance_exceeds_three_ids"})
            continue
        source_ids, source_weights = provenance
        callback, normal_callback = context.get("surface_evaluator"), context.get("normal_evaluator")
        base = np.stack([callback(int(face), bc) if callback else
                         np.einsum('i,pic->pc', bc, original["positions"][:, triangle])
                         for face, triangle, bc in zip(anchors, source_faces, bary)], axis=1)
        if normal_callback:
            normal = np.stack([normal_callback(int(face), bc) for face, bc in zip(anchors, bary)], axis=1)
        else:
            triangles = original["positions"][:, source_faces]
            normal = np.cross(triangles[:, :, 1]-triangles[:, :, 0], triangles[:, :, 2]-triangles[:, :, 0])
        normal = _unit(normal)
        triangles = original["positions"][:, source_faces]
        area = np.linalg.norm(np.cross(triangles[:, :, 1]-triangles[:, :, 0], triangles[:, :, 2]-triangles[:, :, 0]), axis=-1)
        # A source part may start collapsed and expand in a later action.
        # Normalize against its largest authored pose, never a zero bind area.
        scale = np.sqrt(area / np.maximum(area.max(axis=0, keepdims=True), 1e-12))
        local = (uv-domain_uv.reshape(-1, 2).min(axis=0)) / np.maximum(np.ptp(domain_uv.reshape(-1, 2), axis=0), 1e-6)
        interior = np.maximum(np.sin(np.pi*local[:, 0]) * np.sin(np.pi*local[:, 1]), 0.)
        if profile in _DIMENSIONS:
            width, bend = _DIMENSIONS[profile]
            # Window frames carry most material near UV boundaries. Their beams
            # must keep structural depth there instead of tapering like a leaf.
            depth_shape = np.ones_like(interior) if profile in {"wood", "metal"} else (
                .6 + .4*interior if profile == "chain" else .25 + .75*interior)
            thickness = min(span*width, .08) * depth_shape
            curvature = min(span, .08/width) * bend * interior
            high, low = curvature+thickness*.5, curvature-thickness*.5
        else:
            high, low = _sculpted_offsets(profile, span, uv, alpha_key, alpha)
        high, low = high[None]*scale, low[None]*scale
        positions = np.concatenate((base + normal*high[..., None], base + normal*low[..., None]), axis=1)
        max_offset = max(max_offset, float(np.abs(high).max()), float(np.abs(low).max()))
        front = front.copy()
        winding_by_pose = np.einsum('pij,pij->pi', np.cross(positions[:, front[:, 1]]-positions[:, front[:, 0]],
                                                       positions[:, front[:, 2]]-positions[:, front[:, 0]]), normal[:, front].mean(axis=2))
        strongest = np.abs(winding_by_pose).argmax(axis=0)
        winding = winding_by_pose[strongest, np.arange(len(front))]
        front[winding < 0] = front[winding < 0, ::-1]
        boundary = defaultdict(list)
        for index, face in enumerate(front):
            for a, b in zip(face, np.roll(face, -1)):
                boundary[tuple(sorted((int(a), int(b))))].append((int(a), int(b), index))
        count = len(uv)
        walls, wall_anchors = [], []
        for uses in boundary.values():
            if len(uses) == 1:
                a, b, face = uses[0]
                walls.extend(((a, a+count, b+count), (a, b+count, b)))
                wall_anchors.extend((anchors[front[face, 0]],)*2)
        walls = np.asarray(walls, np.uint32).reshape(-1, 3)
        faces = np.concatenate((front, front[:, ::-1]+count, walls))
        normals = np.zeros_like(positions)
        for pose in range(len(positions)):
            tri = positions[pose, faces]
            cross = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
            for corner in range(3):
                np.add.at(normals[pose], faces[:, corner], cross)
        colors = np.einsum('ni,nic->nc', bary, original["colors"][source_faces])
        origins = np.concatenate((anchors[front[:, 0]], anchors[front[:, 0]], wall_anchors)).astype(np.int32)
        origin_table = original.get("triangle_origin")
        origin_values = np.asarray(origin_table)[origins] if origin_table is not None else np.column_stack((np.full(len(origins), int(context.get("surface_index", 0))), origins))
        arrays["positions"].append(positions.astype(np.float32))
        arrays["normals"].append(_unit(normals).astype(np.float32))
        arrays["colors"].append(np.tile(colors, (2, 1)).astype(np.float32))
        arrays["source_ids"].append(np.tile(source_ids, (2, 1)))
        arrays["source_weights"].append(np.tile(source_weights, (2, 1)))
        arrays["uv"].append(np.tile(uv, (2, 1)).astype(np.float32))
        if arrays["uv2"] is not None:
            part = original["uv2"][source_faces[:, 0], 1] if original.get("uv2") is not None else np.full(count, surface.get("part_index", -1))
            arrays["uv2"].append(np.tile(np.column_stack((np.full(count, -1), part)), (2, 1)).astype(np.float32))
        arrays["indices"].append((faces+next_vertex).astype(np.uint32))
        arrays["triangle_origin"].append(origin_values.astype(np.int32))
        arrays["collision_mask"].append(np.zeros(len(faces), bool))
        arrays["collision_surface_types"].append(np.full(len(faces), -1, np.int32))
        next_vertex += len(positions[0])
        added_front += len(front)
        added_walls += len(walls)
        built += 1
    result = dict(surface)
    for name, values in arrays.items():
        result[name] = np.concatenate(values, axis=1 if name in {"positions", "normals"} else 0) if values is not None else None
    result["lod_indices"] = dict(surface.get("lod_indices", {}))
    if built:
        if result["lod_indices"]:
            # Existing PN LODs contain only the underlying card. Their error
            # must include the disappearing volume, otherwise a nearby curved
            # tuft could flatten as soon as its base mesh chooses a coarse LOD.
            adjusted, previous = {}, 0.
            for error, indices in sorted(result["lod_indices"].items()):
                threshold = max(float(error)+max_offset, 2*max_offset, previous+1e-6)
                adjusted[threshold] = indices
                previous = threshold
            result["lod_indices"] = adjusted
        else:
            result["lod_indices"][max(max_offset*2, .025)] = np.asarray(surface["indices"]).copy()
    result["cutout_geometry"] = {
        "method": "alpha_constrained_curved_shells", "profile": profile, "applied": bool(built),
        "source_texture_key": key, "alpha_source": "replacement" if replacement is not None else "source",
        "components": len(groups), "volumetric_components": built, "skipped_components": skipped,
        "skipped_reasons": skipped_reasons,
        "volume_profile": profile,
        "component_tessellation": tessellation,
        "added_vertices": next_vertex-surface["positions"].shape[1],
        "added_triangles": 2*added_front+added_walls, "front_triangles": added_front, "contour_wall_triangles": added_walls,
        "maximum_normal_offset_metres": max_offset, "morph_poses": original["positions"].shape[0],
        "lod_volume_error_floor_metres": 2*max_offset,
        "source_alpha_fringe_retained": True, "transparent_holes_not_capped": True,
        "added_collision": False, "coarse_lod_preserves_source_card": True,
    }
    return result
