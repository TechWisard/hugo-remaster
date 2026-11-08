"""Synthetic source-loader checks; no original bytes or runtime EXE required."""
from dataclasses import replace
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog, Record, Scene
from hugo_assets.mdic import Chunk, Container, Group
from hugo_assets.scopes import (actor_in_range, choose_neighbor, decode_actor_range,
                                decode_scope_policy, native_progress_value, plan_scope_request)


def fixture(children=4):
    data = bytearray((children + 2) * 1024)
    main_at = 1024 + 32
    struct.pack_into("<IIHHI", data, main_at, 0x01010101, 0x02020202, 3, 2, 288)
    struct.pack_into("<3I", data, main_at + 20, 64 if children else 0,
                     2048 if children else 0, children)
    for ordinal in range(children):
        struct.pack_into("<I", data, main_at + 32 + ordinal * 4, 40)
        struct.pack_into("<I", data, main_at + 160 + ordinal * 4, (ordinal + 2) * 1024)
    scenes = {0: Scene(0, 2, 16, 16, (), ()),
              1: Scene(1, 3, 288, 288, (40,) * children, ())}
    chunks = {1: Chunk(1, 1, 1040, 16, 288, 4, None, None, "synthetic")}
    for ordinal in range(children):
        group = ordinal + 2
        offset = group * 1024
        struct.pack_into("<IIHHIII", data, offset + 32, 0x01010101, 0x02020202,
                         4, group + 1, 24, (group - 1) * 1024 if ordinal else 0,
                         (group + 1) * 1024 if ordinal + 1 < children else 0)
        transform = struct.pack("<I12f", 3000, 100, 200, 300,
                                0, 2, 0, -1, 0, 0, 0, 0, 1)
        trigger = bytearray(96)
        struct.pack_into("<I", trigger, 12, 0x80000000)
        actor = bytearray(156)
        struct.pack_into("<2i", actor, 0x90, 248, 496)
        records = (Record(0, 40, 3000, 52, transform, group),
                   Record(1, 92, 10600, 96, bytes(trigger), group),
                   Record(2, 188, 10401, 156, bytes(actor), group))
        scenes[group] = Scene(group, 4, 24, 24, (), records)
        chunks[group] = Chunk(group, group, offset + 16, 16, 24, 4, None, None, "synthetic")
    catalog = Catalog.__new__(Catalog)
    catalog.container = Container(bytes(data), list(chunks.values()),
                                  [Group(g, g * 1024, 1024, 1) for g in range(children + 2)], {})
    catalog.scenes, catalog.scene_chunks = scenes, chunks
    return catalog


