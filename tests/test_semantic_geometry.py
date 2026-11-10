"""Объём, morph-привязка и отсутствие искусственного пола у 3D-декора."""
import unittest

import numpy as np

from hugo_assets.geometry_quality import validate_surface
from hugo_assets.semantic_geometry import augment_surface, features_for


def floor_surface(second_island=False):
    positions = np.asarray([[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]], np.float32)
    faces = np.asarray([[0, 2, 1], [0, 3, 2]], np.uint32)
    uv = np.asarray([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    if second_island:
        positions = np.concatenate((positions, positions + [0, 10, 0]))
        faces = np.concatenate((faces, faces + 4))
        uv = np.concatenate((uv, uv))
    count = len(positions)
    poses = np.stack((positions, positions + [0, .3, 0])).astype(np.float32)
    ids = np.repeat(np.arange(count, dtype=np.int32)[:, None], 3, axis=1)
    weights = np.tile([1., 0., 0.], (count, 1)).astype(np.float32)
    return {"positions": poses, "normals": np.tile([0., 1., 0.], (2, count, 1)),
            "uv": uv, "uv2": np.column_stack((np.arange(count), np.full(count, 9))),
            "colors": np.ones((count, 4), np.float32),
            "source_ids": ids, "source_weights": weights, "indices": faces,
            "triangle_origin": np.column_stack((np.zeros(len(faces), np.int32), np.arange(len(faces)))),
            "collision_mask": np.ones(len(faces), bool),
            "collision_surface_types": np.full(len(faces), 4, np.int32),
            "lod_indices": {10.: faces.copy()}, "source_vertex_count": count, "part_index": 9}


class SemanticGeometryTests(unittest.TestCase):
    def rebuild(self, source, group=6, texture=315, **extra):
        calls = []

        def evaluate(triangle, bary):
            self.assertGreaterEqual(float(np.min(bary)), -1e-7)
            calls.append(triangle)
            return np.einsum("i,pic->pc", bary, source["positions"][:, source["indices"][triangle]])

        context = {"original_surface": source,
                   "source_texture_aliases": [{"group": group, "texture_id": texture}],
                   "surface_evaluator": evaluate, **extra}
        result = augment_surface(source, context)
        validate_surface(result, source["positions"].shape[0])
        return result, calls

    def test_stones_have_volume_and_follow_every_morph_pose(self):
        source = floor_surface()
        out, calls = self.rebuild(source)
        count = source["positions"].shape[1]
        self.assertEqual(out["semantic_geometry"]["features"], {"stone": 5})
        self.assertGreater(float(out["positions"][0, count:, 1].max()), .08)
        np.testing.assert_array_equal(out["positions"][:, :count], source["positions"])
        np.testing.assert_allclose(out["positions"][1, count:] - out["positions"][0, count:],
                                   np.tile([0, .3, 0], (out["positions"].shape[1] - count, 1)), atol=1e-6)
        self.assertEqual(set(calls), {0, 1}, "The same stone crosses a source UV diagonal safely")
        self.assertTrue(np.all(out["source_weights"] >= 0))
        self.assertTrue(np.all(out["uv2"][count:] == [-1, 9]))
        self.assertTrue(np.all(out["collision_surface_types"][len(source["indices"]):] == 4))
        self.assertLess(len(out["lod_indices"][10.]), len(out["indices"]))

    def test_six_explicit_pebble_maps_have_bounded_real_volume_and_native_floor_type(self):
        for group,texture in ((6,302),(6,303),(17,280),(17,285),(17,286),(17,287)):
            with self.subTest(group=group,texture=texture):
                source=floor_surface()
                out,_=self.rebuild(source,group,texture)
                count=out["semantic_geometry"]["features"]["pebble"]
                self.assertIn(count,(8,10))
                self.assertGreater(float(out["positions"][0,4:,1].max()),.01)
                self.assertLessEqual(float(out["positions"][0,4:,1].max()),.035001)
                self.assertLessEqual(len(out["indices"])-2,count*30,"Small pebbles need curved shape without a dense interior grid")
                np.testing.assert_array_equal(out["positions"][:,:4],source["positions"])
                np.testing.assert_allclose(out["positions"][1]-out["positions"][0],
                                           np.tile([0,.3,0],(out["positions"].shape[1],1)),atol=1e-6)
                self.assertTrue(np.all(out["collision_surface_types"][2:]==4))
        self.assertEqual(features_for([{"group":6,"texture_id":317}]),(),"Ordinary sand is never displaced by generic brightness")

    def test_identical_uv_on_disconnected_floors_never_links_their_vertices(self):
        source = floor_surface(second_island=True)
        out, _ = self.rebuild(source)
        self.assertEqual(out["semantic_geometry"]["features"]["stone"], 10)
        added_ids = out["source_ids"][8:]
        self.assertTrue(np.all((added_ids.max(axis=1) < 4) | (added_ids.min(axis=1) >= 4)))
        y = out["positions"][0, 8:, 1]
        self.assertFalse(np.any((y > .5) & (y < 9.5)), "No bridges between unrelated UV layers")

    def test_decor_does_not_invent_collision_when_source_has_none(self):
        source = floor_surface()
        source["collision_mask"][:] = False
        source["collision_surface_types"][:] = -1
        out, _ = self.rebuild(source)
        self.assertFalse(out["collision_mask"].any())
        self.assertTrue(np.all(out["collision_surface_types"] == -1))

    def test_partial_uv_chart_cannot_extrude_a_beam_beyond_its_support(self):
        source = floor_surface()
        source["uv"][:, 0] = source["uv"][:, 0] * .6 + .2
        out, _ = self.rebuild(source, group=27, texture=297)
        added = out["positions"][:, 4:]
        ids = out["source_ids"][4:]
        weights = out["source_weights"][4:]
        anchors = np.einsum("ni,pnic->pnc", weights, source["positions"][:, ids])
        distance = np.linalg.norm(added - anchors, axis=-1)
        self.assertLessEqual(float(distance.max()), .40001,
                             "Real thickness is bounded; UV beyond a chart cannot grow a giant plate")
        self.assertGreaterEqual(float(added[:, :, 0].min()), -1e-6)
        self.assertLessEqual(float(added[:, :, 0].max()), 2.00001)

    def test_vertical_exterior_skirt_has_no_horizontal_floor_or_collision(self):
        source = floor_surface()
        source["positions"] = source["positions"][:1]
        source["normals"] = source["normals"][:1]
        out, _ = self.rebuild(source, group=0, texture=0, exterior_edges=[(0, 1)],
                              world_down_local=[0, -1, 0], surface_index=0)
        self.assertEqual(out["semantic_geometry"]["features"], {"exterior_rock_skirt": 1})
        self.assertFalse(out["collision_mask"][2:].any())
        self.assertLess(float(out["positions"][0, 4:, 1].min()), -1.)
        for face in out["indices"][2:]:
            y = out["positions"][0, face, 1]
            self.assertGreater(float(np.ptp(y)), .1, "Every skirt face descends; no pit cap")

    def test_rails_pipes_controls_and_lantern_are_real_meshes(self):
        for group, texture, kind in [(17, 284, "rail"), (46, 282, "pipe"),
                                     (27, 304, "gauge"), (27, 360, "diagonal")]:
            with self.subTest(group=group, texture=texture):
                out, _ = self.rebuild(floor_surface(), group, texture)
                self.assertIn(kind, out["semantic_geometry"]["features"])
                self.assertGreater(float(out["positions"][0, 4:, 1].max()), .015)

    def test_unknown_material_is_not_randomly_decorated(self):
        source = floor_surface()
        out, _ = self.rebuild(source, group=69, texture=999)
        self.assertIs(out, source)
        self.assertFalse(features_for([]))


if __name__ == "__main__":
    unittest.main()
