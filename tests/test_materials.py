"""Native ordinary-mesh states; independent of the reversed particle enum."""
from pathlib import Path
from dataclasses import replace
import copy
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.mesh import (Mesh, Part, TextureRef, decode_material_flags,
                              material_animation_manifest, sample_material_animation,
                              texture_frame_index)


def animated_fixture():
    colors = np.array([[[109, 109, 109, 0], [0, 255, 128, 0]],
                       [[29, 29, 29, 0], [255, 0, 128, 0]]], dtype=np.uint8)
    uv = np.array([[[250, 0], [255, 32]], [[10, 255], [0, 128]]], dtype=np.uint8)
    materials = (TextureRef(7, 16, 16, (0, 0)), TextureRef(7, 16, 16, (0, 0)),
                 TextureRef(9, 16, 16, (0, 0)))
    part = Part(0, 3, 0x64000000, np.zeros((2, 2, 3), dtype=np.float32), uv,
                np.array([[0, 1, 0]], dtype=np.uint16), colors, materials)
    mesh = Mesh(1, 2, 100, "synthetic", 2, (0, 1 << 16), 0, 0,
                np.zeros((2, 3)), (part,))
    return mesh, part


class NativeMaterialTests(unittest.TestCase):
    def test_recovered_surface_flags_select_d3d_blend_states(self):
        # These words occur in the source Getaway meshes: they must not all
        # collapse to an opaque material simply because the image has alpha1.
        expected = {
            0x01000000: (0, "alpha", "SRCALPHA", "INVSRCALPHA"),
            0x23000000: (1, "add", "ONE", "ONE"),
            0x43000000: (2, "multiply_inverse", "ZERO", "INVSRCCOLOR"),
            0x62000000: (3, "opaque", "ONE", "ZERO"),
        }
        for flags, value in expected.items():
            with self.subTest(flags=hex(flags)):
                result = decode_material_flags(flags)
                self.assertEqual(tuple(result[k] for k in
                                       ("blend_selector", "blend_mode", "blend_src", "blend_dst")), value)
                self.assertEqual(result["depth_write"], value[0] == 3)
                self.assertEqual(result["alpha_blend_enabled"], value[0] != 3)
                self.assertEqual(result["alpha_test"], "GREATER_EQUAL")
                self.assertAlmostEqual(result["alpha_cutoff"], 8 / 255)

    def test_native_vertex_alpha_is_generated_not_color_byte_four(self):
        for flags in (0, 0x20000000, 0x40000000, 0x60000000):
            self.assertEqual(decode_material_flags(flags, textured=True)["vertex_alpha"], 1)
            plain = decode_material_flags(flags, textured=False)
            self.assertAlmostEqual(plain["vertex_alpha"], 128 / 255)
            self.assertEqual(plain["alpha_source"], "fixed_vertex_128_of_255")

    def test_culling_animation_and_unknown_bits_are_separate_from_blend(self):
        opaque = decode_material_flags(0x60000000)
        animated_two_sided = decode_material_flags(0x67000000)
        self.assertFalse(opaque["double_sided"])
        self.assertTrue(animated_two_sided["double_sided"])
        self.assertTrue(animated_two_sided["source_color_animation"])
        self.assertEqual(animated_two_sided["blend_mode"], opaque["blend_mode"])
        self.assertEqual(animated_two_sided["uninterpreted_flags"], 0x02000000)
        self.assertTrue(decode_material_flags(0xF0000000)["native_draw_skipped"])

    def test_invalid_flag_words_are_rejected(self):
        for value in (-1, 0x100000000, 3.5, "0x60000000"):
            with self.subTest(value=value), self.assertRaises(FormatError):
                decode_material_flags(value)

    def test_texture_sequence_preserves_repeats_and_uses_visual_phase(self):
        mesh, part = animated_fixture()
        info = material_animation_manifest(mesh, part)
        self.assertEqual([frame["texture_id"] for frame in info["texture_sequence"]], [7, 7, 9])
        middle = sample_material_animation(info, 0.5)
        self.assertEqual(middle["texture_frame_index"], 1)
        self.assertEqual((middle["sample_a"], middle["sample_b"], middle["sample_weight"]), (0, 1, 0.5))
        final = sample_material_animation(info, 1.0)
        self.assertEqual(final["texture_frame_index"], 0)
        self.assertEqual(final["sample_a"], 1)
        self.assertEqual(final["rgb_bytes"][0], [29, 29, 29])

    def test_texture_frame_boundary_keeps_x87_product_before_truncation(self):
        below = float(np.float32(5 / 6))
        above = float(np.nextafter(np.float32(5 / 6), np.float32(1)))
        # float32(5/6)*6 is just BELOW five in x87; a premature float32
        # multiplication rounds it to five and selects the next image early.
        self.assertEqual(texture_frame_index(6, below), 4)
        self.assertEqual(texture_frame_index(6, above), 5)
        self.assertEqual(texture_frame_index(6, 1), 0)

    def test_rgb_uses_native_byte_truncation_and_float_temporaries(self):
        mesh, part = animated_fixture()
        info = material_animation_manifest(mesh, part)
        result = sample_material_animation(info, 0.15)
        self.assertEqual(result["rgb_bytes"][0], [96, 97, 97])
        self.assertEqual(result["rgba"][0][3], 1)
        np.testing.assert_allclose(result["rgba"][0][:3], np.array([96, 97, 97]) / 255,
                                   rtol=0, atol=1e-7)

    def test_uv_uses_linear_native_bytes_without_seam_shortcut(self):
        mesh, part = animated_fixture()
        info = material_animation_manifest(mesh, part)
        result = sample_material_animation(info, 0.5)
        # 250 -> 10 crosses the middle (130), not the texture's wrap seam.
        np.testing.assert_allclose(result["uv"], [[130 / 255, 0.5], [0.5, 80 / 255]],
                                   rtol=0, atol=1e-7)
        np.testing.assert_allclose(sample_material_animation(info, 0)["uv"][1][0], 1)

    def test_q12_timeline_remaps_color_and_uv_but_not_texture_clock(self):
        mesh, part = animated_fixture()
        mesh = replace(mesh, timeline_words=(2048, 1 << 16))
        result = sample_material_animation(material_animation_manifest(mesh, part), 0)
        self.assertEqual(result["sample_weight"], 0.5)
        self.assertEqual(result["rgb_bytes"][0], [69, 69, 69])
        self.assertEqual(result["texture_frame_index"], 0)

    def test_clear_color_flag_keeps_first_rgb_with_moving_uv(self):
        mesh, part = animated_fixture()
        part = replace(part, flags=0x60000000, colors=part.colors[:1])
        info = material_animation_manifest(mesh, part)
        self.assertFalse(info["source_color_animation"])
        self.assertTrue(info["animate_uv"])
        self.assertEqual(sample_material_animation(info, 0.75)["rgb_bytes"], part.colors[0, :, :3].tolist())

    def test_untextured_animation_omits_uv_and_uses_native_half_alpha(self):
        mesh, part = animated_fixture()
        part = replace(part, kind=1, materials=())
        info = material_animation_manifest(mesh, part)
        result = sample_material_animation(info, 0.5)
        self.assertFalse(info["textured"])
        self.assertEqual(result["uv"], [])
        self.assertIsNone(result["texture_frame_index"])
        self.assertAlmostEqual(result["rgba"][0][3], 128 / 255, places=7)

    def test_material_animation_rejects_bad_phase_and_sample_shape(self):
        mesh, part = animated_fixture()
        info = material_animation_manifest(mesh, part)
        for phase in (-0.001, 1.001, float("nan")):
            with self.subTest(phase=phase), self.assertRaises(FormatError):
                sample_material_animation(info, phase)
        with self.assertRaises(FormatError):
            material_animation_manifest(mesh, replace(part, colors=part.colors[:1]))
        corrupt = copy.deepcopy(info)
        corrupt["uv_samples"][0][0][0] = 256
        with self.assertRaises(FormatError):
            sample_material_animation(corrupt, 0.5)


if __name__ == "__main__":
    unittest.main()
