"""Visible, permanent completions of two confirmed non-gameplay map borders.

These are deliberately separate from optional remaster meshes. The imported
source floor and all authored pits remain intact; both graphics modes attach
the same closed rock geometry and its exact visible triangle collision.
"""
from __future__ import annotations

from collections import defaultdict

import numpy as np


def _aliases(material):
    extra = material.get("extras", {})
    return {(int(row["source_texture_group"]), int(row["source_texture_id"]))
            for row in [extra, *extra.get("source_materials", [])]
            if "source_texture_group" in row and "source_texture_id" in row}


def verified_boundary(level, binding, node, boundaries, glb):
    identity = (str(level.get("id")), binding.get("id"))
    if identity not in {("g027", "g028_o0159_t10400"), ("g006", "g007_o0028_t10400")}:
        return None
    rows = [(surface, edge) for (at, surface), edges in boundaries.items()
            if at == node for edge in edges]
    mesh = glb.doc["meshes"][glb.doc["nodes"][node]["mesh"]]
    if identity[0] == "g027":
        if not rows:
            raise ValueError("Confirmed Mines rear boundary is absent in the imported scene")
        maximum_z = max(float(edge["world"][:, 2].max()) for _, edge in rows)
        back = [(surface, edge) for surface, edge in rows
                if float(edge["world"][:, 2].min()) > maximum_z - .65]
        spawn_y = float(level.get("spawn", [0, -.156, 0])[1])
        floor = [(surface, edge) for surface, edge in back
                 if -.10 < spawn_y - float(edge["world"][:, 1].mean()) < 2.0
                 and float(np.ptp(edge["world"][:, 1])) < .25]
        candidates = [(float(np.ptp(edge["world"][:, 1])), surface, edge["face"])
                      for surface, edge in back
                      if glb.texture(glb.doc["materials"][mesh["primitives"][surface]["material"]])["opaque"]]
        if not floor or not candidates:
            raise ValueError("Mines completion requires the confirmed floor rim and an opaque rock wall")
        _, surface, face = max(candidates)
        points = np.concatenate([edge["world"] for _, edge in back])
        floor_points = np.concatenate([edge["world"] for _, edge in floor])
        return {"kind": "mines_rear_stone_wall", "surface": surface, "anchor_face": face,
                "x_min": float(points[:, 0].min()) - .03, "x_max": float(points[:, 0].max()) + .03,
                "bottom": float(floor_points[:, 1].min()) - .25, "top": float(points[:, 1].max()) + .05,
                "front_z": float(floor_points[:, 2].min()) - .03, "thickness": .55,
                "native_owner": binding["id"], "collision_surface_type": -1,
                "boundary_edges": len(back), "always_present": True,
                "reason": "confirmed rear rim behind Mines spawn, outside the forward negative-Z route"}
    # This precise western chain was verified by rendered pixels and a real
    # backwards walk. The source triangle IDs guard against closing another
    # similarly shaped edge (water, a portal, or an authored gameplay pit).
    confirmed_faces = {10, 11, 17, 18, 20, 70, 77, 78, 110, 118, 120}
    floor_rows = []
    rock_surface = None
    for surface, primitive in enumerate(mesh["primitives"]):
        material = glb.doc["materials"][primitive["material"]]
        aliases = _aliases(material)
        if (6, 285) in aliases and glb.texture(material)["opaque"]:
            rock_surface = surface
        if (6, 317) in aliases:
            floor_rows.extend(edge for at, edge in rows if at == surface and int(edge["face"]) in confirmed_faces
                              and np.all((edge["world"][:, 0] > 92.) & (edge["world"][:, 0] < 102.))
                              and np.all((edge["world"][:, 2] > -63.) & (edge["world"][:, 2] < -9.)))
    if len(floor_rows) != len(confirmed_faces) or rock_surface is None:
        raise ValueError("Beach completion no longer matches the eleven verified source boundary edges")
    adjacency = defaultdict(list)
    values = {}
    for edge in floor_rows:
        pair = [tuple(np.round(point, 4)) for point in edge["world"]]
        for a, b in (pair, pair[::-1]):
            adjacency[a].append(b)
        values.update(zip(pair, edge["world"]))
    ends = [key for key, connected in adjacency.items() if len(connected) == 1]
    if len(ends) != 2 or any(len(v) not in (1, 2) for v in adjacency.values()):
        raise ValueError("Beach confirmed boundary must be one unbranched open chain")
    chain, previous, current = [], None, min(ends, key=lambda point: point[2])
    while current is not None:
        chain.append(values[current].tolist())
        following = [key for key in adjacency[current] if key != previous]
        previous, current = current, following[0] if following else None
        if len(chain) > len(adjacency):
            raise ValueError("Beach boundary loop is not the verified open rear chain")
    return {"kind": "beach_west_rock_bank", "surface": rock_surface, "anchor_face": 0,
            "chain_world": chain, "height": 4.6, "native_owner": binding["id"],
            "collision_surface_type": -1, "boundary_edges": len(floor_rows),
            "source_floor_faces": sorted(confirmed_faces), "always_present": True,
            "reason": "confirmed exposed western bank behind Beach spawn; no water or neighbouring floor exists"}


