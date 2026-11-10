"""Solid contact completion preserves actual topology and excludes visual effects."""
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.mesh import Part, TextureRef
from hugo_assets.scene_graph import CollisionTriangle, CollisionMesh
from hugo_assets.terrain_collision import complete_terrain_collision


def part(index, triangles, flags=0x60000000, textures=()):
    vertices = np.array(triangles, dtype=np.float32).reshape(-1, 3)
    return Part(index, 4, flags, vertices[None], np.zeros((1, len(vertices), 2), np.uint8),
                np.arange(len(vertices)).reshape(-1, 3),
                np.full((1, len(vertices), 4), 255, np.uint8), textures)


class TerrainCollisionTests(unittest.TestCase):
    def test_missing_bank_retains_authored_faces_and_known_surface_id(self):
        a = [[0, 0, 0], [100, 0, 0], [0, 100, 20]]
        b = [[100, 0, 0], [100, 100, 20], [0, 100, 20]]
        far = [[400, 0, 0], [500, 0, 0], [400, 100, 0]]
        mesh = SimpleNamespace(group=6, sample_count=1,
                               parts=(part(0, [a, b]), part(1, [far]), part(2, [a])))
        native = CollisionMesh(6, 0, 100, (), (CollisionTriangle(0, 0, 0, 7, np.array(a)),), 1, 1)
        result = complete_terrain_collision(mesh, native, lambda group, texture: True)
        self.assertEqual(result["source_triangles"], [[0, 1], [1, 0]])
        self.assertEqual(result["surface_types"], [7, -1])
        self.assertEqual(result["excluded"], {"duplicate_geometry": 1})
        self.assertFalse(result["native_quadtree_modified"])
        self.assertEqual(result["invented_triangles"], 0)
        faces = np.array(result["faces"]).reshape(-1, 3, 3)
        self.assertTrue(np.all(faces[0, :, 0] <= 1.0))
        self.assertTrue(np.all(faces[1, :, 0] >= 4.0))
        self.assertEqual(len(native.triangles), 1)  # No floor bridges the 3m gap.

    def test_blended_cutout_animated_and_skipped_geometry_cannot_become_solid(self):
        triangle = [[[0, 0, 0], [100, 0, 0], [0, 100, 0]]]
        texture = TextureRef(5, 4, 4, (0, 0))
        mesh = SimpleNamespace(group=27, sample_count=1, parts=(
            part(0, triangle, flags=0x20000000),
            part(1, triangle, textures=(texture,)),
            part(2, triangle, textures=(texture, texture)),
            part(3, triangle, flags=0xE0000000)))
        native = CollisionMesh(27, 0, 100, (), (), 0, 0)
        result = complete_terrain_collision(mesh, native, lambda group, texture: False)
        self.assertEqual(result["triangle_count"], 0)
        self.assertEqual(result["faces"], [])
        self.assertEqual(result["excluded"], {"blended": 1, "cutout_or_translucent_texture": 1,
                                               "animated_texture": 1, "not_rendered": 1})

    def test_animated_belt_requires_native_nonhazard_sequence_and_all_opaque_frames(self):
        a = [[0, 0, 0], [100, 0, 0], [0, 100, 0]]
        b = [[200, 0, 0], [300, 0, 0], [200, 100, 0]]
        c = [[400, 0, 0], [500, 0, 0], [400, 100, 0]]
        frames = tuple(TextureRef(i, 4, 4, (0, 0)) for i in (5, 6))
        other_frames = tuple(TextureRef(i, 4, 4, (0, 0)) for i in (7, 8))
        mesh = SimpleNamespace(group=55, sample_count=1, parts=(
            part(0, [a], textures=frames), part(1, [b], textures=frames),
            part(2, [c], textures=other_frames)))
        native = CollisionMesh(55, 0, 100, (), (CollisionTriangle(0, 0, 0, 15, np.array(a)),), 1, 1)
        result = complete_terrain_collision(mesh, native, lambda g, t: True, {15: 0.0})
        self.assertEqual(result["source_triangles"], [[1, 0]])
        self.assertEqual(result["surface_types"], [-1])  # No guessed belt direction ID.
        self.assertEqual(result["accepted_animated_parts"], [1])
        self.assertEqual(result["animated_solid_evidence"][0]["native_source_parts"], [0])
        self.assertEqual(result["excluded"], {"animated_texture": 1})
        for damage in ({}, {15: 25.0}):
            blocked = complete_terrain_collision(mesh, native, lambda g, t: True, damage)
            self.assertEqual(blocked["triangle_count"], 0)
        transparent_frame = complete_terrain_collision(mesh, native, lambda g, t: t != 6, {15: 0.0})
        self.assertEqual(transparent_frame["triangle_count"], 0)
        self.assertEqual(transparent_frame["excluded"]["cutout_or_translucent_texture"], 1)


if __name__ == "__main__":
    unittest.main()
