"""Finish proven open foliage sheets skipped by the frozen planar-card pass.

A bend is not thickness. This separate, fingerprinted finishing stage requires
an open manifold source and a non-overlapping UV domain before adding a closed
alpha-constrained shell. A rank-one UV triangle is handled in its physical
barycentric domain, preserving that UV mapping rather than inventing new UVs.
The base pass and all original positions, motion and collision remain intact.
"""
from __future__ import annotations

from collections import OrderedDict, defaultdict
import hashlib

import numpy as np

from .cutout_geometry import (
    CUTOUT_PROFILES, WORLD_CUTOUT_PROFILES, SCULPTED_CUTOUT_PROFILES, _DIMENSIONS,
    _TESSELLATION, _alpha_triangles, _clip_to_triangle, _components, _cross2,
    _provenance, _remember, _sample_alpha, _sculpted_offsets, _unit,
)


_PROFILES = {**CUTOUT_PROFILES, **WORLD_CUTOUT_PROFILES, **SCULPTED_CUTOUT_PROFILES}
SOURCE_KEYS = set(_PROFILES)
_REASONS = {"source_already_nonplanar", "no_opaque_layout", "verified_cutout_construction"}
_SHEET_LAYOUT_CACHE = OrderedDict()


def _constrained_layout(alpha_key, masked, domain_uv):
    """Clip the same hole-safe mask, with length-normalized edge conformity.

    Comparing an unnormalized 2D cross product to a fixed epsilon is unsafe
    near a very short clipped edge: nearby off-edge points can be inserted into
    its perimeter and create overlapping fans. Distances here stay in UV units.
    """
    key = (alpha_key, hashlib.sha256(np.asarray(domain_uv, '<f8').tobytes()).digest())
    if key in _SHEET_LAYOUT_CACHE:
        return _SHEET_LAYOUT_CACHE[key]
    if not len(masked):
        return None
    points, owners, barycentric, faces, face_owners = [], [], [], [], []
    unique, seen = {}, set()
    low, high = masked.min(axis=1), masked.max(axis=1)
    for anchor, domain in enumerate(domain_uv):
        matrix = np.column_stack((domain[1]-domain[0], domain[2]-domain[0]))
        if abs(np.linalg.det(matrix)) < 1e-12:
            continue
        inverse = np.linalg.inv(matrix)
        candidates = np.flatnonzero(np.all(high >= domain.min(axis=0)-1e-10, axis=1) &
                                    np.all(low <= domain.max(axis=0)+1e-10, axis=1))
        for candidate in candidates:
            polygon = _clip_to_triangle(list(masked[candidate]), domain)
            for index in range(1, len(polygon)-1):
                triangle = np.asarray((polygon[0], polygon[index], polygon[index+1]))
                if abs(_cross2(triangle[1]-triangle[0], triangle[2]-triangle[0])) < 1e-13:
                    continue
                vertices = []
                for point in triangle:
                    signature = tuple(np.round(point, 8))
                    if signature not in unique:
                        bc = inverse@(point-domain[0])
                        weights = np.maximum((1-bc.sum(), bc[0], bc[1]), 0.)
                        weights /= weights.sum()
                        unique[signature] = len(points)
                        points.append(point)
                        owners.append(anchor)
                        barycentric.append(weights)
                    vertices.append(unique[signature])
                signature = tuple(sorted(vertices))
                if len(set(vertices)) == 3 and signature not in seen:
                    seen.add(signature)
                    faces.append(vertices)
                    face_owners.append(anchor)
    if not faces:
        return None
    coordinates = np.asarray(points)
    bins, edge_cache = defaultdict(set), {}
    for index, point in enumerate(coordinates):
        bins[tuple(np.floor(point*64).astype(int))].add(index)

    def edge_points(a, b):
        edge = (min(a, b), max(a, b))
        if edge not in edge_cache:
            start, finish = coordinates[list(edge)]
            vector = finish-start
            length = float(np.linalg.norm(vector))
            lo = np.floor(np.minimum(start, finish)*64).astype(int)-1
            hi = np.floor(np.maximum(start, finish)*64).astype(int)+1
            candidates = set()
            for y in range(lo[1], hi[1]+1):
                for x in range(lo[0], hi[0]+1):
                    candidates.update(bins.get((x, y), ()))
            interior = []
            if length > 2e-8:
                for index in candidates:
                    offset = coordinates[index]-start
                    distance = float(np.dot(offset, vector)/length)
                    if 1e-8 < distance < length-1e-8 and abs(_cross2(vector, offset))/length < 1e-8:
                        interior.append((distance, index))
            edge_cache[edge] = [edge[0], *(index for _, index in sorted(interior)), edge[1]]
        ordered = edge_cache[edge]
        return ordered if a == edge[0] else ordered[::-1]

    conformed = []
    for face, anchor in zip(faces, face_owners):
        perimeter = []
        for a, b in zip(face, np.roll(face, -1)):
            perimeter.extend(edge_points(int(a), int(b))[:-1])
        if len(perimeter) == 3:
            conformed.append(face)
            continue
        center = coordinates[face].mean(axis=0)
        domain = domain_uv[anchor]
        bc = np.linalg.solve(np.column_stack((domain[1]-domain[0], domain[2]-domain[0])), center-domain[0])
        weights = np.maximum((1-bc.sum(), bc[0], bc[1]), 0.)
        weights /= weights.sum()
        at = len(points)
        points.append(center)
        owners.append(anchor)
        barycentric.append(weights)
        for a, b in zip(perimeter, np.roll(perimeter, -1)):
            conformed.append((at, int(a), int(b)))
    layout = _clean_layout((np.asarray(points), np.asarray(owners), np.asarray(barycentric), np.asarray(conformed, np.uint32)))
    return _remember(_SHEET_LAYOUT_CACHE, key, layout)


