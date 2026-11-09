"""Synthetic source graphs verify separate static shadow export, without game bytes."""
from dataclasses import replace
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from hugo_assets.animation import export_hugo_shadow
from hugo_assets.binary import FormatError
from hugo_assets.gltf import verify_glb
from test_scene_graph import graph_bytes, synthetic_catalog


def shadow_catalog(*, rows=None, transform=0x80000002):
    catalog = synthetic_catalog()
    scene = catalog.scenes[1]
    records = list(scene.records)
    mesh_data = bytearray(records[0].data)
    struct.pack_into("<I", mesh_data, 120, 0x40000000)
    records[0] = replace(records[0], data=bytes(mesh_data))
    owner = records[4]
    offset = struct.unpack_from("<I", owner.data, 12)[0]
    data = owner.data[:offset] + graph_bytes(rows or [[(transform, 0x80000000)]])
    records[4] = replace(owner, data=data)
    catalog.scenes[1] = replace(scene, records=tuple(records))
    return catalog, records[4]


class HugoShadowTests(unittest.TestCase):
    def test_static_export_bakes_only_local_pose_and_preserves_native_blend(self):
        catalog, owner = shadow_catalog()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            profile = export_hugo_shadow(catalog, output, owner)
            raw = (output / profile["path"]).read_bytes()
            report = verify_glb(raw)
            size = struct.unpack_from("<I", raw, 12)[0]
            document = json.loads(raw[20:20 + size])
            self.assertEqual([p.name for p in (output / "animations").iterdir()], ["hugo_shadow.glb"])
        self.assertEqual((report["meshes"], report["triangles"], report["morph_target_accessors"]), (1, 1, 0))
        np.testing.assert_allclose(report["bounds"], [[0, 0.1, -0.1], [0.1, 0.1, 0]])
        render = document["materials"][0]["extras"]["native_render"]
        self.assertEqual(render["blend_selector"], 2)
        self.assertEqual(render["blend_mode"], "multiply_inverse")
        self.assertTrue(document["materials"][0]["extras"]["native_blend_runtime_required"])
        self.assertNotIn("animations", document)
        self.assertEqual(profile["source_pointer_field"], 12)
        self.assertEqual(profile["source_graph_offset"], struct.unpack_from("<I", owner.data, 12)[0])
        self.assertEqual(profile["native_phase"], 0)
        self.assertFalse(profile["authored_duration_used_for_playback"])
        self.assertTrue(profile["local_transform_baked"])
        self.assertEqual(profile["bytes"], len(raw))

    def test_missing_node_transform_uses_identity(self):
        catalog, owner = shadow_catalog(transform=0)
        with tempfile.TemporaryDirectory() as directory:
            profile = export_hugo_shadow(catalog, Path(directory), owner)
        np.testing.assert_allclose(profile["bounds"], [[0, 0, -0.1], [0.1, 0, 0]])
        self.assertIsNone(profile["source_transform"])

    def test_unproven_multiple_states_are_rejected_before_export(self):
        catalog, owner = shadow_catalog(rows=[[(0, 0x80000000)], [(0, 0x80000000)]])
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with self.assertRaisesRegex(FormatError, "expected one state and node"):
                export_hugo_shadow(catalog, output, owner)
            self.assertFalse((output / "animations").exists())

    def test_non_mesh_renderable_is_rejected(self):
        catalog, owner = shadow_catalog(rows=[[(0, 0x80000001)]])
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(FormatError, "unsupported type 3000"):
                export_hugo_shadow(catalog, Path(directory), owner)


if __name__ == "__main__":
    unittest.main()
