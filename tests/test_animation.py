"""Synthetic animation fixtures only; no original game bytes are committed."""
from pathlib import Path
import math
import struct
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from hugo_assets.animation import (decode_rotation_words, decode_timeline,
                                  nearest_path_phase, parse_transform_track, quaternion_matrix,
                                  sample_rotation, sample_timeline, sample_translation)
from hugo_assets.binary import FormatError
from hugo_assets.catalog import Record


def transform_fixture(kind, translations=(), rotations=(), loop=False):
    header = {3000: 52, 3001: 68, 3002: 64, 3003: 76}[kind]
    raw = bytearray(header)
    struct.pack_into("<I12f", raw, 0, kind, 3, 4, 5, 1, 0, 0, 0, 1, 0, 0, 0, 1)
    if kind != 3000:
        struct.pack_into("<I", raw, 52, 0x07070707)
        fields = [(56, "rotation"), (64, "translation")] if kind == 3003 else [
            (56, "translation" if kind == 3001 else "rotation")]
        for offset, field in fields:
            values = translations if field == "translation" else rotations
            struct.pack_into("<HHI", raw, offset, len(values), int(loop), len(raw))
            for value in values:
                raw += struct.pack("<3f" if field == "translation" else "<2I", *value)
    return Record(0, 0, kind, header, bytes(raw), 0)


class TimelineTests(unittest.TestCase):
    def test_q12_is_not_sixteen_bit_fraction(self):
        key = decode_timeline([0x00020800], 4, False)[0]
        self.assertEqual(key.sample, 2)
        self.assertEqual(key.fraction, 0.5)

    def test_fractional_native_slot_interpolates_coordinate_before_vertices(self):
        words = [0, 0x0800, 0x10000, 0x20000]
        self.assertEqual(sample_timeline(words, 3, False, 0.5), (0, 1, 0.75))
        self.assertEqual(sample_timeline(words, 3, False, 1.0), (2, 0, 0.0))

    def test_last_sample_wrap_preserves_fraction(self):
        self.assertEqual(sample_timeline([0, 0x10000, 0x20000], 3, True, 5 / 6), (2, 0, 0.5))
        self.assertEqual(sample_timeline([0, 0x10000], 2, True, 1.0), (0, 1, 0.0))

    def test_reserved_missing_and_nonloop_fraction_rejected(self):
        for words, count, loop in [([0x1000], 2, True), ([0x30000], 3, True),
                                    ([0x20800], 3, False), ([], 2, True)]:
            with self.assertRaises(FormatError):
                decode_timeline(words, count, loop)