def _bounded_sheet_layout(alpha, source_size, domain_uv, profile):
    longest, budget = _TESSELLATION[profile]
    aspect = np.asarray(source_size, np.float64)/max(max(source_size), 1)
    result = None
    while True:
        resolution = tuple(int(max(4, round(value*longest))) for value in aspect)
        alpha_key, masked = _alpha_triangles(alpha, resolution)
        layout = _constrained_layout(alpha_key, masked, domain_uv)
        if layout is None or not len(layout[3]):
            return result
        edges = defaultdict(int)
        for face in layout[3]:
            for a, b in zip(face, np.roll(face, -1)):
                edges[tuple(sorted((int(a), int(b))))] += 1
        triangles = 2*len(layout[3])+2*sum(count == 1 for count in edges.values())
        result = alpha_key, layout, resolution, triangles, budget
        if triangles <= budget or longest <= 4:
            return result
        longest = max(4, int(longest*.75))


def _open_sheet_proof(original, component):
    """Use physical topology, not SVD, to distinguish an open sheet from volume."""
    faces = np.asarray(original["indices"])[component]
    selected = np.unique(faces)
    signatures = np.asarray(original["positions"])[:, selected].transpose(1, 0, 2).reshape(len(selected), -1)
    vertices, welded = {}, {}
    for vertex, row in zip(selected, signatures):
        welded[int(vertex)] = vertices.setdefault(tuple(np.round(row, 7)), len(vertices))
    edges, seen = defaultdict(int), set()
    for source_face in faces:
        face = [welded[int(vertex)] for vertex in source_face]
        signature = tuple(sorted(face))
        if len(set(face)) != 3 or signature in seen:
            return {"accepted": False, "reason": "degenerate_or_duplicate_physical_face"}
        seen.add(signature)
        for a, b in zip(face, np.roll(face, -1)):
            edges[tuple(sorted((int(a), int(b))))] += 1
    boundary = sum(count == 1 for count in edges.values())
    if not boundary or any(count > 2 for count in edges.values()):
        return {"accepted": False, "reason": "closed_or_nonmanifold_source", "boundary_edges": boundary}
    uv = np.asarray(original["uv"])[faces]
    signed = _cross2(uv[:, 1]-uv[:, 0], uv[:, 2]-uv[:, 0])
    if np.any(np.abs(signed) < 1e-12):
        if len(faces) == 1 and np.linalg.matrix_rank(uv[0]-uv[0, 0], tol=1e-10) == 1:
            return {"accepted": True, "method": "physical_triangle_rank_one_uv", "boundary_edges": boundary}
        return {"accepted": False, "reason": "noninvertible_uv_domain", "boundary_edges": boundary}
    if np.any(signed > 0) and np.any(signed < 0):
        return {"accepted": False, "reason": "folded_uv_orientation", "boundary_edges": boundary}
    for index, triangle in enumerate(uv):
        for other in uv[index+1:]:
            if np.any(other.max(axis=0) <= triangle.min(axis=0)+1e-10) or np.any(other.min(axis=0) >= triangle.max(axis=0)-1e-10):
                continue
            polygon = _clip_to_triangle(list(triangle), other)
            if len(polygon) >= 3:
                polygon = np.asarray(polygon)
                area = abs(float(np.sum(_cross2(polygon, np.roll(polygon, -1, axis=0)))))*.5
                if area > 1e-9:
                    return {"accepted": False, "reason": "overlapping_uv_domain", "boundary_edges": boundary}
    return {"accepted": True, "method": "open_manifold_injective_uv", "boundary_edges": boundary}


