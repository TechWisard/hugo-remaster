"""Synthetic regression tests for recovered gameplay structures.

No original binary assets are copied into fixtures. Optional native integration
is exercised by the importer, which retains both source and executable hashes.
"""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.catalog import Record, Scene
from hugo_assets.gameplay import GameplayDecoder, godot_position, stable_id


def record(group, index, kind, size, data=None):
    return Record(index, 100 + index * 4096, kind, size, bytes(size) if data is None else bytes(data), group)


def decoder(records):
    scenes = {0: Scene(0, 2, 1, 16, (), ()),
              1: Scene(1, 3, 1, 32, (1,), ()),
              2: Scene(2, 4, 1, 16, (), ())}
    by_key = {(r.group, r.index): r for r in records}
    for group in scenes:
        scenes[group] = replace(scenes[group], records=tuple(r for r in records if r.group == group))

    def get_record(group, index):
        if (group, index) not in by_key:
            raise FormatError("missing reference")
        return by_key[(group, index)]

    cat = SimpleNamespace(scenes=scenes, record=get_record,
                          container=SimpleNamespace(chunks=[]),
                          scene_chunks={g: SimpleNamespace(offset=g * 4096, header_size=16) for g in scenes})
    return GameplayDecoder(cat)


def state_fixture():
    # Header + two states + one transition + one notification. Packed offsets
    # are relative to the owner record, even when stored inside a state.
    data = bytearray(632 + 2 * 72 + 12 + 16)
    struct.pack_into("<I", data, 0xAC, (2 << 16) | 632)
    struct.pack_into("<i", data, 0x14, 3)
    for n in range(2):
        offset = 632 + n * 72
        struct.pack_into("<iifiififI", data, offset, n, 2, 4.0, 1, 0x3F800000, 0.5, 2, 1.5, 0)
        struct.pack_into("<f", data, offset + 0x28, 1)
    struct.pack_into("<I", data, 632 + 0x38, (1 << 16) | (632 + 144))
    struct.pack_into("<Iii", data, 632 + 144, 0x200, 1, 7)
    struct.pack_into("<I", data, 704 + 0x20, 0x4101)
    struct.pack_into("<I", data, 704 + 0x40, (1 << 16) | (632 + 144 + 12))
    struct.pack_into("<4I", data, 632 + 144 + 12, 0x80010000, 0x22000002, 0, 0)
    return record(2, 0, 10300, 632, data)