class TransformTests(unittest.TestCase):
    def test_rotation_byte_order_and_signed_components(self):
        decoded = decode_rotation_words(0x804020E0, 0)
        self.assertEqual(decoded["quaternion"], [-1.0, 0.5, 0.25, -0.25])
        np.testing.assert_allclose(quaternion_matrix(decode_rotation_words(0x00000080, 0)["quaternion"]), np.eye(3))

    def test_packed_slerp_parameters_and_sign(self):
        # quarter-turn angle, cosine=-0.5, reciprocal sine=1.25
        packed = 512 | ((-512 & 2047) << 10) | (160 << 21)
        key = decode_rotation_words(0x00000080, packed)
        self.assertEqual(key["angle_turns"], 0.25)
        self.assertEqual(key["cosine"], -0.5)
        self.assertEqual(key["reciprocal_sine"], 1.25)

    def test_native_slerp_preserves_quantized_keys(self):
        a = dict(quaternion=[0., 0., 0., 1.], angle_turns=0.125,
                 cosine=math.sqrt(0.5), reciprocal_sine=math.sqrt(2.))
        b = dict(quaternion=[0., 0., math.sqrt(0.5), math.sqrt(0.5)],
                 angle_turns=0., cosine=1., reciprocal_sine=0.)
        result = sample_rotation([a, b], False, 0.5)
        angle = (0.125 * 6.2831854820251465) * 0.5
        # The stored reciprocal/cosine, rather than a fresh normalized dot,
        # determine the native interpolation weights.
        w1 = math.sin(angle) * math.sqrt(2.)
        w0 = math.cos(angle) - math.sqrt(0.5) * w1
        expected = quaternion_matrix(np.asarray(a["quaternion"]) * w0 + np.asarray(b["quaternion"]) * w1)
        np.testing.assert_allclose(result, expected)

    def test_translation_is_cubic_not_linear(self):
        keys = np.array([[0., 0., 0.], [1., 0., 0.], [4., 0., 0.], [9., 0., 0.]])
        result = sample_translation(keys, False, 0.5)
        np.testing.assert_allclose(result, [2.25, 0, 0])
        self.assertNotEqual(result[0], 2.5)
        np.testing.assert_array_equal(sample_translation(keys, False, 1), keys[-1])

    def test_loop_translation_uses_wrapped_tangents(self):
        keys = np.array([[0., 0., 0.], [4., 0., 0.], [0., 0., 0.], [-4., 0., 0.]])
        np.testing.assert_allclose(sample_translation(keys, True, 0.125), [2.5, 0, 0])
        np.testing.assert_array_equal(sample_translation(keys, True, 1), keys[0])

    def test_type_3003_decodes_both_tracks(self):
        record = transform_fixture(3003, [(1, 2, 3), (5, 6, 7)], [(0x80, 0), (0x80, 0)])
        track = parse_transform_track(record)
        self.assertEqual(track.kind, 3003)
        np.testing.assert_allclose(track.sample(0.5).translation, [3, 4, 5])
        np.testing.assert_array_equal(track.sample(0.5).matrix, np.eye(3))
        self.assertEqual(track.rotations[0]["raw_words"], [128, 0])

    def test_singleton_translation_and_static_affine_survive(self):
        track = parse_transform_track(transform_fixture(3001, [(8, 9, 10)], loop=True))
        np.testing.assert_array_equal(track.sample(0.7).translation, [8, 9, 10])
        static = parse_transform_track(transform_fixture(3000))
        np.testing.assert_array_equal(static.sample(0.3).translation, [3, 4, 5])

    def test_truncated_samples_fail_with_format_error(self):
        valid = transform_fixture(3002, rotations=[(0x80, 0), (0x80, 0)])
        bad = Record(valid.index, valid.offset, valid.kind, valid.header_size, valid.data[:-1], valid.group)
        with self.assertRaises(FormatError):
            parse_transform_track(bad)


class CameraPathTests(unittest.TestCase):
    def test_native_tracker_clamps_open_path_ends(self):
        keys = np.array([[0., 0., 0.], [10., 0., 0.], [20., 0., 0.]])
        self.assertEqual(nearest_path_phase(keys, False, np.array([-3., 0., 0.])), 0.)
        self.assertEqual(nearest_path_phase(keys, False, np.array([25., 0., 0.])), 1.)

    def test_native_ten_refinement_quantization(self):
        keys = np.array([[0., 0., 0.], [10., 0., 0.], [20., 0., 0.]])
        # The exact-zero plane takes the lower branch in the executable.
        phase = nearest_path_phase(keys, False, np.array([5., 2., 3.]))
        self.assertEqual(phase, 0.249755859375)
        self.assertEqual(nearest_path_phase(keys, False, np.array([5., 2., 3.]), 0.9), phase)

    def test_degenerate_cycle_is_bounded(self):
        keys = np.zeros((3, 3))
        self.assertEqual(nearest_path_phase(keys, True, np.ones(3), 0.7), 0.7)

    def test_single_position_does_not_require_two_neighbors(self):
        self.assertEqual(nearest_path_phase(np.array([[1., 2., 3.]]), False, np.zeros(3)), 0.)


if __name__ == "__main__":
    unittest.main()