def _opaque_line_intervals(alpha, start, finish):
    """Exact threshold intervals of bilinear alpha along one source UV line.

    Within each crossed texel cell alpha is quadratic in line position. Its
    roots preserve even a one-texel transparent gap without a downsampled mask.
    """
    h, w = alpha.shape
    direction = finish-start
    breaks = {0., 1.}
    for axis, size in enumerate((w, h)):
        if abs(direction[axis]) < 1e-14:
            continue
        for coordinate in (np.arange(size)+.5)/size:
            t = (coordinate-start[axis])/direction[axis]
            if 0 < t < 1:
                breaks.add(float(t))
    edges = sorted(breaks)
    intervals = []
    for left, right in zip(edges, edges[1:]):
        def value(t):
            return _sample_alpha(alpha, start+direction*t)-.45
        c, midpoint, end = value(left), value((left+right)*.5), value(right)
        a = 2*(end+c-2*midpoint)
        b = end-c-a
        local = [0., 1.]
        if abs(a) > 1e-12:
            discriminant = b*b-4*a*c
            if discriminant >= 0:
                root = np.sqrt(discriminant)
                local.extend(t for t in ((-b-root)/(2*a), (-b+root)/(2*a)) if 0 < t < 1)
        elif abs(b) > 1e-12 and 0 < -c/b < 1:
            local.append(-c/b)
        local.sort()
        for first, last in zip(local, local[1:]):
            if value(left+(right-left)*(first+last)*.5) < 0:
                continue
            lo, hi = left+(right-left)*first, left+(right-left)*last
            if intervals and abs(intervals[-1][1]-lo) < 1e-10:
                intervals[-1] = (intervals[-1][0], hi)
            else:
                intervals.append((lo, hi))
    return intervals


def _partition_uv_charts(original, component):
    """Separate overlapping UV layers without joining different 3D locations."""
    faces = np.asarray(original['indices'])
    positions = original['positions'].transpose(1, 0, 2).reshape(original['positions'].shape[1], -1)
    vertices, welded = {}, []
    for row in np.column_stack((positions, original['uv'])):
        welded.append(vertices.setdefault(tuple(np.round(row, 7)), len(vertices)))
    edges = defaultdict(list)
    for face_index in component:
        face = np.asarray(welded)[faces[face_index]]
        for a, b in zip(face, np.roll(face, -1)):
            edges[tuple(sorted((int(a), int(b))))].append(face_index)
    neighbours = defaultdict(set)
    for uses in edges.values():
        for face_index in uses:
            neighbours[face_index].update(uses)
    remaining, charts = set(component), []
    while remaining:
        first = min(remaining)
        chart = [first]
        if not _open_sheet_proof(original, chart)['accepted']:
            return None
        remaining.remove(first)
        candidates = set(neighbours[first]) & remaining
        while candidates:
            candidate = min(candidates)
            candidates.remove(candidate)
            proof = _open_sheet_proof(original, chart+[candidate])
            if not proof['accepted'] or proof['method'] != 'open_manifold_injective_uv':
                continue
            chart.append(candidate)
            remaining.remove(candidate)
            candidates.update(neighbours[candidate] & remaining)
        charts.append(sorted(chart))
    return charts


