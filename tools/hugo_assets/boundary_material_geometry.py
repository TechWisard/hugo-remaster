"""Continuous, metre-scaled UVs for the verified Beach repair only.

The frozen repair's positions, normal field, indices and collision stay exact.
Its narrow tessellation bands are not texture tiles: the rock material follows
the entire bank with a separate repeat sampler, including the curved crown.
"""
from __future__ import annotations

import numpy as np


def map_rock_bank(surface: dict, world_matrix, tile_metres: float = 2.4):
    if tile_metres <= 0 or np.asarray(surface["positions"]).shape[0] != 1:
        raise ValueError("A permanent rock bank requires one pose and a positive texture scale")
    points = np.asarray(surface["positions"])[0]
    if len(points) % 4:
        raise ValueError("The verified bank no longer contains its original quad strips")
    matrix = np.asarray(world_matrix, np.float64)
    world = points @ matrix[:3, :3].T + matrix[:3, 3]
    quads = world.reshape(-1, 4, 3)
    starts = np.flatnonzero(np.linalg.norm(quads[:, 0] - quads[0, 1], axis=1) < 2e-5)
    if not len(starts) or int(starts[0]) < 3:
        raise ValueError("Cannot identify the verified bank's closed cross-section")
    around = int(starts[0])
    if len(quads) % around or len(quads) // around < 4:
        raise ValueError("The bank no longer has two unchanged closed end caps")
    segments = len(quads) // around - 2
    strip = quads[:segments*around].reshape(segments, around, 4, 3)
    rings = np.concatenate((strip[:, :, 0], strip[-1:, :, 1]), axis=0)
    if not (np.allclose(strip[:, :, 1], rings[1:], atol=2e-5, rtol=0) and
            np.allclose(strip[:, :, 3], np.roll(rings[:-1], -1, axis=1), atol=2e-5, rtol=0) and
            np.allclose(strip[:, :, 2], np.roll(rings[1:], -1, axis=1), atol=2e-5, rtol=0)):
        raise ValueError("The bank strips no longer meet at the same physical edges")
    centers = rings.mean(axis=1)
    along = np.r_[0., np.cumsum(np.linalg.norm(np.diff(centers, axis=0), axis=1))]
    arc = np.linalg.norm(np.roll(rings, -1, axis=1)-rings, axis=2).mean(axis=0)
    around_distance = np.r_[0., np.cumsum(arc)]
    uv = np.empty((len(quads), 4, 2), np.float32)
    for i in range(segments):
        for j in range(around):
            uv[i*around+j] = np.array(((along[i], around_distance[j]),
                                      (along[i+1], around_distance[j]),
                                      (along[i+1], around_distance[j+1]),
                                      (along[i], around_distance[j+1]))) / tile_metres
    # End caps are already closed fans in the world XY plane. Map their actual
    # dimensions rather than repeating a complete texture on every triangle.
    uv[segments*around:] = (quads[segments*around:, :, :2]-centers[0, :2])/tile_metres
    result = dict(surface)
    result["uv"] = uv.reshape(-1, 2)
    evidence = {"method": "continuous_physical_bank_unwrap", "tile_metres": tile_metres,
                "longitudinal_segments": segments, "cross_section_segments": around,
                "bank_length_metres": float(along[-1]),
                "cross_section_length_metres": float(around_distance[-1]),
                "positions_normals_indices_unchanged": True, "collision_unchanged": True,
                "repeat_sampler_required": True, "source_material_alias": [6, 286]}
    return result, evidence
