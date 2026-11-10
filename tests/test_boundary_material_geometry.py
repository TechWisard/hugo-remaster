"""A texture-density change must not move the verified gameplay boundary."""
import unittest

import numpy as np

from tools.hugo_assets.boundary_geometry import build_boundary_surface
from tools.hugo_assets.boundary_material_geometry import map_rock_bank


class BoundaryMaterialTests(unittest.TestCase):
    def test_continuous_metric_unwrap_preserves_visible_collision(self):
        source = {"positions": np.array([[[0, 0, 0], [1, 0, 0], [0, 1, 0]]], np.float32),
                  "indices": np.array([[0, 1, 2]]), "source_ids": np.array([[1], [4], [8]]),
                  "colors": np.ones((3, 4), np.float32)}
        closure = {"kind": "beach_west_rock_bank", "surface": 1, "anchor_face": 0,
                   "chain_world": [[94, -28, -40], [94.2, -28.3, -34], [94.5, -28, -28]]}
        matrix = np.array([[0, 0, 2, 10], [0, 2, 0, 3], [-2, 0, 0, -5], [0, 0, 0, 1]], float)
        original = build_boundary_surface(closure, source, matrix)
        rebuilt, report = map_rock_bank(original, matrix, 2.4)
        for key in original:
            if isinstance(original[key], np.ndarray) and key != "uv":
                np.testing.assert_array_equal(rebuilt[key], original[key], err_msg=key)
        uv = rebuilt["uv"].reshape(-1, 4, 2)
        n, m = report["longitudinal_segments"], report["cross_section_segments"]
        strip = uv[:n*m].reshape(n, m, 4, 2)
        np.testing.assert_allclose(strip[:-1, :, 1:3], strip[1:, :, [0, 3]], atol=1e-6)
        np.testing.assert_allclose(strip[:, :-1, [3, 2]], strip[:, 1:, :2], atol=1e-6)
        self.assertAlmostEqual(float(strip[-1, 0, 1, 0])*2.4, report["bank_length_metres"], places=5)
        self.assertGreater(float(rebuilt["uv"].max()), 3.)
        self.assertTrue(report["collision_unchanged"])
        self.assertTrue(report["repeat_sampler_required"])

    def test_rejects_non_matching_strip_instead_of_guessing(self):
        with self.assertRaises(ValueError):
            map_rock_bank({"positions": np.zeros((1, 4, 3), np.float32)}, np.eye(4))


if __name__ == "__main__":
    unittest.main()