def _unique_volume_domain(original, component):
    """Avoid duplicate shells on coincident, identically attributed faces.

    Original reverse faces stay intact. For animated materials, native IDs and
    weights must also coincide; identical bind colours alone are insufficient.
    """
    positions = original['positions'].transpose(1, 0, 2).reshape(original['positions'].shape[1], -1)
    attributes = [positions, original['uv'], original['colors']]
    if original.get('native_material_key') != '':
        attributes.extend((original['source_ids'], original['source_weights']))
    signatures = np.column_stack(attributes)
    vertices = [tuple(np.round(row, 7)) for row in signatures]
    unique, kept, aliases = {}, [], []
    for face in component:
        signature = tuple(sorted(vertices[int(vertex)] for vertex in original['indices'][face]))
        if signature in unique:
            aliases.append({'source_face': int(face), 'volume_anchor_face': int(unique[signature])})
        else:
            unique[signature] = int(face)
            kept.append(int(face))
    return kept, aliases


def _rank_one_layout(alpha, domain_uv):
    distances = np.sum((domain_uv[:, None]-domain_uv[None, :])**2, axis=2)
    first, last = np.unravel_index(np.argmax(distances), distances.shape)
    start, finish = domain_uv[first], domain_uv[last]
    direction = finish-start
    values = (domain_uv-start)@direction/np.dot(direction, direction)
    domain = np.asarray(((0., 0.), (1., 0.), (0., 1.)))
    intervals = _opaque_line_intervals(alpha, start, finish)
    triangles = []
    for low, high in intervals:
        polygon = list(domain)
        for limit, sign in ((low, 1.), (high, -1.)):
            clipped = []
            previous = polygon[-1] if polygon else None
            def scalar(point):
                return values[0]+point[0]*(values[1]-values[0])+point[1]*(values[2]-values[0])
            previous_value = sign*(scalar(previous)-limit) if previous is not None else 0.
            for point in polygon:
                value = sign*(scalar(point)-limit)
                if (value >= -1e-12) != (previous_value >= -1e-12):
                    clipped.append(previous+(point-previous)*(previous_value/(previous_value-value)))
                if value >= -1e-12:
                    clipped.append(point)
                previous, previous_value = point, value
            polygon = clipped
        for index in range(1, len(polygon)-1):
            triangle = np.asarray((polygon[0], polygon[index], polygon[index+1]))
            if abs(_cross2(triangle[1]-triangle[0], triangle[2]-triangle[0])) > 1e-12:
                # Two splits follow the actual PN evaluator across the triangle.
                children = [triangle]
                for _ in range(2):
                    refined = []
                    for a, b, c in children:
                        ab, bc, ca = (a+b)/2, (b+c)/2, (c+a)/2
                        refined.extend(((a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)))
                    children = refined
                triangles.extend(children)
    digest = hashlib.sha256(alpha.tobytes()+domain_uv.tobytes()).hexdigest()
    layout = _constrained_layout(("rank_one_alpha_intervals", digest), np.asarray(triangles).reshape(-1, 3, 2), domain[None])
    return layout, intervals


