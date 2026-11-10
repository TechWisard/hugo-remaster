import unittest

import numpy as np

from tools.hugo_assets.boundary_geometry import build_boundary_surface
from tools.hugo_assets.boundary_projection import map_stone_end_wall


class EndWallUVTests(unittest.TestCase):
    def test_every_face_uses_real_metres_including_thirteen_metre_side_caps(self):
        source = {"positions": np.zeros((1, 3, 3)), "indices": np.array([[0, 1, 2]]),
                  "source_ids": np.array([[1], [4], [8]]), "colors": np.ones((3, 4))}
        closure = {"kind": "mines_rear_stone_wall", "surface": 3, "anchor_face": 0,
                   "x_min": -28, "x_max": -8, "bottom": -.4, "top": 12.8,
                   "front_z": 6.2, "thickness": .55}
        matrix = np.array([[0, 0, .1, 2], [0, .1, 0, 4], [-.1, 0, 0, 3], [0, 0, 0, 1]])
        before = build_boundary_surface(closure, source, matrix)
        after, report = map_stone_end_wall(before, matrix, 2.4)
        world = (after["positions"][0]@matrix[:3, :3].T+matrix[:3, 3]).reshape(-1, 4, 3)
        uv = after["uv"].reshape(-1, 4, 2)
        for a, b in ((0, 1), (1, 2), (2, 3), (3, 0)):
            np.testing.assert_allclose(np.linalg.norm(uv[:, b]-uv[:, a], axis=1)*2.4,
                                       np.linalg.norm(world[:, b]-world[:, a], axis=1), rtol=1e-5, atol=1e-5)
        for key in before:
            if isinstance(before[key], np.ndarray) and key != "uv":
                np.testing.assert_array_equal(after[key], before[key], err_msg=key)
        self.assertEqual(report["front_plane"], "XY")
        self.assertGreater(float(uv.max()), 5.)


if __name__ == "__main__":
    unittest.main()