class ScopeTests(unittest.TestCase):
    def test_child_tables_buffer_slots_and_first_segment_are_verified(self):
        policy = decode_scope_policy(fixture(), 1)
        self.assertEqual(policy["persistent_groups"], [0, 1])
        self.assertEqual(policy["initial_segment_groups"], [2])
        self.assertEqual(policy["max_resident_segments"], 2)
        self.assertEqual([s["buffer_byte_offset"] for s in policy["segments"]], [0, 40, 0, 40])
        self.assertEqual(policy["required_adjacent_payload_capacity"], 48)
        self.assertEqual(policy["checkpoint"]["restore"], "unload_all_then_recreate_saved")
        self.assertFalse(policy["residency"]["render_only_preload"])

    def test_plane_uses_camera_and_matrix_column_without_aabb_or_normalization(self):
        policy = decode_scope_policy(fixture(), 1)
        trigger = policy["triggers"][1]
        self.assertEqual(trigger["origin"], [1, 3, -2])
        self.assertEqual(trigger["normal"], [2, 0, 0])
        self.assertEqual(trigger["trigger_reference"], "camera_position")
        self.assertFalse(trigger["requires_aabb_intersection"])
        self.assertEqual(choose_neighbor(trigger, [0, 100000, -100000]), 2)
        self.assertEqual(choose_neighbor(trigger, [2, 100000, -100000]), 4)
        self.assertEqual(choose_neighbor(trigger, [1, 3, -2]), 4)
        self.assertIsNone(choose_neighbor(policy["triggers"][0], [0, 3, -2]))

    def test_window_requests_preserve_near_neighbor_and_evict_far_end(self):
        policy = decode_scope_policy(fixture(), 1)
        forward = plan_scope_request(policy, [2, 3], 4)
        self.assertEqual(forward, dict(requested_group=4, unload_groups=[2],
                                       load_groups=[4], resident_after=[3, 4]))
        backward = plan_scope_request(policy, [3, 4], 2)
        self.assertEqual(backward["unload_groups"], [4])
        self.assertEqual(backward["resident_after"], [2, 3])
        self.assertEqual(plan_scope_request(policy, [2], 3)["resident_after"], [2, 3])
        self.assertEqual(plan_scope_request(policy, [2, 3], 2)["load_groups"], [])
        for resident, requested in [([2, 4], 3), ([2, 2], 3), ([2, 3, 4], 5), ([2], 99)]:
            with self.subTest(resident=resident, requested=requested), self.assertRaises(FormatError):
                plan_scope_request(policy, resident, requested)

    def test_progress_uses_992_and_inclusive_authored_bounds(self):
        policy = decode_scope_policy(fixture(), 1)
        active_range = policy["actor_ranges"]["g002_o0002_t10401"]
        self.assertEqual(native_progress_value(.5), 496)
        self.assertEqual(native_progress_value(1), 992)
        self.assertTrue(actor_in_range(active_range, .25))
        self.assertTrue(actor_in_range(active_range, .5))
        self.assertFalse(actor_in_range(active_range, .249))
        self.assertFalse(actor_in_range(active_range, .502))
        self.assertEqual(active_range["source_field_offsets"], [0x90, 0x94])
        default = policy["actor_ranges"]["g002_o0001_t10600"]
        self.assertEqual((default["minimum"], default["maximum"]), (0, 1000))

    def test_reversed_source_range_stays_disabled_and_collision_only_has_no_gate(self):
        record = fixture().scenes[2].records[2]
        data = bytearray(record.data)
        struct.pack_into("<2i", data, 0x90, 555, 550)
        active_range = decode_actor_range(replace(record, data=bytes(data), kind=10402))
        self.assertTrue(active_range["never_in_range"])
        self.assertFalse(any(actor_in_range(active_range, p / 1000) for p in range(1001)))
        self.assertIsNone(decode_actor_range(replace(record, kind=10203)))

    def test_corrupt_headers_buffers_neighbor_links_and_refs_fail(self):
        for offset, value in [(1056 + 28, 33), (1056 + 24, 4096),
                              (1056 + 160, 999), (1056 + 20, 47),
                              (1056 + 32, 39), (2048 + 32 + 20, 4096)]:
            catalog = fixture()
            data = bytearray(catalog.container.data)
            struct.pack_into("<I", data, offset, value)
            catalog.container.data = bytes(data)
            with self.subTest(offset=offset), self.assertRaises(FormatError):
                decode_scope_policy(catalog, 1)
        catalog = fixture()
        records = list(catalog.scenes[2].records)
        records[1] = replace(records[1], data=bytes(96))
        catalog.scenes[2] = replace(catalog.scenes[2], records=tuple(records))
        with self.assertRaisesRegex(FormatError, "segment-trigger plane"):
            decode_scope_policy(catalog, 1)

    def test_empty_scene_and_nonfinite_runtime_queries(self):
        policy = decode_scope_policy(fixture(0), 1)
        self.assertEqual(policy["initial_segment_groups"], [])
        self.assertEqual(policy["segments"], [])
        with self.assertRaises(FormatError):
            native_progress_value(float("nan"))
        trigger = decode_scope_policy(fixture(), 1)["triggers"][0]
        with self.assertRaises(FormatError):
            choose_neighbor(trigger, [float("inf"), 0, 0])


if __name__ == "__main__":
    unittest.main()