def _clean_layout(layout):
    """Remove numerical slivers where mask intersections meet shared UV edges.

    The tolerance is far below a texel of the authored masks. Re-splitting
    disconnected fans retains real regions that touch at only one UV point.
    """
    parameter, anchors, bary, faces = layout
    tolerance = 2e-7
    bins, points, owners, weights, remap = defaultdict(list), [], [], [], []
    for point, anchor, bc in zip(parameter, anchors, bary):
        cell = tuple(np.floor(point/tolerance).astype(np.int64))
        found = None
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for index in bins.get((cell[0]+dx, cell[1]+dy), ()):
                    if np.linalg.norm(points[index]-point) <= tolerance:
                        found = index
                        break
                if found is not None:
                    break
            if found is not None:
                break
        if found is None:
            found = len(points)
            points.append(point)
            owners.append(anchor)
            weights.append(bc)
            bins[cell].append(found)
        remap.append(found)
    kept, seen = [], set()
    for face in np.asarray(remap)[faces]:
        signature = tuple(sorted(int(value) for value in face))
        if len(set(signature)) != 3 or signature in seen:
            continue
        triangle = np.asarray(points)[face]
        longest = float(np.linalg.norm(triangle-np.roll(triangle, -1, axis=0), axis=1).max())
        if abs(_cross2(triangle[1]-triangle[0], triangle[2]-triangle[0])) < tolerance*longest:
            continue
        seen.add(signature)
        kept.append(face)
    faces = np.asarray(kept, np.uint32).reshape(-1, 3)
    incident = defaultdict(list)
    for face_index, face in enumerate(faces):
        for vertex in face:
            incident[int(vertex)].append(face_index)
    for vertex, uses in incident.items():
        by_neighbour = defaultdict(list)
        for face_index in uses:
            for neighbour in faces[face_index]:
                if int(neighbour) != vertex:
                    by_neighbour[int(neighbour)].append(face_index)
        graph = defaultdict(set)
        for neighbours in by_neighbour.values():
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
            owners.append(owners[vertex])
            weights.append(weights[vertex])
            for face_index in fan:
                faces[face_index, faces[face_index] == vertex] = replacement
    used = np.unique(faces)
    remap = np.full(len(points), -1, np.int64)
    remap[used] = np.arange(len(used))
    return np.asarray(points)[used], np.asarray(owners)[used], np.asarray(weights)[used], remap[faces].astype(np.uint32)


