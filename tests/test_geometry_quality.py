"""Shape, seam, morph and collision guarantees of the offline mesh rebuild."""
import unittest
from collections import Counter

import numpy as np

from hugo_assets.geometry_quality import mesh_topology, refine_mesh, validate_surface


def surface(points, triangles, ids=None, translations=((0., 0., 0.), (.1, .4, -.2))):
    points = np.asarray(points, np.float32)
    triangles = np.asarray(triangles, np.uint32)
    count = len(points)
    source_ids = np.arange(count, dtype=np.int32) if ids is None else np.asarray(ids, np.int32)
    poses = np.stack([points + np.asarray(delta) for delta in translations]).astype(np.float32)
    return {"positions": poses, "normals": np.zeros_like(poses),
            "uv": points[:, :2].copy(), "uv2": np.column_stack((source_ids, np.full(count, 7))).astype(np.float32),
            "colors": np.ones((count, 4), np.float32),
            "source_ids": np.repeat(source_ids[:, None], 3, axis=1),
            "source_weights": np.tile([1., 0., 0.], (count, 1)).astype(np.float32),
            "indices": triangles,
            "triangle_origin": np.column_stack((np.zeros(len(triangles)), np.arange(len(triangles)))).astype(np.int32),
            "collision_mask": np.zeros(len(triangles), bool),
            "collision_surface_types": np.full(len(triangles), -1, np.int32),
            "lod_indices": {}, "part_index": 7, "native_material_key": "fixture"}


def octahedron(split=False):
    points = np.asarray([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], np.float32)
    triangles = np.asarray([[0, 2, 4], [4, 2, 1], [1, 2, 5], [5, 2, 0],
                            [4, 3, 0], [1, 3, 4], [5, 3, 1], [0, 3, 5]], np.uint32)
    if split:
        return [surface(points[face], [[0, 1, 2]], face) for face in triangles]
    return [surface(points, triangles)]


