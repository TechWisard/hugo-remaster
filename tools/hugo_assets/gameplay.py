"""Recover native gameplay data from MDIC records, without executing the game.

Field meanings come from the unmodified HUGO4_PC.EXE factory and handlers.
Unknown flags remain numeric.  In particular, CSimpleStateActor is a general
state machine: its class ID does not establish that an object is an enemy.
See docs/gameplay_recovery.md for executable addresses and limitations.
"""
from __future__ import annotations

from collections import Counter
import math
from pathlib import Path

from .binary import Reader, require
from .catalog import Catalog, Record
from .mdic import write_json
from .player import decode_player_configuration
from .scene_graph import parse_graph
from .speakers import decode_sound_settings, decode_speaker


EXE_SHA256 = "bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3"
NATIVE_CLASSES = {
    10000: ("CHugoMainActor", "player", 0x401A50),
    10101: ("CTargetCam", "camera", 0x40A3D0),
    10200: ("CActorTrigger", "actor_trigger", 0x404EF0),
    10203: ("CNotifyTrigger", "notify_trigger", 0x406570),
    10204: ("CFallTrigger", "fall_trigger", 0x406020),
    10300: ("CSimpleStateActor", "state_actor", 0x407850),
    10301: ("CPowerUp", "pickup", 0x406FC0),
    10400: ("CDefaultSegment", "collision_segment", 0x405960),
    10401: ("COrnemental", "decoration", 0x406850),
    10402: ("CPlatform", "platform", 0x406C20),
    10403: ("CBackmap", "background", 0x4055B0),
    10500: ("CSpeaker", "speaker", 0x404CB0),
    10501: ("CLoudSpeaker", "loudspeaker", 0x406250),
    10600: ("CSegmentTrigger", "segment_trigger", 0x407590),
    10602: ("CEndOfLevelTrigger", "exit", 0x405B70),
}
TRANSFORM_FIELDS = {
    10000: 0x10, 10101: 0x1C, 10200: 8, 10203: 8, 10204: 8,
    10300: 0x30, 10301: 0xC, 10400: 8, 10401: 8, 10402: 8,
    10600: 0xC, 10602: 8,
}
BOX_FIELDS = {10200: 0xC, 10203: 0xC, 10204: 0x10,
              10402: 0xA0, 10600: 0x20, 10602: 0x3C}
EVENT_NAMES = {
    0x22000001: "activate_transition_mask_1",
    0x22000002: "activate_at_sender_pose",
    0x22000003: "damage",
    0x22000004: "transition_by_argument",
    0x22000005: "add_diamonds",
    0x22000006: "heal_by_difficulty",
    0x22000007: "add_lives",
    0x22000009: "camera_vertical_effect",
    0x22000011: "death_sequence_ready",
    0x22000012: "alternate_damage",
    0x22000013: "checkpoint",
    0x22000030: "save_checkpoint_state",
    0x22000031: "restore_checkpoint_state",
    0x22000040: "finish_level",
    0x22020000: "initialize_resources",
    0x22020001: "deactivate_registration",
    0x22020002: "activate_registration",
    0x22020003: "update_phase_one",
    0x22020004: "update_phase_two",
    0x22020005: "render",
    0x22020010: "query_persistent_id",
    0x22040000: "directed_logic_collision",
    0x22050000: "set_player_camera_basis",
    0x22050001: "set_player_world_position",
    0x22050002: "add_player_yaw",
    0x32000001: "enable_and_rearm_speaker",
}
TRANSITION_MEANINGS = {
    0x1: "event_22000001", 0x2: "collision_mask_intersection",
    0x4: "health_depleted", 0x8: "transform_loop_count_reached",
    0x10: "visual_loop_count_reached", 0x20: "state_elapsed_time_exceeded",
    0x40: "collision", 0x80: "damaged",
    0x100: "event_22000002", 0x200: "event_22000004_matching_argument",
}


def stable_id(record: Record) -> str:
    return f"g{record.group:03d}_o{record.index:04d}_t{record.kind}"


def godot_position(xyz: tuple | list) -> list[float]:
    """The same centimetre/axis conversion as the original mesh importer."""
    return [xyz[0] * .01, xyz[2] * .01, -xyz[1] * .01]