def _append_shell(surface, original, component, context, layout, rank_one=False):
    parameter, local_anchors, bary, front = _clean_layout(layout)
    if not len(front):
        return surface, {"applied": False, "reason": "numerically_empty_opaque_layout"}
    anchors = np.asarray(component)[local_anchors]
    source_faces = np.asarray(original["indices"])[anchors]
    provenance = _provenance(original, source_faces, bary)
    if provenance is None:
        return surface, {"applied": False, "reason": "native_provenance_exceeds_three_ids"}
    ids, weights = provenance
    callback, normal_callback = context.get("surface_evaluator"), context.get("normal_evaluator")
    base = np.stack([callback(int(face), bc) if callback else np.einsum('i,pic->pc', bc, original["positions"][:, tri])
                     for face, tri, bc in zip(anchors, source_faces, bary)], axis=1)
    triangles = original["positions"][:, source_faces]
    face_normals = np.cross(triangles[:, :, 1]-triangles[:, :, 0], triangles[:, :, 2]-triangles[:, :, 0])
    normal = np.stack([normal_callback(int(face), bc) for face, bc in zip(anchors, bary)], axis=1) if normal_callback else face_normals
    normal = _unit(normal)
    area = np.linalg.norm(face_normals, axis=-1)
    scale = np.sqrt(area/np.maximum(area.max(axis=0, keepdims=True), 1e-12))
    selected = np.unique(np.asarray(original["indices"])[component])
    points = original["positions"][:, selected]
    span = float(np.linalg.norm(points-points.mean(axis=1, keepdims=True), axis=-1).max()*2)
    source_domain = np.asarray(original['uv'])[np.asarray(original['indices'])[component]].reshape(-1, 2)
    domain = np.asarray(((0., 0.), (1., 1.))) if rank_one else source_domain
    local = (parameter-domain.min(axis=0))/np.maximum(np.ptp(domain, axis=0), 1e-6)
    interior = np.maximum(np.sin(np.pi*local[:, 0])*np.sin(np.pi*local[:, 1]), 0)
    profile = _PROFILES.get(str(context.get('source_texture_key', '')), 'leaf')
    uv = np.einsum('ni,nic->nc', bary, original['uv'][source_faces]) if rank_one else parameter
    if profile in _DIMENSIONS:
        width, bend = _DIMENSIONS[profile]
        depth_shape = np.ones_like(interior) if profile in {'wood', 'metal'} else (
            .6+.4*interior if profile == 'chain' else .25+.75*interior)
        thickness = min(span*width, .08)*depth_shape
        curvature = min(span, .08/width)*bend*interior
        high, low = curvature+thickness*.5, curvature-thickness*.5
    else:
        alpha = context.get('replacement_alpha')
        if alpha is None:
            alpha = context['source_alpha']
        alpha = np.asarray(alpha, np.uint8)
        alpha_key = (alpha.shape, hashlib.sha256(alpha.tobytes()).digest())
        high, low = _sculpted_offsets(profile, span, uv, alpha_key, alpha)
    high, low = high[None]*scale, low[None]*scale
    positions = np.concatenate((base+normal*high[..., None], base+normal*low[..., None]), axis=1)
    front = front.copy()
    winding = np.einsum('pij,pij->pi', np.cross(positions[:, front[:, 1]]-positions[:, front[:, 0]],
                                            positions[:, front[:, 2]]-positions[:, front[:, 0]]), normal[:, front].mean(axis=2))
    strongest = np.abs(winding).argmax(axis=0)
    front[winding[strongest, np.arange(len(front))] < 0] = front[winding[strongest, np.arange(len(front))] < 0, ::-1]
    count = len(parameter)
    edges = defaultdict(list)
    for index, face in enumerate(front):
        for a, b in zip(face, np.roll(face, -1)):
            edges[tuple(sorted((int(a), int(b))))].append((int(a), int(b), index))
    if any(len(uses) > 2 for uses in edges.values()):
        return surface, {"applied": False, "reason": "nonmanifold_alpha_layout"}
    walls, wall_anchors = [], []
    for uses in edges.values():
        if len(uses) == 1:
            a, b, face = uses[0]
            walls.extend(((a, a+count, b+count), (a, b+count, b)))
            wall_anchors.extend((anchors[front[face, 0]],)*2)
    faces = np.concatenate((front, front[:, ::-1]+count, np.asarray(walls, np.uint32).reshape(-1, 3)))
    incidence = defaultdict(int)
    for face in faces:
        for a, b in zip(face, np.roll(face, -1)):
            incidence[tuple(sorted((int(a), int(b))))] += 1
    if any(value != 2 for value in incidence.values()):
        return surface, {"applied": False, "reason": "nonmanifold_contour_wall"}
    normals = np.zeros_like(positions)
    for pose in range(len(positions)):
        tri = positions[pose, faces]
        crosses = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
        for corner in range(3):
            np.add.at(normals[pose], faces[:, corner], crosses)
    origins = np.concatenate((anchors[front[:, 0]], anchors[front[:, 0]], wall_anchors)).astype(np.int32)
    colors = np.einsum('ni,nic->nc', bary, original['colors'][source_faces])
    added = {"positions": positions, "normals": _unit(normals), "uv": np.tile(uv, (2, 1)),
             "colors": np.tile(colors, (2, 1)), "source_ids": np.tile(ids, (2, 1)),
             "source_weights": np.tile(weights, (2, 1)), "indices": faces+surface['positions'].shape[1],
             "triangle_origin": original['triangle_origin'][origins],
             "collision_mask": np.zeros(len(faces), bool), "collision_surface_types": np.full(len(faces), -1)}
    if surface.get('uv2') is not None:
        part = original['uv2'][source_faces[:, 0], 1]
        added['uv2'] = np.tile(np.column_stack((np.full(count, -1), part)), (2, 1))
    result = dict(surface)
    for name, values in added.items():
        result[name] = np.concatenate((surface[name], values.astype(surface[name].dtype)), axis=1 if name in {'positions', 'normals'} else 0)
    offset = max(float(np.abs(high).max()), float(np.abs(low).max()))
    # The caller adjusts disappearance error once using the maximum offset.
    # Summing it per chart would postpone LODs on many-leaf plants needlessly.
    result['lod_indices'] = dict(surface.get('lod_indices', {}))
    return result, {'applied': True, 'added_vertices': 2*count, 'added_triangles': len(faces),
                    'front_triangles': len(front), 'contour_wall_triangles': len(walls),
                    'maximum_normal_offset_metres': offset}


