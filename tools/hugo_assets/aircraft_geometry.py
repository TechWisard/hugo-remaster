"""Source-specific aircraft role classification and closed airfoil skins.

The recovered Beach aircraft is one record containing body, damaged wings,
struts, propeller, wheels and tail. Its painted panels share materials; a
material-wide organic smoothing flag would bend the thin wings and emblems.
"""
from __future__ import annotations

from collections import defaultdict

import numpy as np


def is_aircraft(contexts):
    return bool(contexts) and int(contexts[0].get("source_group", -1)) == 7 and int(contexts[0].get("source_record", -1)) == 1


def curvature_roles(surfaces, contexts):
    limits, counts = [], {"body_or_wheel_faces": 0, "wing_tail_trim_faces": 0}
    # Axis through the measured cowling and rear fuselage, in the recovered
    # record's local metre coordinates. Detached wings extend far outside it.
    front = np.asarray([-4.72, 1.04, 1.455])
    axis = np.asarray([8.42, -3.04, -2.355]); axis /= np.linalg.norm(axis)
    for source, context in zip(surfaces, contexts):
        aliases = {(int(a["group"]), int(a["texture_id"])) for a in context.get("source_texture_aliases", [])}
        faces = source["positions"][0, source["indices"]]
        radial = faces - front
        radial -= (radial @ axis)[..., None] * axis
        body = np.max(np.linalg.norm(radial, axis=-1), axis=1) < 1.65
        if aliases & {(6, 291), (6, 289), (6, 351)}:
            body[:] = True
        if aliases & {(6, 349), (6, 290)}:
            body[:] = False
        limits.extend(np.where(body, 145., 65.))
        counts["body_or_wheel_faces"] += int(body.sum())
        counts["wing_tail_trim_faces"] += int((~body).sum())
    return np.asarray(limits), counts