class GeometryQualityTests(unittest.TestCase):
    def test_mechanical_cube_has_real_closed_rounded_bevels_in_every_pose(self):
        points = [[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],
                  [-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]]
        triangles = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,4,7],[0,7,3],
                     [1,2,6],[1,6,5],[0,1,5],[0,5,4],[3,7,6],[3,6,2]]
        source = surface(points, triangles)
        rebuilt, report = refine_mesh([source], [{"owner_classes": ["COrnemental"]}])
        out = rebuilt[0]
        self.assertEqual(report["bevel_geometry"]["eligible_edges"], 12)
        self.assertEqual(report["bevel_geometry"]["rounded_vertices"], 8)
        self.assertGreater(report["bevel_geometry"]["fillet_triangles"], 100)
        used = np.unique(out["indices"])
        shape = out["positions"][0, used]
        self.assertLess(float(np.abs(shape).sum(axis=1).max()), 2.99,
                        "The actual sharp cube tips must disappear from the high LOD silhouette")
        self.assertLessEqual(float(np.abs(shape).max()), 1.000001)
        np.testing.assert_allclose(out["positions"][1] - out["positions"][0],
                                   np.tile([.1, .4, -.2], (out["positions"].shape[1], 1)), atol=3e-7)
        welded = [tuple(row) for row in np.round(out["positions"][0], 5)]
        edges = Counter()
        for face in out["indices"]:
            for a, b in zip(face, np.roll(face, -1)):
                edges[tuple(sorted((welded[a], welded[b])))] += 1
        self.assertEqual(set(edges.values()), {2}, "Curved strips and corner patches close without cracks")
        self.assertFalse(out["collision_mask"].any(), "A decorative body does not acquire gameplay collision")
        np.testing.assert_array_equal(out["positions"][:, :8], source["positions"])
        validate_surface(out, 2)

    def test_organic_reconstruction_changes_shape_in_every_native_pose(self):
        source = octahedron()[0]
        rebuilt, report = refine_mesh([source], [{"owner_classes": ["Hugo"]}])
        out = rebuilt[0]
        validate_surface(out, 2)
        self.assertGreater(report["max_curvature_displacement"], .025)
        used = np.unique(out["indices"])
        # The source's six sharp cage tips are rounded inward, and PN samples
        # leave their original planar facets. More indices alone cannot pass.
        self.assertLess(float(out["positions"][0, used, 0].max()), .99)
        ids, weights = out["source_ids"], out["source_weights"]
        linear = (source["positions"][0, ids] * weights[:, :, None]).sum(axis=1)
        self.assertGreater(float(np.linalg.norm(out["positions"][0] - linear, axis=-1).max()), .025)
        expected = np.tile([.1, .4, -.2], (out["positions"].shape[1], 1))
        np.testing.assert_allclose(out["positions"][1] - out["positions"][0], expected, atol=2e-7)
        np.testing.assert_array_equal(out["positions"][:, :6], source["positions"])
        self.assertTrue(np.all(out["uv2"][6:] == [-1, 7]))
        self.assertGreater(len(out["indices"]), len(source["indices"]))

        levels=sorted(out["lod_indices"].items())
        self.assertEqual(len(levels),2,"Curved intermediate LOD precedes the distant native cage")
        self.assertGreater(len(levels[0][1]),len(source["indices"]))
        self.assertLess(len(levels[0][1]),len(out["indices"]))
        mid_vertices=np.unique(levels[0][1])
        self.assertTrue(np.all(mid_vertices>=len(source["positions"][0])),"Middle LOD uses the actual rounded surface, not source vertices")
        self.assertLess(float(out["positions"][0,mid_vertices,0].max()),.99)

    def test_separate_uv_material_surfaces_share_the_same_curved_edge(self):
        sources = octahedron(split=True)
        rebuilt, _ = refine_mesh(sources, [{"owner_classes": ["CSimpleStateActor"]}] * len(sources))
        edge_samples = {}
        shared = 0
        for out in rebuilt:
            for vertex in np.unique(out["indices"]):
                weights = out["source_weights"][vertex]
                active = weights > 1e-7
                if np.count_nonzero(active) != 2:
                    continue
                key = tuple(sorted(zip(out["source_ids"][vertex][active].tolist(), weights[active].tolist())))
                point = out["positions"][:, vertex]
                if key in edge_samples:
                    np.testing.assert_allclose(point, edge_samples[key], atol=1e-6,
                                               err_msg="A material seam must not open during any morph pose")
                    shared += 1
                else:
                    edge_samples[key] = point
        self.assertGreater(shared, 20)

    def test_matching_bind_pose_does_not_weld_parts_that_move_apart(self):
        first = surface([[0, 0, 0], [1, 0, 0], [0, 1, 0]], [[0, 1, 2]])
        second = surface([[0, 0, 0], [1, 0, 0], [0, -1, 0]], [[0, 2, 1]])
        second["positions"][1] += [0, 0, .3]
        topology = mesh_topology([first, second], 145.)
        self.assertNotEqual(topology.weld_ids[0], topology.weld_ids[3])
        self.assertNotEqual(topology.weld_ids[1], topology.weld_ids[4])

    def test_an_exact_plane_is_retained_without_fake_subdivision_or_support(self):
        source = surface([[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]], [[0, 2, 1], [0, 3, 2]])
        source["collision_mask"][0] = True
        source["collision_surface_types"][0] = 4
        rebuilt, report = refine_mesh([source], [{"owner_classes": ["CDefaultSegment"]}])
        out = rebuilt[0]
        self.assertLess(report["max_curvature_displacement"], 1e-7)
        np.testing.assert_array_equal(out["positions"], source["positions"])
        np.testing.assert_array_equal(out["indices"], source["indices"])
        np.testing.assert_array_equal(out["collision_mask"], [True, False])
        self.assertFalse(out["lod_indices"])

    def test_curved_support_inherits_each_original_triangle_type(self):
        source = octahedron()[0]
        source["collision_mask"][:4] = True
        source["collision_surface_types"][:4] = [2, 4, 17, 0]
        rebuilt, _ = refine_mesh([source], [{"owner_classes": ["CDefaultSegment"]}])
        out = rebuilt[0]
        parents = out["triangle_origin"][:, 1]
        np.testing.assert_array_equal(out["collision_mask"], source["collision_mask"][parents])
        np.testing.assert_array_equal(out["collision_surface_types"], source["collision_surface_types"][parents])
        for lod in out["lod_indices"].values():
            self.assertGreaterEqual(int(lod.min()), 0)
            self.assertLess(int(lod.max()), out["positions"].shape[1])
        self.assertLess(len(next(iter(out["lod_indices"].values()))), len(out["indices"]))

    def test_invalid_attachment_provenance_fails_before_a_resource_is_written(self):
        source = octahedron()[0]
        invalid = dict(source)
        invalid["source_weights"] = source["source_weights"].copy()
        invalid["source_weights"][0] = [-.1, .5, .6]
        with self.assertRaisesRegex(ValueError, "provenance"):
            validate_surface(invalid, 2)


if __name__ == "__main__":
    unittest.main()