def augment_curved_cutout_surface(surface: dict, context: dict) -> dict:
    """Append volume only to proven sheets skipped by the frozen base pass."""
    key = str(context.get('source_texture_key', ''))
    prior = surface.get('cutout_geometry', {})
    pending = {int(row['first_source_face']): row['reason'] for row in prior.get('skipped_reasons', [])
               if row.get('reason') in _REASONS}
    if key not in SOURCE_KEYS or not pending:
        return surface
    original = context.get('original_surface', surface)
    replacement = context.get('replacement_alpha')
    alpha = replacement if replacement is not None else context.get('source_alpha')
    if alpha is None or original.get('uv') is None:
        return surface
    alpha = np.asarray(alpha, np.uint8)
    result = surface
    evidence, finished = [], set()
    for component in _components(original):
        first = int(component[0])
        if first not in pending:
            continue
        proof = _open_sheet_proof(original, component)
        row = {'first_source_face': first, 'original_skip': pending[first], 'proof': proof}
        domain_component = component
        if proof.get('reason') == 'degenerate_or_duplicate_physical_face':
            domain_component, aliases = _unique_volume_domain(original, component)
            if aliases:
                row['coincident_source_faces_retained'] = aliases
                proof = _open_sheet_proof(original, domain_component)
                row['unique_volume_domain_proof'] = proof
        charts = [domain_component] if proof['accepted'] else None
        if proof.get('reason') in {'overlapping_uv_domain', 'folded_uv_orientation', 'noninvertible_uv_domain'}:
            charts = _partition_uv_charts(original, domain_component)
            row['uv_chart_partition'] = 'connected_injective_source_charts'
        if charts is None:
            evidence.append(row)
            continue
        candidate, chart_rows = result, []
        profile = _PROFILES[key]
        for chart in charts:
            chart_proof = _open_sheet_proof(original, chart)
            chart_row = {'source_faces': chart, 'proof': chart_proof}
            # Intersect in float64. Float32 inverses create numerical slivers
            # along shared source UV edges, which are cleaned before closure.
            domain = np.asarray(original['uv'], np.float64)[np.asarray(original['indices'])[chart]]
            if domain.min() < -1e-6 or domain.max() > 1+1e-6:
                chart_row['reason'] = 'uv_outside_unit_tile'
                chart_rows.append(chart_row)
                break
            rank_one = chart_proof['method'] == 'physical_triangle_rank_one_uv'
            if rank_one:
                layout, intervals = _rank_one_layout(alpha, domain[0])
                chart_row['opaque_intervals'] = intervals
                row['opaque_intervals'] = intervals
            else:
                bounded = _bounded_sheet_layout(alpha, context.get('source_texture_size', (32, 32)), domain, profile)
                layout = bounded[1] if bounded else None
                if bounded:
                    chart_row.update(grid=list(bounded[2]), triangles=int(bounded[3]), triangle_budget=int(bounded[4]),
                                     over_budget_for_hole_preservation=bool(bounded[3] > bounded[4]))
            if layout is None:
                chart_row['reason'] = 'no_visible_alpha_interval' if rank_one else 'no_opaque_layout'
                chart_rows.append(chart_row)
                break
            candidate, info = _append_shell(candidate, original, chart, context, layout, rank_one)
            chart_row.update(info)
            chart_rows.append(chart_row)
            if not info.get('applied'):
                break
        row['charts'] = chart_rows
        if len(chart_rows) == len(charts) and all(chart.get('applied') for chart in chart_rows):
            result = candidate
            row['applied'] = True
            for name in ('added_vertices', 'added_triangles', 'front_triangles', 'contour_wall_triangles'):
                row[name] = sum(chart[name] for chart in chart_rows)
            row['maximum_normal_offset_metres'] = max(chart['maximum_normal_offset_metres'] for chart in chart_rows)
            finished.add(first)
        evidence.append(row)
    aggregate = dict(prior)
    aggregate['skipped_reasons'] = [row for row in prior.get('skipped_reasons', []) if int(row['first_source_face']) not in finished]
    aggregate['skipped_components'] = len(aggregate['skipped_reasons'])
    aggregate['volumetric_components'] = int(prior.get('volumetric_components', 0))+len(finished)
    aggregate['applied'] = bool(aggregate['volumetric_components'])
    for name in ('added_vertices', 'added_triangles', 'front_triangles', 'contour_wall_triangles'):
        aggregate[name] = int(prior.get(name, 0))+sum(int(row.get(name, 0)) for row in evidence)
    aggregate['maximum_normal_offset_metres'] = max([float(prior.get('maximum_normal_offset_metres', 0)),
                                                    *(float(row.get('maximum_normal_offset_metres', 0)) for row in evidence)])
    aggregate['lod_volume_error_floor_metres'] = 2*aggregate['maximum_normal_offset_metres']
    result = dict(result)
    if finished:
        added_offset = max(float(row.get('maximum_normal_offset_metres', 0)) for row in evidence)
        adjusted, previous = {}, 0.
        for error, indices in sorted(surface.get('lod_indices', {}).items()):
            threshold = max(float(error)+added_offset, aggregate['lod_volume_error_floor_metres'], previous+1e-6)
            adjusted[threshold] = indices
            previous = threshold
        if not adjusted:
            adjusted[max(aggregate['lod_volume_error_floor_metres'], .025)] = np.asarray(surface['indices']).copy()
        result['lod_indices'] = adjusted
    result['cutout_geometry'] = aggregate
    result['curved_cutout_geometry'] = {'method': 'proven_open_sheet_alpha_shells', 'source_texture_key': key,
        'applied': bool(finished), 'volumetric_components': len(finished), 'components': evidence,
        'alpha_source': 'replacement' if replacement is not None else 'source',
        'morph_poses': int(original['positions'].shape[0]), 'added_collision': False,
        'original_uv_mapping_retained': True, 'full_resolution_alpha_holes_retained': True}
    return result