class GameplayTests(unittest.TestCase):
    def test_reference_scope_is_ancestry_not_absolute_group(self):
        root, parent, child = record(0, 0, 6017, 464), record(1, 0, 10301, 420), record(2, 0, 3000, 52)
        d = decoder([root, parent, child])
        self.assertIs(d.reference(2, 0x80000000), child)
        self.assertIs(d.reference(2, 0x80010000), parent)
        self.assertIs(d.reference(2, 0x80020000), root)
        self.assertIsNone(d.reference(2, 0))
        with self.assertRaisesRegex(FormatError, "scope"):
            d.reference(2, 0x80030000)
        with self.assertRaisesRegex(FormatError, "non-resource"):
            d.reference(2, 1)

    def test_source_identity_and_rotated_bounds(self):
        transform = bytearray(52)
        struct.pack_into("<I12f", transform, 0, 3000, 100, 200, 300, 0, -1, 0, 1, 0, 0, 0, 0, 1)
        tr = record(2, 0, 3000, 52, transform)
        trigger = bytearray(188)
        struct.pack_into("<I", trigger, 8, 0x80000000)
        struct.pack_into("<6f", trigger, 0x3C, -10, -20, -30, 10, 20, 30)
        owner = record(2, 1, 10602, 188, trigger)
        decoded = decoder([tr, owner]).owner(owner)
        self.assertEqual(stable_id(owner), "g002_o0001_t10602")
        self.assertEqual(decoded["position"], [1, 3, -2])
        self.assertEqual(decoded["bounds"]["world_min"], [.8, 2.7, -2.1])
        self.assertEqual(decoded["bounds"]["world_max"], [1.2, 3.3000000000000003, -1.9000000000000001])
        self.assertFalse(decoded["requires_all_diamonds"])
        self.assertEqual(decoded["event"], 0x22000040)

    def test_corrupt_bounds_and_nonfinite_transforms_fail(self):
        data = bytearray(188)
        struct.pack_into("<6f", data, 0x3C, 1, 0, 0, -1, 1, 1)
        r = record(2, 0, 10602, 188, data)
        with self.assertRaisesRegex(FormatError, "unordered"):
            decoder([r]).owner(r)
        tr = bytearray(52)
        struct.pack_into("<f", tr, 4, float("nan"))
        t = record(2, 0, 3000, 52, tr)
        struct.pack_into("<I", data, 8, 0x80000000)
        r = record(2, 1, 10602, 188, data)
        with self.assertRaisesRegex(FormatError, "non-finite"):
            decoder([t, r]).owner(r)

    def test_powerup_fields_do_not_confuse_health_amount_or_activation(self):
        data = bytearray(420)
        struct.pack_into("<hhHH", data, 0x10, 1, 2, 50, 1)
        r = record(2, 0, 10301, 420, data)
        pickup = decoder([r]).owner(r)["pickup"]
        self.assertEqual(pickup["diamonds"], 1)
        self.assertEqual(pickup["lives"], 2)
        self.assertIs(pickup["health"], True)
        self.assertEqual(pickup["healing_by_difficulty"], [20, 10, 5])
        self.assertEqual(pickup["health_field_raw"], 50)
        self.assertTrue(pickup["starts_inactive"])

    def test_state_table_keeps_target_refs_checkpoint_flags_and_event_order(self):
        actor = state_fixture()
        target = record(1, 0, 10301, 420)
        state_machine = decoder([actor, target]).state_actor(actor)
        self.assertEqual(state_machine["initial_health_base"], 3)
        self.assertEqual(state_machine["checkpoint_states"], [1])
        a, b = state_machine["states"]
        self.assertEqual(a["transitions"][0]["next_state"], 1)
        self.assertEqual(a["transitions"][0]["argument"], 7)
        self.assertEqual(b["entry_events"][0]["target"], stable_id(target))
        self.assertEqual(b["entry_events"][0]["event"], 0x22000002)
        self.assertTrue(b["checkpoint_on_collision"])
        self.assertTrue(b["save_world_state_on_entry"])

    def test_corrupt_packed_arrays_and_invalid_transitions_fail(self):
        original = state_fixture()
        for offset, value, message in [(0xAC, (0xFFFF << 16) | 632, "outside"),
                                       (0xAC, (1 << 16) | 20, "overlaps"),
                                       (632 + 144 + 4, 2, "transition")]:
            with self.subTest(offset=offset):
                data = bytearray(original.data)
                struct.pack_into("<I", data, offset, value)
                corrupt = replace(original, data=bytes(data))
                with self.assertRaisesRegex(FormatError, message):
                    decoder([corrupt, record(1, 0, 10301, 420)]).state_actor(corrupt)

    def test_notification_parameters_are_refs_only_when_flagged(self):
        target, extra = record(1, 0, 10300, 632), record(0, 0, 6017, 464)
        data = struct.pack("<5I", 0x80010000, 0x22000004, 0x80020000, 17, 1)
        event_record = record(2, 0, 0, 20, data)
        result = decoder([target, extra, event_record]).event(event_record, 0, True)
        self.assertEqual(result["target"], stable_id(target))
        self.assertEqual(result["param1_reference"], stable_id(extra))
        self.assertEqual(result["param2"], 17)
        self.assertNotIn("param2_reference", result)

    def test_source_phase_percentages_and_persistent_checkpoint_flag(self):
        original = state_fixture()
        data = bytearray(original.data)
        struct.pack_into("<2f", data, 0x1C, 25, 37.5)
        struct.pack_into("<I", data, 0x264, 1)
        actor = replace(original, data=bytes(data))
        target = record(1, 0, 10301, 420)
        decoded = decoder([actor, target]).state_actor(actor)
        self.assertEqual(decoded["initial_visual_phase"], .25)
        self.assertEqual(decoded["initial_transform_phase"], .375)
        self.assertEqual(decoded["checkpoint_snapshot_fields"], ["persistent_activation_flag"])
        struct.pack_into("<f", data, 0x20, float("nan"))
        with self.assertRaisesRegex(FormatError, "non-finite"):
            decoder([replace(actor, data=bytes(data)), target]).state_actor(replace(actor, data=bytes(data)))

    def test_camera_effect_ref_and_duration_are_distinct_parameter_types(self):
        camera = record(1, 0, 10101, 228)
        track = record(1, 1, 3001, 52)
        data = struct.pack("<III f I", 0x80010000, 0x22000009, 0x80010001, 1.25, 1)
        descriptor = record(2, 0, 0, 20, data)
        event = decoder([camera, track, descriptor]).event(descriptor, 0, True)
        self.assertEqual(event["camera_effect"]["transform"], stable_id(track))
        self.assertEqual(event["camera_effect"]["duration_seconds"], 1.25)
        self.assertEqual(event["camera_effect"]["sample_component"], "source_translation_x")
        self.assertNotIn("param2_reference", event)
        corrupt = bytearray(data)
        struct.pack_into("<f", corrupt, 12, 0)
        descriptor = replace(descriptor, data=bytes(corrupt))
        with self.assertRaisesRegex(FormatError, "camera-effect duration"):
            decoder([camera, track, descriptor]).event(descriptor, 0, True)


if __name__ == "__main__":
    unittest.main()
