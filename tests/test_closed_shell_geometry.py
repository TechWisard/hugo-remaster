import unittest

import numpy as np

from hugo_assets.closed_shell_geometry import close_formed_canopy


def canopy():
    base = np.array([[-1, 0, -1], [1, 0, -1], [1, 0, 1], [-1, 0, 1],
                     [-.3, .6, -.3], [.3, .6, -.3], [.3, .6, .3], [-.3, .6, .3],
                     [0, .8, 0], [4, 0, 0], [5, 0, 0], [4, 0, 1]], dtype=np.float32)
    faces = []
    for i in range(4):
        j = (i+1) % 4
        faces.extend(((i, i+4, j+4), (i, j+4, j), (i+4, 8, j+4)))
    faces.append((9, 11, 10))  # An unrelated part must remain exactly intact.
    faces = np.asarray(faces, np.int32)
    angle = .73
    rotation = np.array([[np.cos(angle), -np.sin(angle), 0],
                         [np.sin(angle), np.cos(angle), 0], [0, 0, 1]])
    moved = base @ rotation.T * 1.7 + np.array([2.1, -3.2, 4.3])
    count = len(base)
    normals = np.zeros((2, count, 3), np.float32)
    normals[0, :, 1] = 1
    normals[1] = normals[0] @ rotation.T
    return {"positions": np.stack((base, moved)), "normals": normals,
            "indices": faces, "lod_indices": {.01: faces.copy(), .02: faces.copy()},
            "colors": np.column_stack((np.linspace(.1, .9, count), np.ones((count, 3)))),
            "uv": base[:, [0, 2]], "uv2": np.column_stack((np.arange(count), np.zeros(count))),
            "source_ids": np.tile(np.arange(count)[:, None], (1, 3)).astype(np.int32),
            "source_weights": np.tile([1., 0., 0.], (count, 1)),
            "collision_mask": np.zeros(len(faces), bool),
            "collision_surface_types": np.full(len(faces), -1, np.int32)}, rotation


class ClosedCanopyTests(unittest.TestCase):
    def test_every_lod_is_closed_thick_and_keeps_native_attributes(self):
        source, rotation = canopy()
        roof = set(range(9))
        result, info = close_formed_canopy(source, roof)
        old_count = source["positions"].shape[1]
        self.assertEqual(info["morph_poses"], 2)
        self.assertTrue(info["source_front_skin_unchanged"])
        np.testing.assert_array_equal(result["positions"][:, :old_count], source["positions"].astype(np.float32))
        np.testing.assert_array_equal(result["indices"][:len(source["indices"])], source["indices"])
        self.assertFalse(result["collision_mask"].any())
        self.assertTrue(np.all(result["collision_surface_types"] == -1))
        np.testing.assert_allclose(result["source_weights"].sum(axis=1), 1)
        self.assertTrue(np.all(result["source_weights"] >= 0))
        for i in range(old_count, result["positions"].shape[1]):
            anchor = int(result["source_ids"][i, 0])
            self.assertIn(anchor, roof)
            np.testing.assert_array_equal(result["colors"][i], source["colors"][anchor])
            np.testing.assert_array_equal(result["uv"][i], source["uv"][anchor])
        np.testing.assert_allclose(result["positions"][1],
                                   result["positions"][0] @ rotation.T * 1.7 + [2.1, -3.2, 4.3], atol=1e-6)
        self.assertLess(float(result["positions"][0, old_count:, 1].min()), -.01)
        from collections import Counter
        for indices in [result["indices"], *result["lod_indices"].values()]:
            faces = [face for face in indices if all(int(result["source_ids"][i, 0]) in roof for i in face)]
            edges = Counter()
            for face in faces:
                points = result["positions"][0, face]
                self.assertGreater(float(np.linalg.norm(np.cross(points[1]-points[0], points[2]-points[0]))), 1e-8)
                keys = [tuple(np.round(point, 5)) for point in points]
                for i in range(3):
                    edges[tuple(sorted((keys[i], keys[(i+1) % 3])))] += 1
            self.assertEqual(set(edges.values()), {2}, "every edge of every rendered canopy LOD must have two incident faces")
        thresholds = list(result["lod_indices"])
        self.assertGreaterEqual(thresholds[0], .06)
        self.assertGreater(thresholds[1], thresholds[0])

    def test_unknown_or_invalid_shell_is_rejected(self):
        source, _ = canopy()
        with self.assertRaises(ValueError):
            close_formed_canopy(source, {999})
        bad = dict(source)
        bad["indices"] = np.concatenate((source["indices"], source["indices"][:1]))
        with self.assertRaises(ValueError):
            close_formed_canopy(bad, set(range(9)))


if __name__ == "__main__":
    unittest.main()