def solidify_sheets(sources, refined, contexts, topology, subdivisions=4):
    """Give confirmed open, planar aircraft patches closed curved thickness.

    Closed body panels are excluded by their shared exterior edges. Footprints
    and source UVs stay fixed, with thin rounded skins on both sides and rim
    walls. Original prefixes remain available to the existing distant LOD.
    """
    from .bevel_geometry import _Surface, _unit
    points, faces = topology.positions, topology.faces
    tris = points[:, faces]
    normals = _unit(np.cross(tris[:, :, 1] - tris[:, :, 0], tris[:, :, 2] - tris[:, :, 0]))
    parent = list(range(len(faces)))
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for edge, uses in topology.edges.items():
        if len(uses) == 2:
            a, b = uses[0][0], uses[1][0]
            if np.all(np.sum(normals[:, a] * normals[:, b], axis=-1) > .995):
                parent[root(b)] = root(a)
    components = defaultdict(list)
    for face in range(len(faces)): components[root(face)].append(face)
    face_surface = np.empty(len(faces), np.int32); face_local = np.empty(len(faces), np.int32)
    for at, source in enumerate(sources):
        start = topology.face_offsets[at]
        face_surface[start:start+len(source["indices"])] = at
        face_local[start:start+len(source["indices"])] = np.arange(len(source["indices"]))
    selected = {}
    component_rows = []
    for component in components.values():
        component_set = set(component)
        boundary = []
        for edge, uses in topology.edges.items():
            inner = [(face, side) for face, side in uses if face in component_set]
            if len(inner) == 1:
                boundary.append((edge, inner[0], len(uses) == 1))
        if not boundary or sum(int(item[2]) for item in boundary) / len(boundary) < .70:
            continue
        vertices = np.unique(faces[component])
        base = points[0, vertices]
        centered = base - base.mean(axis=0)
        _, singular, basis = np.linalg.svd(centered, full_matrices=False)
        if len(singular) < 3 or singular[1] < .05 or singular[2] > singular[1] * .015:
            continue
        spans = np.ptp(centered @ basis[:2].T, axis=0)
        if spans.min() < .15 or spans.max() < .35:
            continue
        # Small physical thickness: preserve the damaged wing's proportions,
        # while removing the infinitely thin edge visible in free-camera views.
        width = min(float(spans.min()) * .045, .075)
        normal = _unit(normals[:, component].sum(axis=1))
        short_axis = basis[int(np.argmin(spans))]
        coordinates = centered @ short_axis
        low, high = float(coordinates.min()), float(coordinates.max())
        row = {"faces": component, "vertices": vertices, "boundary": boundary,
               "width": width, "normal": normal, "origin": base.mean(axis=0),
               "axis": short_axis, "low": low, "high": high}
        component_rows.append(row)
        for face in component: selected[face] = row
    if not selected:
        return refined, {"applied": False, "patches": 0}
    builders = [_Surface(source, target) for source, target in zip(sources, refined)]
    for surface, target in enumerate(refined):
        for i, triangle in enumerate(target["indices"]):
            global_face = topology.face_offsets[surface] + int(target["triangle_origin"][i, 1])
            if global_face not in selected:
                builders[surface].triangle(triangle, target["triangle_origin"][i], bool(target["collision_mask"][i]), int(target["collision_surface_types"][i]))
    def sample(face, bary, side):
        surface, local = int(face_surface[face]), int(face_local[face])
        source, row = sources[surface], selected[face]
        triangle = source["indices"][local]
        native = source["source_ids"][triangle, 0]
        base = contexts[surface]["surface_evaluator"](local, bary)
        reference = np.sum(source["positions"][0, triangle] * bary[:, None], axis=0)
        coordinate = float((reference - row["origin"]) @ row["axis"])
        t = np.clip((coordinate - row["low"]) / max(row["high"] - row["low"], 1e-8), 0., 1.)
        height = row["width"] * (.15 + .85 * np.sin(np.pi*t)) * .5
        # Per-pose span scale follows native deformation, without rebuilding at runtime.
        original_span = np.linalg.norm(points[0, row["vertices"]] - points[0, row["vertices"]].mean(axis=0), axis=-1).max()
        pose_span = np.linalg.norm(points[:, row["vertices"]] - points[:, row["vertices"]].mean(axis=1, keepdims=True), axis=-1).max(axis=1)
        position = base + row["normal"] * (side * height * pose_span / max(original_span, 1e-8))[:, None]
        return builders[surface].vertex(position, row["normal"] * side, native, bary,
                                         bary @ source["uv"][triangle] if source.get("uv") is not None else None,
                                         bary @ source["colors"][triangle], [-1., source.get("part_index", -1)])
    for face in selected:
        surface, local = int(face_surface[face]), int(face_local[face])
        builder, source = builders[surface], sources[surface]
        for side in (-1., 1.):
            lattice = {}
            for i in range(subdivisions + 1):
                for j in range(subdivisions + 1 - i):
                    lattice[i,j] = sample(face, np.array([subdivisions-i-j, i, j]) / subdivisions, side)
            for i in range(subdivisions):
                for j in range(subdivisions-i):
                    triangles = [(lattice[i,j], lattice[i+1,j], lattice[i,j+1])]
                    if i+j < subdivisions-1:
                        triangles.append((lattice[i+1,j], lattice[i+1,j+1], lattice[i,j+1]))
                    for triangle in triangles:
                        builder.triangle(triangle, [surface, local], False, -1, orient=normals[0, face] * side)
    for row in component_rows:
        for edge, (face, local_side), _ in row["boundary"]:
            surface, local = int(face_surface[face]), int(face_local[face])
            builder = builders[surface]
            for step in range(subdivisions):
                vertices = []
                for t, side in ((step/subdivisions, -1.), ((step+1)/subdivisions, -1.),
                                ((step+1)/subdivisions, 1.), (step/subdivisions, 1.)):
                    bary = np.zeros(3); bary[local_side] = 1.-t; bary[(local_side+1)%3] = t
                    vertices.append(sample(face, bary, side))
                along = tris[0,face,(local_side+1)%3] - tris[0,face,local_side]
                outward = _unit(np.cross(along, normals[0, face]))
                for triangle in ((vertices[0],vertices[1],vertices[2]),(vertices[0],vertices[2],vertices[3])):
                    builder.triangle(triangle,[surface,local],False,-1,orient=outward)
    result=[]
    for at, builder in enumerate(builders):
        target = builder.finish(max(row["width"] for row in component_rows))
        if builder.positions:
            if "bevel_geometry" in refined[at]:
                target["bevel_geometry"] = refined[at]["bevel_geometry"]
            else:
                target.pop("bevel_geometry", None)
            target["aircraft_thickness"]={"method":"closed_curved_airfoil_skin_and_rims","added_vertices":len(builder.positions),"skin_triangles":builder.extra_triangles}
        result.append(target)
    return result,{"applied":True,"patches":len(component_rows),"source_faces":len(selected),
                   "maximum_thickness":max(row["width"] for row in component_rows)}
