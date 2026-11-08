"""Native emitter equations and bounded sprite/pool decoding, synthetic only."""
from dataclasses import replace
import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog, Record, Scene
from hugo_assets.effects import export_emitter, parse_emitter, sample_native_spawn
from hugo_assets.mdic import Chunk, Container
from hugo_assets.scene_graph import SourceTransform

PIXELS = bytes((255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 64, 255, 255, 255, 128))


def fixture():
    sprite = (struct.pack("<4I", 0, 0, 2, 16) + struct.pack("<HHII", 1, 1, 24, 28)
              + struct.pack("<I4B", 7, 0, 0, 2, 2))
    pool = bytearray(200)
    struct.pack_into("<2I", pool, 4, (2 << 16) | 40, (2 << 16) | 192)
    struct.pack_into("<2f", pool, 32, 0.5, 10)
    struct.pack_into("<I", pool, 40, 0x80000000)
    struct.pack_into("<I", pool, 116, 0x80000000)
    effect = bytearray(104)
    struct.pack_into("<I", effect, 4, 0x80000000)
    struct.pack_into("<I", effect, 16, 0x80000001)
    effect[24:30] = bytes((128, 64, 32, 0, 1, 2))
    struct.pack_into("<I", effect, 32, 10)
    for offset, value in ((44, 60), (52, 20), (56, 2), (60, 50), (64, 100), (68, 50),
                          (72, 0.06), (76, 100), (84, 100), (92, 100)):
        struct.pack_into("<f", effect, offset, value)
    struct.pack_into("<I", effect, 80, 10)
    struct.pack_into("<I", effect, 88, 20)
    records = (Record(0, 100, 2002, 16, sprite, 0), Record(1, 200, 7000, 40, bytes(pool), 0),
               Record(2, 400, 7500, 104, bytes(effect), 0))
    texture = Chunk(0, 0, 0, 0, len(PIXELS), 2, 7, (2 << 16) | 2, hashlib.sha256(PIXELS).hexdigest())
    catalog = Catalog.__new__(Catalog)
    catalog.scenes = {0: Scene(0, 2, 0, 16, (), records)}
    catalog.scene_chunks = {}
    catalog.textures = {(0, 7): texture}
    catalog.texture_groups = [0]
    catalog.container = Container(PIXELS, [texture], [], {})
    catalog.descriptors = []
    return catalog


class EffectTests(unittest.TestCase):
    def test_native_fields_references_and_sprite_dimensions(self):
        catalog = fixture()
        value = parse_emitter(catalog.record(0, 2), catalog)
        self.assertEqual(value["emission_rate"], 10)
        self.assertEqual(value["sprite"]["blend_mode"], 2)
        self.assertEqual(value["sprite"]["frames"][0]["texture_id"], 7)
        self.assertEqual(value["environment"]["capacity"], 2)
        self.assertEqual(value["environment"]["velocity_multiplier_per_update"], 0.5)
        self.assertEqual(value["environment"]["gravity_z_per_update_source"], 10)
        self.assertEqual(value["start_rgb"], [128, 64, 32])
        self.assertEqual(value["end_rgb"], [0, 1, 2])

    def test_native_spawn_uses_disk_xy_cone_z_and_owner_matrix(self):
        catalog = fixture()
        value = parse_emitter(catalog.record(0, 2), catalog)
        randoms = [0, 0, 0, 0, 0.25, 0, 1, 0, 1, 1]
        world = SourceTransform(np.array([10, 20, 30]), np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]]))
        particle = sample_native_spawn(value, randoms, world)
        np.testing.assert_allclose(particle["source_position"], [10, 40, 30])
        np.testing.assert_allclose(particle["source_velocity"], [0, 0, 100], atol=1e-10)
        self.assertEqual(particle["lifetime"], 1)
        self.assertEqual((particle["start_size"], particle["end_size"]), (20, 10))
        self.assertAlmostEqual(particle["angular_velocity_turns_per_second"], 1, places=6)

    def test_percentage_is_endpoint_to_100_not_symmetric_randomness(self):
        catalog = fixture()
        value = parse_emitter(catalog.record(0, 2), catalog)
        value["end_size"]["percent"] = 200
        a = sample_native_spawn(value, [0] * 10)
        b = sample_native_spawn(value, [1] * 10)
        self.assertEqual((a["end_size"], b["end_size"]), (20, 10))
        self.assertEqual((a["lifetime"], b["lifetime"]), (1, 2))
        self.assertAlmostEqual(a["source_velocity"][2], 25)

    def test_bad_sprite_pool_and_scoped_handle_are_rejected(self):
        for record_index, offset, value in ((0, 24, 0xfffffff0), (1, 4, (65535 << 16) | 40),
                                             (2, 4, 0x80000001), (2, 16, 0x80010000)):
            catalog = fixture()
            records = list(catalog.scenes[0].records)
            data = bytearray(records[record_index].data)
            struct.pack_into("<I", data, offset, value)
            records[record_index] = replace(records[record_index], data=bytes(data))
            catalog.scenes[0] = replace(catalog.scenes[0], records=tuple(records))
            with self.subTest(record=record_index, offset=offset), self.assertRaises(FormatError):
                parse_emitter(catalog.record(0, 2), catalog)

    def test_exported_particle_texture_is_lossless_rgba(self):
        catalog = fixture()
        with tempfile.TemporaryDirectory() as temporary:
            value = export_emitter(catalog.record(0, 2), catalog, Path(temporary))
            image_path = Path(temporary) / value["sprite"]["frames"][0]["texture_path"]
            with Image.open(image_path) as image:
                self.assertEqual(image.mode, "RGBA")
                self.assertEqual(image.tobytes(), PIXELS)
            # A second emitter using the same bitmap verifies and reuses it.
            export_emitter(catalog.record(0, 2), catalog, Path(temporary))
            self.assertEqual(len(list(Path(temporary).rglob("*.png"))), 1)


if __name__ == "__main__":
    unittest.main()
