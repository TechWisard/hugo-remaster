"""Native CSpeaker/CLoudSpeaker and shared CSound settings.

The code reads source records only. Executable addresses documenting each
interpretation are listed in docs/source_audio.md. Serialized frequency words
can contain uninitialized bytes; they are preserved as integers, never used as
an authored pitch or serialized as NaN.
"""
from __future__ import annotations

import math
from typing import TYPE_CHECKING

from .binary import Reader, require
from .catalog import Record

if TYPE_CHECKING:
    from .gameplay import GameplayDecoder


def decode_sound_settings(record: Record) -> dict:
    """Return flat fields suitable for every GameplayDecoder.sound() result."""
    r = Reader(record.data, record.label)
    require(record.kind == 1000 and record.header_size == 44 and len(record.data) == 44,
            f"{r.label}: unsupported CSound layout")
    flags = r.u32(4)
    volume, pan = r.unpack("<2f", 16)
    coefficient = r.unpack("<f", 28)[0]
    squared_offset = r.unpack("<f", 40)[0]
    require(all(math.isfinite(v) for v in (volume, pan, coefficient, squared_offset))
            and volume >= 0 and 0 <= pan <= 1 and coefficient >= 0 and squared_offset >= 0,
            f"{r.label}: invalid sound gain/distance parameters")
    exclusive, mix_group = r.unpack("<HH", 36)
    require(mix_group < 64, f"{r.label}: sound mix group exceeds native table")
    k = .1 * (coefficient if flags & 8 else 1)
    return dict(volume=volume, flags=flags, range_coefficient=coefficient,
                native_loop=bool(flags & 1), spatial=bool(flags & 4),
                custom_range=bool(flags & 8), suppress_same_group=bool(flags & 0x20),
                exclusive_group=exclusive, mix_group=mix_group,
                source_pan=pan, source_priority_raw=r.u32(32),
                runtime_frequency_word_raw=r.u32(24),
                source_distance_squared_offset=squared_offset,
                distance_squared_offset_enabled=bool(flags & 0x40),
                attenuation=dict(source_distance_multiplier=.0001,
                                 godot_distance_multiplier=.01,
                                 squared_distance_coefficient=k,
                                 cutoff_squared_multiplier=10,
                                 cutoff_distance=100 * math.sqrt(10 * k)
                                 if flags & 4 and not flags & 0x40 else None,
                                 equation="volume * k / (k + squared_distance); zero beyond 10*k"),
                volume_db_equation="v == 0 ? -100 : trunc((v - 1) * 2500) / 100",
                source_setting_offsets=dict(flags=4, sample=8, volume=16, pan=20,
                                            runtime_frequency_word=24, range_coefficient=28,
                                            priority=32, exclusive_group=36, mix_group=38,
                                            distance_squared_offset=40),
                settings_evidence_va=["0x00418bc0", "0x00419210", "0x004209e1", "0x00420b86"],
                settings_limits=["Serialized frequency word is runtime storage, not a verified pitch.",
                                 "Source pan is retained; modern spatial panning can differ from the legacy backend."])


def native_volume_scalar(settings: dict, distance_godot: float = 0,
                         master_scalar: float = 1, mix_scalar: float = 1) -> float:
    """Transcribe 0x419210 attenuation, using the exporter's world units.

    The original engine scales source position differences by 1e-4. Exported
    positions are source * .01, hence exported distance * .01 here. The final
    scalar is NOT a linear amplitude: native_volume_db performs the backend's
    subsequent conversion.
    """
    require(all(math.isfinite(v) and v >= 0 for v in
                (distance_godot, master_scalar, mix_scalar)), "Invalid sound distance/master gain")
    flags, volume = int(settings["flags"]), float(settings["volume"])
    require(math.isfinite(volume) and volume >= 0, "Invalid source sound volume")
    gain = volume
    if flags & 4:
        d2 = (distance_godot * .01) ** 2
        if flags & 0x40:
            d2 -= float(settings["source_distance_squared_offset"])
        if d2 > 0:
            k = .1 * (float(settings["range_coefficient"]) if flags & 8 else 1)
            require(math.isfinite(k) and k >= 0, "Invalid source sound range")
            gain = 0 if d2 > 10 * k else volume * k / (k + d2)
    return gain * master_scalar * mix_scalar


