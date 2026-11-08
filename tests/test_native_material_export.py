"""Synthetic render-state regressions; no original textures or meshes."""
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import struct
import sys
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog
from hugo_assets.gltf import export_glb, verify_glb
from hugo_assets.levels import _batch_geometry
from hugo_assets.mdic import parse_mdic
from hugo_assets.mesh import Selection, parse_mesh
from test_import_original import synthetic_container


def document(raw):
    length = struct.unpack_from("<I", raw, 12)[0]
    return json.loads(raw[20:20 + length]), raw[28 + length:]


def replace_document(raw, doc):
    _, binary = document(raw)
    encoded = json.dumps(doc, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    return (struct.pack("<4sII", b"glTF", 2, 28 + len(encoded) + len(binary))
            + struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


class NativeMaterialExportTests(unittest.TestCase):
    def setUp(self):
        self.catalog = Catalog(parse_mdic(synthetic_container()))
        self.mesh = parse_mesh(self.catalog.record(0, 0, 2001))

    def export(self, parts):
        mesh = replace(self.mesh, parts=tuple(parts))
        return export_glb(self.catalog, [Selection(mesh, "synthetic_materials", np.zeros(3), np.eye(3))],
                          include_samples=True)

    def test_all_native_modes_are_explicit_and_opaque_cutout_uses_source_threshold(self):
        part = self.mesh.parts[0]
        raw = self.export(replace(part, index=i, flags=i << 29) for i in range(4))
        doc, _ = document(raw)
        self.assertEqual(verify_glb(raw)["triangles"], 4)
        self.assertEqual([m["extras"]["native_render"]["blend_mode"] for m in doc["materials"]],
                         ["alpha", "add", "multiply_inverse", "opaque"])
        self.assertEqual([m["alphaMode"] for m in doc["materials"]], ["BLEND", "BLEND", "BLEND", "MASK"])
        self.assertAlmostEqual(doc["materials"][3]["alphaCutoff"], 8 / 255)
        for selector, material in enumerate(doc["materials"]):
            self.assertTrue(material["name"].endswith(f"__hugo_blend_{selector}"))
            self.assertEqual(material["extras"]["native_render"]["source_flags"], selector << 29)
            self.assertEqual(material["extras"]["native_blend_runtime_required"], selector in (1, 2))
            self.assertTrue(material["doubleSided"])
        # Byte-exact PNG reuse is covered by the ordinary extraction tests;
        # this fix must not synthesize texture alpha from black RGB values.
        self.assertEqual(len(doc["images"]), 1)

    def test_plain_surface_alpha_is_128_and_stored_fourth_color_byte_is_ignored(self):
        part = self.mesh.parts[0]
        colors = part.colors.copy()
        colors[:, :, 3] = [0, 17, 255]
        raw = self.export([replace(part, kind=1, flags=0, materials=(), colors=colors)])
        doc, binary = document(raw)
        primitive = doc["meshes"][0]["primitives"][0]
        accessor = doc["accessors"][primitive["attributes"]["COLOR_0"]]
        view = doc["bufferViews"][accessor["bufferView"]]
        actual = np.frombuffer(binary, dtype="<f4", count=accessor["count"] * 4,
                               offset=view.get("byteOffset", 0)).reshape(-1, 4)
        np.testing.assert_allclose(actual[:, 3], 128 / 255, rtol=0, atol=1e-7)
        self.assertEqual(doc["materials"][0]["alphaMode"], "BLEND")
        self.assertEqual(doc["materials"][0]["extras"]["native_render"]["alpha_source"],
                         "fixed_vertex_128_of_255")

    def test_batching_separates_native_modes_and_other_preserved_flags(self):
        part = self.mesh.parts[0]
        # Alpha/add/multiply share identical core glTF fallback settings.
        # A repeat of additive may batch; an additional undecoded flag may not.
        flags = [0, 0x20000000, 0x40000000, 0x60000000, 0x62000000, 0x20000000]
        raw = self.export(replace(part, index=i, flags=f) for i, f in enumerate(flags))
        doc, _, _, report = _batch_geometry(raw)
        self.assertEqual((report["source_surfaces"], report["exported_surfaces"]), (6, 5))
        self.assertEqual((report["source_triangles"], report["exported_triangles"]), (6, 6))
        self.assertEqual(report["native_material_modes"], {"alpha": 1, "add": 1, "multiply_inverse": 1, "opaque": 2})
        self.assertTrue(report["checked_native_render_identity"])
        self.assertTrue(report["checked_every_morph_triangle_attribute"])
        for material in doc["materials"]:
            extras = material["extras"]
            self.assertEqual({m["source_flags"] for m in extras["source_materials"]}, {extras["source_flags"]})
            self.assertEqual(extras["native_render"]["blend_selector"], (extras["source_flags"] >> 29) & 3)
            self.assertTrue(material["name"].endswith(f"__hugo_blend_{extras['native_render']['blend_selector']}"))
        parts = [p for m in doc["meshes"] for p in m["primitives"]]
        self.assertIn([1, 5], [p["extras"]["source_submesh_indices"] for p in parts])

    def test_mismatching_native_render_metadata_is_rejected_before_batching(self):
        raw = self.export(self.mesh.parts)
        doc, _ = document(raw)
        doc["materials"][0]["extras"]["native_render"]["blend_selector"] = 1
        with self.assertRaisesRegex(FormatError, "metadata disagrees"):
            _batch_geometry(replace_document(raw, doc))


if __name__ == "__main__":
    unittest.main()