def _catmull_closed(points, subdivisions=3):
    points = np.asarray(points, np.float64)
    output = []
    for index in range(len(points)):
        a, b, c, d = [points[v % len(points)] for v in (index-1, index, index+1, index+2)]
        for step in range(subdivisions):
            t = step / subdivisions
            output.append(.5 * (2*b + (-a+c)*t + (2*a-5*b+4*c-d)*t*t + (-a+3*b-3*c+d)*t*t*t))
    return np.asarray(output)


def build_boundary_surface(closure, original, world_matrix):
    """Return only the completion's mesh, never a copy of the original floor."""
    if original["positions"].shape[0] != 1:
        raise ValueError("Permanent scene borders may only attach to static source geometry")
    matrix = np.asarray(world_matrix, np.float64)
    inverse = np.linalg.inv(matrix)
    anchor = original["indices"][int(closure["anchor_face"])]
    bary = np.full(3, 1/3, np.float32)
    ids = original["source_ids"][anchor, 0]
    tint = (original["colors"][anchor] * bary[:, None]).sum(axis=0)
    points, normals, uv, faces = [], [], [], []

    def quad(corners, facing=None, corner_normals=None):
        at = len(points)
        corners = np.asarray(corners, np.float64)
        local = (corners - matrix[:3, 3]) @ inverse[:3, :3].T
        natural = np.cross(corners[1]-corners[0], corners[2]-corners[0])
        facing = natural if facing is None else np.asarray(facing)
        if np.linalg.norm(natural) < 1e-10:
            return
        normal = facing @ matrix[:3, :3]
        normal /= max(np.linalg.norm(normal), 1e-12)
        points.extend(local)
        if corner_normals is None:
            normals.extend([normal] * 4)
        else:
            ns = np.asarray(corner_normals) @ matrix[:3, :3]
            ns /= np.maximum(np.linalg.norm(ns, axis=1, keepdims=True), 1e-12)
            normals.extend(ns)
        uv.extend(((0, 0), (1, 0), (1, 1), (0, 1)))
        index = np.array(((0, 1, 2), (0, 2, 3)), np.uint32)
        if np.dot(natural, facing) < 0:
            index = index[:, ::-1]
        faces.extend(index + at)

    if closure["kind"] == "mines_rear_stone_wall":
        width, height = closure["x_max"]-closure["x_min"], closure["top"]-closure["bottom"]
        nx, ny = max(1, int(np.ceil(width/1.8))), max(1, int(np.ceil(height/1.8)))
        front, rear = closure["front_z"], closure["front_z"]+closure["thickness"]
        for ix in range(nx):
            a, b = closure["x_min"]+width*ix/nx, closure["x_min"]+width*(ix+1)/nx
            for iy in range(ny):
                c, d = closure["bottom"]+height*iy/ny, closure["bottom"]+height*(iy+1)/ny
                quad(((a,c,front),(b,c,front),(b,d,front),(a,d,front)), (0,0,-1))
                quad(((a,c,rear),(b,c,rear),(b,d,rear),(a,d,rear)), (0,0,1))
        for x, facing in ((closure["x_min"],(-1,0,0)), (closure["x_max"],(1,0,0))):
            quad(((x,closure["bottom"],front),(x,closure["bottom"],rear),
                  (x,closure["top"],rear),(x,closure["top"],front)),facing)
        for y, facing in ((closure["top"],(0,1,0)),(closure["bottom"],(0,-1,0))):
            quad(((closure["x_min"],y,front),(closure["x_max"],y,front),
                  (closure["x_max"],y,rear),(closure["x_min"],y,rear)),facing)
    elif closure["kind"] == "beach_west_rock_bank":
        chain = np.asarray(closure["chain_world"], np.float64)
        # Keep the steep inner face slightly inside the verified floor rim.
        # A smooth, irregular crown and broad outer foot form visible solid
        # rock. The wall is taller than a normal jump; no invisible floor is
        # added beyond it. The original forward route lies to the east.
        cross_section = _catmull_closed(((.45,-.65),(.45,1.5),(.25,3.1),(-.35,4.1),
                                        (-1.3,4.6),(-2.4,4.1),(-3.2,2.8),(-3.5,.6),(-3.2,-.65)))
        samples, distance = [], [0.]
        for a, b in zip(chain[:-1], chain[1:]):
            length = float(np.linalg.norm(b-a))
            count = max(1, int(np.ceil(length/.85)))
            for step in range(count):
                samples.append(a+(b-a)*step/count)
                if len(samples)>1:
                    distance.append(distance[-1]+float(np.linalg.norm(samples[-1]-samples[-2])))
        samples.append(chain[-1])
        distance.append(distance[-1]+float(np.linalg.norm(samples[-1]-samples[-2])))
        samples = np.asarray(samples)
        ring = np.empty((len(samples),len(cross_section),3))
        for i, (point, at) in enumerate(zip(samples,distance)):
            bulge = .14*np.sin(at*1.13)+.07*np.sin(at*2.37)
            height = 1.+.055*np.sin(at*.73)+.025*np.sin(at*1.91)
            ring[i] = point + np.column_stack((cross_section[:,0]+bulge,
                                               cross_section[:,1]*height,
                                               np.zeros(len(cross_section))))
        along = np.gradient(ring,axis=0)
        around = np.roll(ring,-1,axis=1)-np.roll(ring,1,axis=1)
        ns = np.cross(around,along)
        ns /= np.maximum(np.linalg.norm(ns,axis=2,keepdims=True),1e-12)
        center = ring.mean(axis=1,keepdims=True)
        if float(np.sum(ns*(ring-center)))<0:
            ns *= -1
        for i in range(len(samples)-1):
            for j in range(len(cross_section)):
                k=(j+1)%len(cross_section)
                local_ns=ns[[i,i+1,i+1,i],[j,j,k,k]]
                quad(ring[[i,i+1,i+1,i],[j,j,k,k]],local_ns.mean(axis=0),local_ns)
        # Closed visible caps, not open thin walls. Each fan triangle is
        # represented as a degenerate quad and filtered below.
        for i, sign in ((0,-1),(-1,1)):
            c=ring[i].mean(axis=0)
            facing=(samples[-1]-samples[-2]) if sign==1 else samples[0]-samples[1]
            for j in range(len(cross_section)):
                quad((c,ring[i,j],ring[i,(j+1)%len(cross_section)],c),facing)
    else:
        raise ValueError("Unknown confirmed boundary completion")
    points=np.asarray(points,np.float32)
    faces=np.asarray(faces,np.uint32)
    area=np.linalg.norm(np.cross(points[faces[:,1]]-points[faces[:,0]],points[faces[:,2]]-points[faces[:,0]]),axis=1)
    faces=faces[area>1e-9]
    count=len(points)
    return {"positions":points[None],"normals":np.asarray(normals,np.float32)[None],
            "uv":np.asarray(uv,np.float32),"uv2":None,"colors":np.tile(tint,(count,1)),
            "source_ids":np.tile(ids,(count,1)),"source_weights":np.tile(bary,(count,1)),
            "indices":faces,"triangle_origin":np.tile((closure["surface"],closure["anchor_face"]),(len(faces),1)),
            "collision_mask":np.ones(len(faces),bool),"collision_surface_types":np.full(len(faces),-1,np.int32),
            "lod_indices":{},"source_vertex_count":0,"part_index":-1,"native_material_key":"",
            "verified_scene_closure":{**closure,"vertices":count,"triangles":len(faces)}}