def augment_verified_cutout_surface(surface: dict, context: dict) -> dict:
    """Build verified profile shells directly after semantic geometry.

    Used only by the scoped finishing stage for proven broken or unfinished
    resources. It does not append the frozen old shell first, so no duplicate
    volume or removal of source triangles is needed. Shape parameters remain
    those of the frozen profile definitions; normalized conformance repairs the
    topology, and physical-sheet proofs permit genuine bent/overlapping cards.
    """
    key = str(context.get('source_texture_key', ''))
    profile = _PROFILES.get(key)
    if profile is None:
        return surface
    roles = set(context.get('owner_classes', []))
    if key in CUTOUT_PROFILES and roles and not roles.intersection({'Hugo', 'CSimpleStateActor'}):
        return surface
    original = context.get('original_surface', surface)
    if original.get('uv') is None or not len(original.get('indices', [])):
        return surface
    groups = _components(original)
    result = dict(surface)
    result['cutout_geometry'] = {
        'method': 'verified_alpha_constrained_curved_shells', 'profile': profile,
        'volume_profile': profile, 'source_texture_key': key, 'applied': False,
        'components': len(groups), 'volumetric_components': 0, 'skipped_components': len(groups),
        'skipped_reasons': [{'first_source_face': int(group[0]), 'reason': 'verified_cutout_construction'} for group in groups],
        'added_vertices': 0, 'added_triangles': 0, 'front_triangles': 0, 'contour_wall_triangles': 0,
        'maximum_normal_offset_metres': 0., 'morph_poses': int(original['positions'].shape[0]),
        'source_alpha_fringe_retained': True, 'transparent_holes_not_capped': True,
        'added_collision': False, 'coarse_lod_preserves_source_card': True,
        'alpha_source': 'replacement' if context.get('replacement_alpha') is not None else 'source',
    }
    result = augment_curved_cutout_surface(result, context)
    result.setdefault('curved_cutout_geometry', {})['reconstructed_from_semantic_stage'] = True
    return result