def native_volume_db(scalar: float) -> float:
    """DirectSound hundredth-dB conversion in 0x4209E1/0x420B86."""
    require(math.isfinite(scalar) and scalar >= 0, "Invalid native volume scalar")
    return -100.0 if scalar == 0 else math.trunc((scalar - 1) * 2500) / 100


def _sound_ref(record: Record, offset: int, decoder: GameplayDecoder) -> dict:
    sound = decoder.sound_ref(record, offset)
    require(sound is not None and "unresolved_sound_class" not in sound,
            f"{record.label}: speaker cue does not resolve to CSound")
    target = decoder.catalog.record(sound["reference"]["group"], sound["reference"]["record"])
    return {**sound, **decode_sound_settings(target)}


def decode_speaker(record: Record, decoder: GameplayDecoder) -> dict:
    """Return owner.update()-compatible metadata; no files are written.

    Owner matrices/track bytes are exported by levels.py. This decoder links
    their stable track keys and supplies native timing/event behavior.
    """
    r = Reader(record.data, record.label)
    require(record.kind in (10500, 10501), f"{r.label}: expected speaker type")
    expected = 72 if record.kind == 10500 else 152
    require(record.header_size == expected, f"{r.label}: unsupported speaker header")
    r.check(0, expected, "speaker header")
    pose = decoder.pose(record, 8)
    require(pose is not None, f"{r.label}: missing speaker transform")
    ref = pose["reference"]
    data = dict(transform_track=f"g{ref['group']:03d}_r{ref['record']:04d}",
                update_event=0x22020003,
                stops_on_scope_unload=True,
                source_field_offsets=dict(transform=8))
    if record.kind == 10500:
        require(len(record.data) == expected, f"{r.label}: trailing CSpeaker data")
        repeat, enabled, pending = r.unpack("<3I", 16)
        require(repeat in (0, 1) and enabled in (0, 1) and pending in (0, 1),
                f"{r.label}: invalid CSpeaker boolean fields")
        data.update(mode="continuous", sound=_sound_ref(record, 12, decoder),
                    repeat=bool(repeat), initial_enabled=bool(enabled),
                    initial_pending_start=True, source_pending_start=bool(pending),
                    activation_event=0x32000001,
                    activation_behavior="enable and arm; current playback is not interrupted",
                    transform_policy="sample_phase_zero_once",
                    start_policy="on first update while enabled and not playing",
                    finish_policy="restart if pending_start or repeat; otherwise disable",
                    evidence_va=["0x00404cb0", "0x00404d3d", "0x00404e50"])
        data["source_field_offsets"].update(sound=12, repeat=16, enabled=20, pending_start=24)
    else:
        period = r.unpack("<f", 12)[0]
        initial_phase = r.unpack("<f", 52)[0]
        require(math.isfinite(period) and period > 0 and math.isfinite(initial_phase)
                and 0 <= initial_phase <= 1, f"{r.label}: invalid CLoudSpeaker timer")
        start, count = decoder.packed_array(record, 32, 84)
        require(start == expected and len(record.data) == expected + 84 * count,
                f"{r.label}: unsupported CLoudSpeaker cue layout")
        sequence = decoder.sound_sequence(record, 16)
        denominator = sequence["time_denominator"]
        require(math.isfinite(denominator) and denominator > 0,
                f"{r.label}: invalid CLoudSpeaker cue denominator")
        previous = -math.inf
        for cue in sequence["cues"]:
            phase = cue["normalized_phase"]
            require(previous <= phase <= 1 and phase >= 0,
                    f"{r.label}: unordered or out-of-cycle CLoudSpeaker cues")
            previous = phase
            cue["sound"] = _sound_ref(record, cue["source_field_offset"] + 4, decoder)
        data.update(mode="sequence", sound_sequence=sequence, repeat=True,
                    initial_enabled=True, period_seconds=period, initial_phase=initial_phase,
                    activation_event=None, transform_policy="sample_normalized_sequence_phase",
                    timer_policy="phase += delta/period; wrap when phase > 1",
                    cue_policy="play due cues in source order; reset cursor after processing a wrapped update",
                    stops_sounds_at_cycle_end=False,
                    evidence_va=["0x00406250", "0x00406460", "0x004158d0", "0x004159f0", "0x00416100"])
        data["source_field_offsets"].update(period_seconds=12, sound_sequence=16,
                                            cue_array=32, initial_phase=52)
    return dict(transform=pose, position=pose["position"], speaker=data)