def _finite(values: tuple | list, label: str) -> list[float]:
    require(all(math.isfinite(v) for v in values), f"{label}: non-finite coordinates")
    return list(values)


class GameplayDecoder:
    def __init__(self, catalog: Catalog):
        self.catalog = catalog
        self.parents: dict[int, int] = {}
        for scene in catalog.scenes.values():
            if scene.category == 3:
                self.parents[scene.group] = 0
                for group in range(scene.group + 1, scene.group + 1 + len(scene.child_sizes)):
                    require(group not in self.parents, f"Group {group}: ambiguous parent")
                    self.parents[group] = scene.group
        self.audio_chunks = {(c.group, c.resource_id): c for c in catalog.container.chunks if c.kind == 5}

    def reference(self, group: int, word: int) -> Record | None:
        if word == 0:
            return None
        require(bool(word & 0x80000000), f"Group {group}: non-resource reference 0x{word:08x}")
        scope, index = (word >> 16) & 0x7FFF, word & 0xFFFF
        for _ in range(scope):
            require(group in self.parents, f"Resource 0x{word:08x}: scope exceeds ancestors")
            group = self.parents[group]
        return self.catalog.record(group, index)

    def ref_field(self, record: Record, offset: int) -> dict | None:
        word = Reader(record.data, record.label).u32(offset)
        target = self.reference(record.group, word)
        if target is None:
            return None
        return {"id": stable_id(target), "group": target.group, "record": target.index,
                "type": target.kind, "raw": word, "source_field_offset": offset}

    def source(self, record: Record) -> dict:
        chunk = self.catalog.scene_chunks[record.group]
        return {"group": record.group, "record": record.index, "type": record.kind,
                "scene_offset": record.offset,
                "container_offset": chunk.offset + chunk.header_size + record.offset,
                "record_bytes": len(record.data), "header_bytes": record.header_size}

    def pose(self, record: Record, offset: int) -> dict | None:
        ref = self.ref_field(record, offset)
        if ref is None:
            return None
        target = self.catalog.record(ref["group"], ref["record"])
        require(target.kind in (3000, 3001, 3002, 3003),
                f"{record.label}: transform field points to {target.label}")
        data = _finite(Reader(target.data, target.label).unpack("<12f", 4), target.label)
        return {"reference": ref, "source_position": data[:3], "source_basis": data[3:],
                "position": godot_position(data[:3]), "animated": target.kind != 3000,
                "sample": "initial_pose", "meaning_confidence": "native_handler_verified"}

    def box(self, record: Record, offset: int, pose: dict | None) -> dict:
        values = _finite(Reader(record.data, record.label).unpack("<6f", offset), record.label)
        require(all(values[i] <= values[i + 3] for i in range(3)),
                f"{record.label}: unordered trigger/collision bounds")
        out = {"source_field_offset": offset, "source_min": values[:3], "source_max": values[3:],
               "meaning_confidence": "native_collider_constructor_verified"}
        if pose:
            # Match mesh/level assembly's row-major source transform convention.
            origin, basis = pose["source_position"], pose["source_basis"]
            corners = []
            for mask in range(8):
                v = [values[i + (3 if mask & (1 << i) else 0)] for i in range(3)]
                xyz = [origin[i] + sum(basis[i * 3 + j] * v[j] for j in range(3)) for i in range(3)]
                corners.append(godot_position(xyz))
            out["world_min"] = [min(v[i] for v in corners) for i in range(3)]
            out["world_max"] = [max(v[i] for v in corners) for i in range(3)]
            out["world_bounds_kind"] = "enclosing_aabb_of_initial_oriented_box"
        return out

    def packed_array(self, record: Record, offset: int, stride: int) -> tuple[int, int]:
        reader = Reader(record.data, record.label)
        packed = reader.u32(offset)
        start, count = packed & 0xFFFF, packed >> 16
        require(count == 0 or start >= record.header_size,
                f"{record.label}: packed array at 0x{offset:x} overlaps header")
        reader.check(start, count * stride, "packed array")
        return start, count

    def event(self, record: Record, offset: int, with_flags: bool = False) -> dict:
        reader = Reader(record.data, record.label)
        target_word, event, param1, param2 = reader.unpack("<4I", offset)
        flags = reader.u32(offset + 16) if with_flags else 0
        target = self.reference(record.group, target_word)
        out = {"source_field_offset": offset, "target": stable_id(target) if target else None,
               "target_raw": target_word, "event": event, "event_hex": f"0x{event:08x}",
               "param1": param1, "param2": param2,
               "meaning_confidence": "native_dispatch_verified"}
        if event in EVENT_NAMES:
            out["protocol_name"] = EVENT_NAMES[event]
        if with_flags:
            out["parameter_reference_flags"] = flags
            for bit, word, key in [(1, param1, "param1_reference"), (2, param2, "param2_reference")]:
                if flags & bit and word:
                    dest = self.reference(record.group, word)
                    out[key] = stable_id(dest) if dest else None
        if event == 0x22000009:
            duration = reader.unpack("<f", offset + 12)[0]
            require(math.isfinite(duration) and duration > 0,
                    f"{record.label}: invalid camera-effect duration")
            out["camera_effect"] = {
                "transform": out.get("param1_reference"), "duration_seconds": duration,
                "sample_component": "source_translation_x", "displacement_axis": "godot_y",
                "displacement_scale": .01, "ignore_while_active": True, "repeat": False,
                "evidence_va": ["0x0040a75a", "0x0040a779", "0x0040ad86", "0x0040add7"]}
        return out

    def sound(self, record: Record) -> dict:
        require(record.kind == 1000, f"{record.label}: expected CSound")
        reader = Reader(record.data, record.label)
        sample = reader.u32(8)
        group = record.group
        while (group, sample) not in self.audio_chunks and group in self.parents:
            group = self.parents[group]
        chunk = self.audio_chunks.get((group, sample))
        require(chunk is not None, f"{record.label}: unresolved WAV sample {sample}")
        return {"record_id": stable_id(record), "group": group, "resource_id": sample,
                "path": f"audio/g{group:03d}_r{sample:04d}.wav", "source_field_offset": 8,
                "settings_raw": list(reader.unpack("<10I", 4)),
                **decode_sound_settings(record),
                "meaning_confidence": "sample_id_and_ancestor_scope_verified"}

    def sound_ref(self, record: Record, offset: int) -> dict | None:
        ref = self.ref_field(record, offset)
        if ref is None:
            return None
        target = self.catalog.record(ref["group"], ref["record"])
        if target.kind != 1000:
            return {"reference": ref, "unresolved_sound_class": target.kind}
        return {"reference": ref, **self.sound(target)}

    def sound_sequence(self, record: Record, offset: int) -> dict:
        """CSoundSequence stores owner-relative 84-byte cue entries."""
        reader = Reader(record.data, record.label)
        start, count = self.packed_array(record, offset + 0x10, 84)
        denominator = reader.unpack("<f", offset + 4)[0]
        require(not count or math.isfinite(denominator) and denominator > 0,
                f"{record.label}: invalid sound-sequence time denominator")
        cues = []
        for n in range(count):
            at = start + n * 84
            stamp = reader.unpack("<f", at)[0]
            require(math.isfinite(stamp), f"{record.label}: non-finite sound cue time")
            cues.append({"source_field_offset": at, "time_raw": stamp,
                         "normalized_phase": stamp / denominator,
                         "sound": self.sound_ref(record, at + 4)})
        return {"source_field_offset": offset, "time_denominator": denominator,
                "cues": cues, "meaning_confidence": "native_sound_sequence_reader_verified",
                "evidence_va": ["0x004158ee", "0x0041592b", "0x0041597b", "0x00415a16"]}

    def state_actor(self, record: Record) -> dict:
        reader = Reader(record.data, record.label)
        death_visual = None
        graph_offset = reader.u32(0x244)
        if graph_offset:
            # This is an owner-relative embedded graph, not a resource handle.
            # CSimpleStateActor relocates it at 0x4082A2..0x4082BD and sends it
            # in damage payload+0x14; Hugo uses state zero at death entry.
            graph = parse_graph(record, graph_offset)
            death_visual = {
                "group": record.group, "record": record.index,
                "graph_offset": graph_offset, "source_field_offset": 0x244,
                "action": f"contact_death_g{record.group:03d}_r{record.index:04d}_o{graph_offset:08x}",
                "duration_seconds": graph.states[0].duration,
                "meaning_confidence": "native_damage_payload_death_graph_verified",
                "evidence_va": ["0x004082a2", "0x00408c6c", "0x004026b7", "0x00403c36"],
            }
        initial_phases = _finite(reader.unpack("<2f", 0x1C), record.label)
        start, count = self.packed_array(record, 0xAC, 72)
        require(count > 0, f"{record.label}: missing native state table")
        states = []
        for index in range(count):
            at = start + index * 72
            raw = list(reader.unpack("<18I", at))
            flags = raw[8]
            transitions_at, transitions_count = self.packed_array(record, at + 0x38, 12)
            transitions = []
            for n in range(transitions_count):
                off = transitions_at + n * 12
                mask, next_state, argument = reader.unpack("<Iii", off)
                require(next_state in (-2000, -2, -1) or 0 <= next_state < count,
                        f"{record.label}: transition points outside state table")
                transitions.append({"source_field_offset": off, "mask": mask, "next_state": next_state,
                                    "argument": argument,
                                    "known_conditions": [v for k, v in TRANSITION_MEANINGS.items() if mask & k]})
            events_at, events_count = self.packed_array(record, at + 0x40, 16)
            periods = _finite(reader.unpack("<f", at + 8) + reader.unpack("<f", at + 0x10)
                              + reader.unpack("<f", at + 0x14) + reader.unpack("<f", at + 0x1C), record.label)
            states.append({"index": index, "source_field_offset": at,
                           "visual_action": reader.unpack("<i", at)[0],
                           "transform_loop_limit": reader.unpack("<i", at + 4)[0],
                           "transform_period": periods[0],
                           "visual_loop_limit": reader.unpack("<i", at + 0xC)[0],
                           "visual_period": periods[1], "timeout_seconds": periods[2],
                           "contact_damage": reader.unpack("<i", at + 0x18)[0],
                           "knockback_multiplier": periods[3],
                           "flags": flags, "checkpoint_on_collision": bool(flags & 0x4000),
                           "save_world_state_on_entry": bool(flags & 0x100),
                           "remove_actor_on_entry": bool(flags & 0x200),
                           "reset_visual_phase_on_entry": bool(flags & 1),
                           "reset_transform_phase_on_entry": bool(flags & 2),
                           "animate_transform": bool(flags & 4),
                           "reverse_transform": bool(flags & 0x40),
                           "reverse_visual": bool(flags & 0x80),
                           "stop_previous_sound_sequence": bool(flags & 0x400),
                           "suppress_sound_sequence_repeat": bool(flags & 0x800),
                           "randomize_sound_pitch": bool(flags & 0x1000),
                           "remember_removed_on_scope_unload": bool(flags & 0x2000),
                           "physics_mask": flags & 0x18,
                           "sound_sequence": self.sound_sequence(record, at + 0x24),
                           "transitions": transitions,
                           "entry_events": [self.event(record, events_at + n * 16) for n in range(events_count)],
                           "raw_u32": raw})
        return {"source_field_offset": 0xAC, "states": states,
                "initial_state": 0, "initial_health_base": reader.unpack("<i", 0x14)[0],
                "initial_visual_phase": initial_phases[0] * .01,
                "initial_transform_phase": initial_phases[1] * .01,
                "health_adds_difficulty_index": True,
                "difficulty_controller": self.ref_field(record, 0x25C),
                "damage_event": 0x22000003 if reader.u32(0x260) else 0x22000012,
                "persistent_checkpoint_item": bool(reader.u32(0x264)),
                "contact_death_visual": death_visual,
                "contact_sound_sequence": self.sound_sequence(record, 0x248),
                "checkpoint_states": [s["index"] for s in states if s["checkpoint_on_collision"]],
                "meaning_confidence": "native_state_table_and_dispatch_verified",
                "checkpoint_snapshot_fields": ["persistent_activation_flag"]
                    if reader.u32(0x264) else [],
                "unresolved": ["unlisted state flags", "full native motion/collision integration"]}

    def owner(self, record: Record) -> dict:
        name, role, ctor = NATIVE_CLASSES[record.kind]
        out = {"id": stable_id(record), "type": record.kind, "native_class": name, "role": role,
               "source": self.source(record), "evidence": {"factory_va": "0x0040b200", "constructor_va": f"0x{ctor:08x}"},
               "meaning_confidence": "native_factory_rtti_verified"}
        reader = Reader(record.data, record.label)
        pose = self.pose(record, TRANSFORM_FIELDS[record.kind]) if record.kind in TRANSFORM_FIELDS else None
        if pose:
            out["transform"] = pose
            out["position"] = pose["position"]
        if record.kind in BOX_FIELDS:
            out["bounds"] = self.box(record, BOX_FIELDS[record.kind], pose)
        if record.kind == 10000:
            out["health_bar"] = self.ref_field(record, 0x1E4)
            out["movement"] = decode_player_configuration(record)
            out["spawn_verified_by"] = ["0x0040223c", "0x00402245", "0x0040224f", "0x00402273"]
        elif record.kind == 10101:
            out.update(camera_resource=self.ref_field(record, 0x14), target=self.ref_field(record, 0x24),
                       alternate_path=self.pose(record, 0x28))
            camera = out["camera_resource"]
            require(camera is not None and camera["type"] == 2000, f"{record.label}: expected CCameraVisual")
            camera_record = self.catalog.record(camera["group"], camera["record"])
            fov, far = _finite(Reader(camera_record.data, camera_record.label).unpack("<2f", 4), camera_record.label)
            require(0 < fov < .5 and far > 0, f"{camera_record.label}: invalid projection settings")
            out["projection"] = {"horizontal_fov_turns": fov, "horizontal_fov_degrees": fov * 360,
                                 "requested_distance_source_units": far, "requested_distance": far * .01,
                                 "near": .3, "far": max(50000, far) * .01,
                                 "source_field_offsets": {"fov": 4, "distance": 8},
                                 "meaning_confidence": "native_d3d_projection_verified",
                                 "evidence_va": ["0x004138f0", "0x00413c70", "0x00413978", "0x0040ffd0"]}
        elif record.kind == 10301:
            diamonds, lives, heal, inactive = reader.unpack("<hhHH", 0x10)
            out["pickup"] = {"diamonds": diamonds, "lives": lives, "health": bool(heal),
                             "health_field_raw": heal, "starts_inactive": bool(inactive),
                             "activation_event": 0x22000002, "collection_delay_seconds": .6,
                             "idle_action": 0, "idle_period_seconds": 2.0,
                             "collected_action": 1, "collection_disables_collision_immediately": True,
                             "award_after_collected_action": True,
                             "activation_copies_full_sender_pose": True,
                             "healing_by_difficulty": [20, 10, 5], "lives_cap": 20,
                             "source_field_offsets": {"diamonds": 0x10, "lives": 0x12, "health": 0x14, "inactive": 0x16},
                             "meaning_confidence": "native_pickup_to_healthbar_handlers_verified"}
            out["collection_sound"] = self.sound_ref(record, 0x64)
        elif record.kind == 10300:
            out["state_machine"] = self.state_actor(record)
        elif record.kind == 10200:
            out["events"] = {name: self.event(record, off, True)
                             for name, off in [("on_enter", 0x5C), ("on_exit", 0x70), ("on_stay", 0x84)]}
            out["contact_damage"] = reader.unpack("<i", 0xA8)[0]
            out["native_collider_selector"] = reader.u32(0xA4)
            out["collision_masks"] = list(reader.unpack("<2I", 0x98))
        elif record.kind == 10203:
            offset, count = self.packed_array(record, 0x60, 4)
            events = []
            for n in range(count):
                target = self.reference(record.group, reader.u32(offset + n * 4))
                if target:
                    event = self.event(target, 0, True)
                    event["descriptor_record"] = stable_id(target)
                    events.append(event)
            out.update(events=events, once=True, collision_masks=list(reader.unpack("<2I", 0x24)))
        elif record.kind == 10204:
            out.update(damage=1000, event=0x22000003, collision_masks=list(reader.unpack("<2I", 0x28)),
                       evidence_handler_va="0x00406200")
        elif record.kind == 10602:
            out.update(target=self.ref_field(record, 0x5C), event=0x22000040,
                       once=True, requires_all_diamonds=False, evidence_handler_va="0x00405d60")
        elif record.kind == 10403:
            offset = _finite(reader.unpack("<3f", 0x18), record.label)
            out.update(mesh=self.ref_field(record, 8), camera_centered=True,
                       rotate_offset_with_camera_yaw=bool(reader.u32(0x10)),
                       source_offset=offset, offset=godot_position(offset),
                       requested_distance_source_units=reader.unpack("<f", 0x14)[0],
                       physics_role="none", evidence_handler_va="0x00405720")
        elif record.kind in (10500, 10501):
            out.update(decode_speaker(record, self))
        elif record.kind in (10400, 10401, 10402):
            out["mesh"] = self.ref_field(record, 0xC)
            out["physics_role"] = {10400: "native_mesh_quadtree", 10401: "none", 10402: "explicit_moving_collider"}[record.kind]
            timing = _finite(reader.unpack("<f", 0x14) + reader.unpack("<f", 0x20)
                             + reader.unpack("<f", 0x28) + reader.unpack("<f", 0x34), record.label)
            out["motion"] = {"visual_period_seconds": timing[0], "visual_initial_phase": timing[1],
                             "transform_period_seconds": timing[2], "transform_initial_phase": timing[3],
                             "wrap": True, "evidence_va": ["0x00406b7d", "0x00406b8a", "0x00406ba4"],
                             "source_field_offsets": {"visual_period": 0x14, "visual_phase": 0x20,
                                                      "transform_period": 0x28, "transform_phase": 0x34}}
            if record.kind == 10400:
                surfaces = []
                for index in range(20):
                    at = 0x9C + index * 52
                    values = _finite(reader.unpack("<5f", at), record.label)
                    effect = reader.u32(at + 0x14)
                    require(not effect or record.header_size <= effect < len(record.data),
                            f"{record.label}: surface effect points outside variable data")
                    surfaces.append({"surface_type": index, "source_field_offset": at,
                                     "source_vector_raw": values[:3], "ground_damage": values[3],
                                     "movement_response_coefficient": values[4],
                                     "death_visual_offset": effect or None,
                                     "movement_constraint_raw": reader.u32(at + 0x18),
                                     "prevent_standing_from_crouch": bool(reader.u32(at + 0x18)),
                                     "raw_u32": list(reader.unpack("<13I", at)),
                                     "meaning_confidence": "native_material_table_and_ground_damage_verified"})
                out["surface_data"] = surfaces
                out["surface_evidence_va"] = ["0x00416680", "0x0041a888", "0x00403008", "0x004049ea",
                                              "0x004035c4", "0x0040374e"]
            if record.kind == 10402:
                out["native_collider_selector"] = reader.u32(0x9C)
                out["motion_parameters_raw"] = list(reader.unpack("<10I", 0x10))
        return out

    def health_bar(self, record: Record) -> dict:
        reader = Reader(record.data, record.label)
        return {"id": stable_id(record), "source": self.source(record),
                "native_class": "CHealthBar", "constructor_va": "0x004288c0",
                "lives_raw": reader.u32(0x70), "health_raw": reader.u32(0x74),
                "maximum_health_raw": reader.u32(0x78), "diamonds_initial": reader.u32(0x7C),
                "diamonds_total_native": reader.u32(0x80),
                "bonus_total_raw": reader.u32(0x84), "bonus_initial_raw": reader.u32(0x88),
                "source_field_offsets": {"lives": 0x70, "health": 0x74, "maximum_health": 0x78,
                                         "diamonds": 0x7C, "diamonds_total": 0x80},
                "note": "Raw record defaults; controller initialization may replace health/lives by difficulty or saved status."}


