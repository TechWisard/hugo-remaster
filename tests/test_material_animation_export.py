"""Resource-animation export fixtures are generated, never copied from a game."""
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog
from hugo_assets.gltf import export_glb, verify_glb
from hugo_assets.levels import _batch_geometry
from hugo_assets.material_animation import export_material_animations
from hugo_assets.mdic import parse_mdic
from hugo_assets.mesh import Selection, parse_mesh, sample_material_animation
from test_import_original import PIXELS, chunk, synthetic_scene


def animated_catalog(texture_ids=(7, 7, 7)):
    """Two vertex/RGB/UV samples and intentionally repeated texture slots."""
    raw = bytearray(156)
    for offset, value in ((0, 2001), (4, 0x01010101), (32, 0x02020202),
                          (40, 104), (44, 112), (112, 116)):
        struct.pack_into("<I", raw, offset, value)
    struct.pack_into("<H", raw, 38, 1)
    struct.pack_into("<HH", raw, 104, 2, 2)
    struct.pack_into("<6f", raw, 72, 0, 0, 0, 10, 10, 1)
    vertices = b"".join(struct.pack("<hhhBB", x, y, sample, u + sample * 10, v)
                         for sample in range(2)
                         for x, y, u, v in ((0, 0, 0, 0), (10, 0, 245, 0), (0, 10, 0, 255)))
    face = len(raw) + len(vertices)
    colors = face + 4
    material = colors + 24
    table = material + 8
    refs = table + len(texture_ids) * 4
    timeline = refs + len(texture_ids) * 8
    struct.pack_into("<I", raw, 48, timeline)
    struct.pack_into("<IIHHII", raw, 116, 0x10003, 0x64000000, 3, 1, face, 156)
    struct.pack_into("<II", raw, 148, colors, material)
    raw += vertices + struct.pack("<I", (1 << 10) | (2 << 20))
    raw += bytes((128, 128, 128, 0)) * 3 + bytes((255, 17, 61, 99)) * 3
    raw += struct.pack("<HHI", 0, len(texture_ids), table)
    raw += b"".join(struct.pack("<I", refs + i * 8) for i in range(len(texture_ids)))
    raw += b"".join(struct.pack("<I4B", texture_id, 0, 0, 2, 2) for texture_id in texture_ids)
    raw += struct.pack("<II", 0, 1 << 16)
    assets = [chunk(2, PIXELS, (7, (2 << 16) | 2)), chunk(4, synthetic_scene(bytes(raw)))]
    container = chunk(1, aux=(2048 + sum(map(len, assets)), len(assets))) + b"".join(assets)
    return Catalog(parse_mdic(container))


def document(raw):
    size = struct.unpack_from("<I", raw, 12)[0]
    return json.loads(raw[20:20 + size]), raw[28 + size:]


def accessor_array(doc, binary, index):
    item = doc["accessors"][index]
    view = doc["bufferViews"][item["bufferView"]]
    dimensions = {"VEC2": 2, "VEC3": 3, "VEC4": 4, "SCALAR": 1}[item["type"]]
    dtype = "<f4" if item["componentType"] == 5126 else "<u2"
    return np.frombuffer(binary, dtype=dtype, count=item["count"] * dimensions,
                         offset=view.get("byteOffset", 0)).reshape(-1, dimensions)


