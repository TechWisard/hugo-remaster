"""Metre-scaled material projection for a verified axis-aligned stone closure."""
from __future__ import annotations

import numpy as np


def map_stone_end_wall(surface: dict, world_matrix, tile_metres: float = 2.4):
    points = np.asarray(surface["positions"])
    if points.shape[0] != 1 or points.shape[1] % 4 or tile_metres <= 0:
        raise ValueError("The confirmed end wall requires static quad faces and a positive material scale")
    matrix = np.asarray(world_matrix, np.float64)
    quads = (points[0] @ matrix[:3, :3].T + matrix[:3, 3]).reshape(-1, 4, 3)
    normals = np.cross(quads[:, 1]-quads[:, 0], quads[:, 2]-quads[:, 0])
    lengths = np.linalg.norm(normals, axis=1)
    if np.any(lengths < 1e-8):
        raise ValueError("Degenerate end-wall face")
    directions = np.abs(normals/lengths[:, None])
    axes = directions.argmax(axis=1)
    if np.any(directions.max(axis=1) < 1.-1e-6):
        raise ValueError("The verified end-wall faces are no longer axis-aligned in the world")
    origin = quads.reshape(-1, 3).min(axis=0)
    uv = np.empty((len(quads), 4, 2), np.float32)
    planes = ((2, 1), (0, 2), (0, 1))  # side=ZY, top=XZ, front=XY
    for index, axis in enumerate(axes):
        plane = list(planes[int(axis)])
        uv[index] = (quads[index][:, plane]-origin[plane])/tile_metres
    result = dict(surface)
    result["uv"] = uv.reshape(-1, 2)
    return result, {"method": "world_metric_per_face_projection", "tile_metres": tile_metres,
                    "quad_plane_counts": {str(axis): int(np.count_nonzero(axes == axis)) for axis in range(3)},
                    "front_plane": "XY", "side_plane": "ZY", "cap_plane": "XZ",
                    "positions_normals_indices_unchanged": True, "collision_unchanged": True,
                    "repeat_sampler_required": True}