def recover_gameplay(catalog: Catalog) -> dict:
    """Return source-backed level data. No original executable is needed or run."""
    decoder = GameplayDecoder(catalog)
    levels = {}
    music = {}
    for scene in catalog.scenes.values():
        tracks = [r for r in scene.records if r.kind == 1101]
        require(len(tracks) <= 1, f"Group {scene.group}: multiple CDDA music controllers")
        if tracks:
            record = tracks[0]
            track = Reader(record.data, record.label).bytes(0x1C, 1)[0]
            require(2 <= track <= 99, f"{record.label}: unsupported CDDA track")
            music[f"g{scene.group:03d}"] = {
                "track": track, "id": stable_id(record), "source_field_offset": 0x1C,
                "source": decoder.source(record), "native_class": "CSQMidiFile",
                "meaning_confidence": "mci_cdaudio_play_from_track_to_next_verified",
                "evidence_va": ["0x0042c7fd", "0x0042c83d", "0x0042c846", "0x0042c86d"]}
    for descriptor in catalog.descriptors:
        main = catalog.scenes[descriptor["group"]]
        players = [r for r in main.records if r.kind == 10000]
        if not players:
            continue
        require(len(players) == 1, f"Group {main.group}: expected one Hugo player")
        groups = list(range(main.group, main.group + len(main.child_sizes) + 1))
        owners = {stable_id(r): decoder.owner(r) for group in groups for r in catalog.scenes[group].records
                  if r.kind in NATIVE_CLASSES}
        player = owners[stable_id(players[0])]
        cameras = [v for v in owners.values() if v["role"] == "camera"]
        health_bars = [r for r in main.records if r.kind == 6017]
        require(len(cameras) == 1 and len(health_bars) == 1,
                f"Group {main.group}: expected native camera and health bar")
        pickups = [v["id"] for v in owners.values() if v["role"] == "pickup"]
        checkpoints = [v["id"] for v in owners.values()
                       if v.get("state_machine", {}).get("checkpoint_states")]
        levels[f"g{main.group:03d}"] = {
            "id": f"g{main.group:03d}", "source_name": descriptor["name"], "order": len(levels) + 1,
            "main_group": main.group, "groups": groups, "native_player": player,
            "spawn": player["transform"], "camera": cameras[0], "music": music.get(f"g{main.group:03d}"),
            "health_bar": decoder.health_bar(health_bars[0]), "owners": owners,
            "pickups": pickups, "checkpoints": checkpoints,
            "exits": [v["id"] for v in owners.values() if v["role"] == "exit"],
            "triggers": [v["id"] for v in owners.values() if v["role"].endswith("trigger")],
            "actors": [v["id"] for v in owners.values() if v["role"] == "state_actor"],
            "counts": dict(sorted(Counter(v["role"] for v in owners.values()).items())),
            "diamonds_in_records": sum(owners[k]["pickup"]["diamonds"] for k in pickups),
            "initially_active_diamonds": sum(owners[k]["pickup"]["diamonds"] for k in pickups
                                            if not owners[k]["pickup"]["starts_inactive"]),
        }
    audio = {}
    for (group, resource), chunk in sorted(decoder.audio_chunks.items()):
        fmt = catalog.container.audio[chunk.index]
        key = f"g{group:03d}_r{resource:04d}"
        audio[key] = {"group": group, "resource_id": resource, "path": f"audio/{key}.wav",
                      "source_offset": chunk.offset, "sha256": chunk.sha256, **fmt,
                      "duration_seconds": fmt["frames"] / fmt["sample_rate"]}
    sounds = {stable_id(r): decoder.sound(r) for s in catalog.scenes.values() for r in s.records if r.kind == 1000}
    event_counts = Counter()
    for level in levels.values():
        for owner in level["owners"].values():
            events = owner.get("events", [])
            events = list(events.values()) if isinstance(events, dict) else list(events)
            for state in owner.get("state_machine", {}).get("states", []):
                events.extend(state["entry_events"])
            for event in events:
                if event["event"]:
                    event_counts[(event["event"], event["target"] is not None)] += 1
    return {"schema_version": 1, "source_sha256": catalog.container.summary["input_sha256"],
            "static_evidence_exe_sha256": EXE_SHA256,
            "coordinate_conversion": "Godot=(source.x,source.z,-source.y)*0.01; source poses are not recentered",
            "levels": levels, "scene_music": music, "audio": audio, "sounds": sounds,
            "native_rules": {"default_difficulty_index": 1, "starting_total_lives": 4,
                             "lives_hud_shows_reserves": True, "life_cap": 20,
                             "maximum_health_base_by_difficulty": [11, 10, 8],
                             "health_bonus_per_qualified_level": 1,
                             "health_bonus_diamond_percent_threshold": 90,
                             "health_bonus_eligible_level_indices": list(range(7)),
                             "health_bonus_awarded_only_if_not_already_qualified": True,
                             "all_checkpoints_finish_life_bonus": 1,
                             "checkpoint_finish_bonus_comparison": "collected == total",
                             "healing_by_difficulty": [20, 10, 5],
                             "ordinary_damage_adds_difficulty_index": True,
                             "alternate_damage_adds_difficulty_index": False,
                             "player_attack_damage": 1, "player_damage_invulnerability_seconds": 2.0,
                             "force_death_damage_threshold": 1000,
                             "nonpositive_visual_period_freezes_time_driven_phase": True,
                             "path_phase_requires_state_flag": 4,
                             "evidence_va": ["0x004169a1", "0x004169ab", "0x00416eb0", "0x00427adf",
                                             "0x00427ec7", "0x00429103", "0x004031ed", "0x0040274b", "0x004087a8"]},
            "checkpoint_protocol": {
                "initial_snapshot_after_scene_load": True,
                "removed_ids_restored_from_checkpoint": True,
                "child_segments_recreated_from_source": True,
                "player_snapshot": ["checkpoint_position", "previous_position", "yaw"],
                "camera_snapshot": ["track_phase", "world_pose"],
                "healthbar_restores": ["diamonds"],
                "health_after_death_restore": "maximum_health",
                "lives_after_death_restore": "current_lives_after_decrement",
                "state_actor_snapshot": "four-byte activation flag only when record+0x264 is nonzero",
                "state_actor_restore": "remove if saved activation flag; otherwise state0 entry, then authored initial phases",
                "pickup_snapshot": "no per-pickup handler; removed-ID snapshot plus source segment reload",
                "not_snapshotted_by_state_actor": ["health", "state_index", "elapsed", "visual_phase", "path_phase", "pose"],
                "evidence_va": ["0x0041ba92", "0x0041c076", "0x0042da69", "0x00407eff", "0x00407f2b",
                                "0x004084a6", "0x0040297e", "0x0040a735", "0x00428d00", "0x00429037"]},
            "logic_collision_protocol": {
                "node_category_offset": 20, "node_receive_mask_offset": 24,
                "delivery_condition": "receiver.mask_b & other.mask_a != 0",
                "payload": ["receiver_collider", "other_actor", "other_collider"],
                "sender": "other_actor",
                "state_transition_mask_2_compares": "receiver collider mask_a & transition.argument",
                "state_contact_damage_requires_category_bit": 8,
                "player_attack_requires_category_bit": 2,
                "player_body_masks": [0x1001, 8], "player_attack_masks": [2, 4],
                "damage_deduplication_key": "damage payload+0x10; one monotonically incremented ID per accepted Hugo attack",
                "evidence_va": ["0x00415f4d", "0x00415f8c", "0x0041ca31", "0x0041ca5a",
                                "0x0041ca98", "0x00408c0e", "0x00408d8d", "0x004031ed", "0x0040350a"]},
            "event_coverage": {
                "source_authored_dispatch": [{"event": event, "event_hex": f"0x{event:08x}",
                    "has_target": has_target, "count": count, "decoded": event in EVENT_NAMES}
                    for (event, has_target), count in sorted(event_counts.items())],
                "unrecognized_source_events": [f"0x{e:08x}" for e in sorted({e for e, _ in event_counts if e not in EVENT_NAMES})],
                "source_scope": "all entry notifications, ActorTrigger and NotifyTrigger descriptors in eight gameplay levels"},
            "event_protocol": {f"0x{k:08x}": v for k, v in EVENT_NAMES.items()},
            "limitations": ["Native state flags not named here are preserved without inferred semantics.",
                            "Collision meshes must use the native section, not all visible triangles.",
                            "Initial poses alone do not reproduce animated paths.",
                            "Class CSimpleStateActor does not imply an enemy.",
                            "Native expected diamond total differs from record sum in DiamondMines (85 versus 86); both are retained."]}


def export_gameplay(catalog: Catalog, output: Path | str) -> dict:
    """Write gameplay_manifest.json and unmodified original PCM WAV resources."""
    directory = Path(output)
    directory.mkdir(parents=True, exist_ok=True)
    result = recover_gameplay(catalog)
    (directory / "audio").mkdir(exist_ok=True)
    for chunk in catalog.container.chunks:
        if chunk.kind == 5:
            path = directory / f"audio/g{chunk.group:03d}_r{chunk.resource_id:04d}.wav"
            path.write_bytes(catalog.container.payload(chunk))
    write_json(directory / "gameplay_manifest.json", result)
    return result