class MaterialAnimationExportTests(unittest.TestCase):
    def test_lossless_frames_repeated_slots_and_reference_sample(self):
        catalog = animated_catalog()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            report = export_material_animations(catalog, output)
            manifest = json.loads((output / report["manifest_path"]).read_text())
            self.assertEqual(set(manifest["materials"]), {"g000_r0000_p000"})
            row = manifest["materials"]["g000_r0000_p000"]
            validation = report["validation"]
            self.assertEqual((validation["animated_materials"], validation["texture_sequences"],
                              validation["color_animated_parts"], validation["uv_animated_parts"]), (1, 1, 1, 1))
            self.assertEqual((validation["texture_frame_slots"], validation["unique_texture_frames"]), (3, 1))
            self.assertEqual([x["texture_id"] for x in row["texture_sequence"]], [7, 7, 7])
            self.assertEqual(len({x["path"] for x in row["texture_sequence"]}), 1)
            with Image.open(output / row["texture_sequence"][0]["path"]) as image:
                self.assertEqual(image.tobytes(), PIXELS)
            sample = sample_material_animation(row, 0.5)
            self.assertEqual(sample["texture_frame_index"], 1)
            self.assertEqual(sample["rgb_bytes"][0], [191, 72, 94])
            self.assertAlmostEqual(sample["uv"][0][0], 5 / 255, places=7)
            self.assertEqual(row["source_vertex_mapping"]["attribute"], "TEXCOORD_1")

    def test_source_indices_survive_batching_in_uv2_and_parts_stay_separate(self):
        catalog = animated_catalog()
        mesh = parse_mesh(catalog.record(0, 0, 2001))
        model = replace(mesh, parts=(mesh.parts[0], replace(mesh.parts[0], index=1)))
        raw = export_glb(catalog, [Selection(model, "generated", np.zeros(3), np.eye(3))], include_samples=True)
        self.assertEqual(verify_glb(raw)["triangles"], 2)
        initial, initial_binary = document(raw)
        primitive = initial["meshes"][0]["primitives"][0]
        uv = accessor_array(initial, initial_binary, primitive["attributes"]["TEXCOORD_0"])
        self.assertAlmostEqual(float(uv[2, 1]), 1.0)
        doc, binary, _, report = _batch_geometry(raw)
        self.assertEqual((report["source_surfaces"], report["exported_surfaces"]), (2, 2))
        self.assertTrue(report["checked_animated_surface_isolation"])
        self.assertTrue(report["checked_every_morph_triangle_attribute"])
        primitives = doc["meshes"][0]["primitives"]
        for i, primitive in enumerate(primitives):
            source_ids = accessor_array(doc, binary, primitive["attributes"]["TEXCOORD_1"])
            np.testing.assert_array_equal(source_ids, [[0, i], [1, i], [2, i]])
            self.assertEqual(primitive["extras"]["source_submesh_indices"], [i])
            material = doc["materials"][primitive["material"]]
            self.assertIn(f"__hugo_anim_g000_r0000_p{i:03d}__hugo_blend_3", material["name"])

    def test_animated_surface_isolation_keeps_godot_surface_limit(self):
        catalog = animated_catalog()
        mesh = parse_mesh(catalog.record(0, 0, 2001))
        model = replace(mesh, parts=tuple(replace(mesh.parts[0], index=i) for i in range(129)))
        raw = export_glb(catalog, [Selection(model, "generated", np.zeros(3), np.eye(3))], include_samples=True)
        doc, _, mapping, report = _batch_geometry(raw)
        self.assertEqual(mapping, {0: [0, 1]})
        self.assertEqual([len(m["primitives"]) for m in doc["meshes"]], [128, 1])
        self.assertEqual(report["animated_materials"], 129)
        self.assertEqual(report["source_triangles"], report["exported_triangles"])

    def test_bad_late_texture_reference_does_not_publish_partial_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            sentinel = output / "existing.txt"
            sentinel.write_text("keep")
            with self.assertRaisesRegex(FormatError, "Unresolved texture"):
                export_material_animations(animated_catalog((7, 999)), output)
            self.assertEqual(sentinel.read_text(), "keep")
            self.assertFalse((output / "materials").exists())
            self.assertFalse((output / "material_animation_manifest.json").exists())
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_existing_export_is_rejected_without_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            export_material_animations(animated_catalog(), output)
            path = output / "material_animation_manifest.json"
            previous = path.read_bytes()
            with self.assertRaisesRegex(FormatError, "already exists"):
                export_material_animations(animated_catalog(), output)
            self.assertEqual(path.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
