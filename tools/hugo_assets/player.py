"""Player parameters recovered from CHugoMainActor's stored fields and code.

No executable is loaded or run. Values in source records are converted to the
exporter's .01 scene scale; executable constants are documented separately.
"""
from __future__ import annotations

import math

from .binary import Reader, require
from .catalog import Record


TIMER_HZ = 300
SOURCE_SCALE = 0.01
FIELD_MEANINGS = {
    0x68: "ground_max_speed_source_per_second",
    0x6C: "walk_run_animation_threshold_source_per_second",
    0x70: "ground_response_per_tick",
    0x7C: "crawl_speed_source_per_second",
    0x80: "crawl_response_per_tick",
    0x8C: "jump_height_source_units",
    0x90: "jump_horizontal_distance_source_units",
    0x94: "jump_authored_duration_seconds",
    0x98: "jump_air_response_per_tick",
    0xAC: "fall_horizontal_speed_source_per_second",
    0xB0: "fall_air_response_per_tick",
    0xB4: "fall_velocity_decrement_source_per_second_per_tick",
    0xB8: "fall_terminal_speed_source_per_second",
}


def decode_player_configuration(record: Record) -> dict:
    """Return evidence-labelled movement configuration for a type-10000 owner.

    The .6C field only switches visual actions. The executable uses .68 for
    both walk and run, multiplied by analog input magnitude; a digital key
    requests full movement. No second guessed walking speed is introduced.
    """
    require(record.kind == 10000, f"{record.label}: not a Hugo player record")
    reader = Reader(record.data, record.label)
    values = {offset: reader.unpack("<f", offset)[0] for offset in FIELD_MEANINGS}
    require(all(math.isfinite(value) for value in values.values()),
            f"{record.label}: non-finite player parameter")
    require(all(values[offset] > 0 for offset in (0x68, 0x6C, 0x7C, 0x8C,
                                                 0x90, 0x94, 0xAC, 0xB4, 0xB8)),
            f"{record.label}: invalid player speed/flight parameter")
    require(all(0 <= values[offset] <= 1 for offset in (0x70, 0x80, 0x98, 0xB0)),
            f"{record.label}: invalid player response coefficient")
    # 0x404412..0x404449: truncate duration*300, halve it, then construct a
    # discrete parabola whose sum of the first n velocities equals the height.
    half_ticks = int(values[0x94] * TIMER_HZ) // 2
    require(half_ticks > 0, f"{record.label}: jump lasts fewer than two timer ticks")
    initial_per_tick = 2.0 * values[0x8C] / (half_ticks + 1)
    gravity_per_tick_squared = initial_per_tick / half_ticks
    return {
        "schema_version": 1,
        "native_timer_hz": TIMER_HZ,
        "source_scale": SOURCE_SCALE,
        "ground_max_speed": values[0x68] * SOURCE_SCALE,
        "walk_run_animation_threshold": values[0x6C] * SOURCE_SCALE,
        "ground_response_per_tick": values[0x70],
        "crawl_speed": values[0x7C] * SOURCE_SCALE,
        "crawl_response_per_tick": values[0x80],
        "jump_height": values[0x8C] * SOURCE_SCALE,
        "jump_authored_duration_seconds": values[0x94],
        "jump_half_ticks": half_ticks,
        "jump_initial_velocity": initial_per_tick * TIMER_HZ * SOURCE_SCALE,
        "jump_gravity": gravity_per_tick_squared * TIMER_HZ**2 * SOURCE_SCALE,
        "jump_horizontal_speed": values[0x90] / values[0x94] * SOURCE_SCALE,
        "jump_response_per_tick": values[0x98],
        "fall_horizontal_speed": values[0xAC] * SOURCE_SCALE,
        "fall_response_per_tick": values[0xB0],
        "fall_gravity": values[0xB4] * TIMER_HZ * SOURCE_SCALE,
        "fall_terminal_speed": values[0xB8] * SOURCE_SCALE,
        # Fixed EXE values, not inferred from the mesh or its changing bounds.
        "standing_box_size": [0.8, 3.0, 0.8],
        "crouching_box_size": [0.8, 2.0, 0.8],
        "jump_position_lift": 0.01,
        "jump_drop_to_fall_distance": 3.0,
        "stop_speed_squared": 0.10000000149011612 * (TIMER_HZ * SOURCE_SCALE)**2,
        "invulnerability_seconds": 2.0,
        "source_fields": {f"0x{offset:04x}": {"value": values[offset], "meaning": meaning}
                          for offset, meaning in FIELD_MEANINGS.items()},
        "evidence": {
            "per_tick_conversion": "0x401CAF..0x401D2F; source speeds multiplied by 1/300",
            "ground_movement": "0x40495C..0x404AB6; v = target*response + v*(1-response), sum per tick",
            "walk_run_threshold": "0x404AED..0x404B06; input magnitude*.68 compared with .6C",
            "crawl": "0x4035EB..0x403729; source .7C speed and .80 response",
            "jump_parabola": "0x404400..0x404449; position uses velocity before decrement at 0x404660..0x404675",
            "jump_horizontal": "0x401CD5..0x401CE7, 0x40458E..0x40465D; .90/.94 and .98 response",
            "jump_entry": "0x404898..0x4048D8; +1 source Z, horizontal velocity rescaled by jump/ground speed",
            "fall": "0x403DB2..0x403EC4; .AC target, .B0 response, .B4 decrement, .B8 clamp",
            "jump_to_fall": "0x404765..0x404794; 300 source units below jump origin",
            "body_box": "0x4021D8..0x402240; bounds (-40,-40,0)..(40,40,300)",
            "body_height": "actor+0x244 = 300 (idle 0x4043D3), 200 (crawl 0x4038C6)",
            "stop_threshold": "0x404243/0x40454A; source velocity squared < 0.1 tick-units squared",
            "invulnerability": "0x40274B/0x402E12; 600 ticks, damage >=1000 bypasses cooldown",
            "digital_input": "0x4018C0..0x401A46; directional bytes converted to magnitude, no separate sprint multiplier",
        },
        "limitations": [
            "Godot resolves world contact; this configuration does not reproduce the native collision solver.",
            "Digital diagonal normalization and camera-relative input use the new input layer.",
            "Source .6C is an animation threshold, not an independently authored walking speed.",
        ],
    }
