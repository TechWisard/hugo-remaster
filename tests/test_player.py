"""Synthetic native-player parameter fixtures, without copyrighted data."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Record
from hugo_assets.player import decode_player_configuration


def fixture(**changes):
    fields = {0x68: 825., 0x6C: 390., 0x70: .05, 0x7C: 300., 0x80: .9,
              0x8C: 300., 0x90: 900., 0x94: .8, 0x98: .01,
              0xAC: 300., 0xB0: .005, 0xB4: 72., 0xB8: 900.}
    fields.update({int(key, 16): value for key, value in changes.items()})
    raw = bytearray(0xCC)
    struct.pack_into("<I", raw, 0, 10000)
    for offset, value in fields.items():
        struct.pack_into("<f", raw, offset, value)
    return Record(0, 0, 10000, len(raw), bytes(raw), 0)


class NativePlayerTests(unittest.TestCase):
    def test_discrete_jump_reaches_authored_height(self):
        config = decode_player_configuration(fixture())
        velocity = config["jump_initial_velocity"] / config["native_timer_hz"]
        decrement = config["jump_gravity"] / config["native_timer_hz"]**2
        height = 0.
        for _ in range(config["jump_half_ticks"]):
            height += velocity
            velocity -= decrement
        self.assertAlmostEqual(height, config["jump_height"], places=12)
        self.assertAlmostEqual(velocity, 0., places=12)

    def test_ground_and_air_units_are_distinct(self):
        config = decode_player_configuration(fixture())
        self.assertEqual(config["ground_max_speed"], 8.25)
        self.assertEqual(config["walk_run_animation_threshold"], 3.9)
        self.assertEqual(config["crawl_speed"], 3.)
        self.assertAlmostEqual(config["jump_horizontal_speed"], 11.25, places=5)
        self.assertEqual(config["fall_gravity"], 216.)
        self.assertEqual(config["fall_terminal_speed"], 9.)
        self.assertNotIn("walk_speed", config)

    def test_jump_duration_changes_velocity_not_height(self):
        slow = decode_player_configuration(fixture(**{"94": 1.2}))
        fast = decode_player_configuration(fixture())
        self.assertEqual(slow["jump_height"], fast["jump_height"])
        self.assertGreater(slow["jump_half_ticks"], fast["jump_half_ticks"])
        self.assertLess(slow["jump_initial_velocity"], fast["jump_initial_velocity"])

    def test_invalid_fields_fail_without_native_fallback_guess(self):
        for changes in [{"94": 0.}, {"68": float("nan")}, {"70": 1.2}, {"8c": -1.}]:
            with self.assertRaises(FormatError):
                decode_player_configuration(fixture(**changes))


if __name__ == "__main__":
    unittest.main()
