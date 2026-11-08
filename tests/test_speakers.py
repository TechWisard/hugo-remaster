"""Synthetic checks for native audio records, without original game bytes."""
from dataclasses import replace
import math
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.catalog import Record, Scene
from hugo_assets.gameplay import GameplayDecoder
from hugo_assets.speakers import (decode_sound_settings, decode_speaker,
                                  native_volume_db, native_volume_scalar)


def sound_record():
    data = bytearray(44)
    struct.pack_into("<3I2fIfIHHf", data, 4, 0xD, 7, 1, .8, .5,
                     0xFFC00000, .6, 10, 3, 1, 0)
    return Record(0, 100, 1000, 44, bytes(data), 1)


def fixture(kind=10500):
    sound = sound_record()
    transform = bytearray(52)
    struct.pack_into("<I12f", transform, 0, 3000, 100, 200, 300,
                     1, 0, 0, 0, 1, 0, 0, 0, 1)
    transform = Record(0, 100, 3000, 52, bytes(transform), 2)
    if kind == 10500:
        data = bytearray(72)
        struct.pack_into("<5I", data, 8, 0x80000000, 0x80010000, 1, 1, 0)
        header = 72
    else:
        data = bytearray(152 + 168)
        struct.pack_into("<If", data, 8, 0x80000000, 4)
        struct.pack_into("<f", data, 20, 8)
        struct.pack_into("<I", data, 32, (2 << 16) | 152)
        for at, stamp in [(152, 2), (236, 6)]:
            struct.pack_into("<fI", data, at, stamp, 0x80010000)
        header = 152
    owner = Record(1, 200, kind, header, bytes(data), 2)
    by_key = {(r.group, r.index): r for r in (sound, transform, owner)}

    def get_record(group, index):
        if (group, index) not in by_key:
            raise FormatError("missing reference")
        return by_key[group, index]

    scenes = {0: Scene(0, 2, 1, 16, (), ()),
              1: Scene(1, 3, 1, 32, (1,), (sound,)),
              2: Scene(2, 4, 1, 16, (), (transform, owner))}
    wav = SimpleNamespace(group=1, resource_id=7, kind=5)
    catalog = SimpleNamespace(scenes=scenes, record=get_record,
                              container=SimpleNamespace(chunks=[wav]))
    return owner, GameplayDecoder(catalog)


class SpeakerTests(unittest.TestCase):
    def test_continuous_speaker_resolves_ancestor_sample_and_activation(self):
        owner, decoder = fixture()
        out = decode_speaker(owner, decoder)
        self.assertEqual(out["position"], [1, 3, -2])
        speaker = out["speaker"]
        self.assertEqual(speaker["sound"]["path"], "audio/g001_r0007.wav")
        self.assertEqual(speaker["activation_event"], 0x32000001)
        self.assertTrue(speaker["repeat"])
        self.assertTrue(speaker["initial_pending_start"])
        self.assertFalse(speaker["source_pending_start"])
        self.assertEqual(speaker["transform_policy"], "sample_phase_zero_once")
        self.assertEqual(speaker["transform_track"], "g002_r0000")

    def test_sequence_retains_separate_timer_and_cue_normalization(self):
        owner, decoder = fixture(10501)
        speaker = decode_speaker(owner, decoder)["speaker"]
        self.assertEqual(speaker["period_seconds"], 4)
        self.assertEqual(speaker["sound_sequence"]["time_denominator"], 8)
        self.assertEqual([c["normalized_phase"] for c in speaker["sound_sequence"]["cues"]], [.25, .75])
        self.assertTrue(all(c["sound"]["spatial"] for c in speaker["sound_sequence"]["cues"]))
        self.assertFalse(speaker["stops_sounds_at_cycle_end"])
        self.assertIsNone(speaker["activation_event"])

    def test_runtime_frequency_nan_is_preserved_only_as_raw_integer(self):
        settings = decode_sound_settings(sound_record())
        self.assertEqual(settings["runtime_frequency_word_raw"], 0xFFC00000)
        self.assertTrue(settings["native_loop"])
        self.assertEqual(settings["mix_group"], 1)
        self.assertEqual(settings["exclusive_group"], 3)
        self.assertAlmostEqual(settings["volume"], .8, places=6)

    def test_native_distance_scalar_and_decibel_curve_are_distinct(self):
        s = decode_sound_settings(sound_record())
        k = .1 * s["range_coefficient"]
        self.assertAlmostEqual(native_volume_scalar(s, math.sqrt(k) * 100), s["volume"] / 2)
        self.assertEqual(native_volume_scalar(s, math.sqrt(10 * k) * 100 + .01), 0)
        self.assertAlmostEqual(native_volume_scalar(s, 0, .5, .25), s["volume"] / 8)
        self.assertEqual(native_volume_db(.5), -12.5)
        self.assertEqual(native_volume_db(0), -100)
        self.assertEqual(native_volume_db(1), 0)
        nonspatial = {**s, "flags": 1}
        self.assertEqual(native_volume_scalar(nonspatial, 10000), s["volume"])

    def test_corrupt_arrays_order_parameters_and_references_are_rejected(self):
        owner, decoder = fixture(10501)
        mutations = [(32, "<I", (3 << 16) | 152),
                     (236, "<f", 1), (12, "<f", float("nan")),
                     (156, "<I", 0x80000000), (8, "<I", 0)]
        for offset, fmt, value in mutations:
            with self.subTest(offset=offset):
                data = bytearray(owner.data)
                struct.pack_into(fmt, data, offset, value)
                with self.assertRaises(FormatError):
                    decode_speaker(replace(owner, data=bytes(data)), decoder)
        data = bytearray(sound_record().data)
        struct.pack_into("<f", data, 16, float("nan"))
        with self.assertRaises(FormatError):
            decode_sound_settings(replace(sound_record(), data=bytes(data)))
        with self.assertRaises(FormatError):
            native_volume_scalar(decode_sound_settings(sound_record()), -1)


if __name__ == "__main__":
    unittest.main()
