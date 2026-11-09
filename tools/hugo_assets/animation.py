"""Recover Hugo's native morph timelines and transform/action tracks.

The original executable is never loaded or executed. Function addresses document
the static disassembly used to recover interpolation and state selection. Scene
records, including compressed rotation words, remain the authority for each key.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from .binary import Reader, require
from .catalog import Catalog, Record
from .gltf import SOURCE_UNIT_SCALE, export_glb, scene_axes, verify_glb
from .mesh import Mesh, Selection, parse_mesh
from .scene_graph import SceneIndex, SourceTransform, TRANSFORM_KINDS, parse_graph, parse_transform


NATIVE_TIMER_HZ = 300
EXE_SHA256 = "bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3"
TAU_F32 = float(np.float32(2.0 * math.pi))
AXES = np.array(((1., 0., 0.), (0., 0., 1.), (0., -1., 0.)))
HUGO_SHADOW_HEIGHT_SCALE_SOURCE = float(np.float32(0.0045))

# These are action IDs passed by RTTI-identified CHugoState* implementations to
# CHugoMainActor::SetAction at 0x403390, not names inferred from frame counts.
ACTION_NAMES = (
    "idle", "idle_variation", "attack", "crouch", "land", "crouch_transition",
    "walk", "run", "crawl", "jump", "jump_moving", "fall", "hurt", "death",
)
ACTION_EVIDENCE = (
    "CHugoStateIdle entry 0x4043EC and update 0x4042FB select 0",
    "CHugoStateIdle update 0x40430F selects 1 as an alternate idle action",
    "shared input handler 0x403508..0x403514 selects 2 on input mask 0x8000",
    "CHugoStateCrawl 0x4037BE..0x4037CB selects stationary action 3",
    "CHugoStateFall 0x403F6C..0x403F75 selects action 4 during landing",
    "CHugoStateCrawl 0x4037D6..0x403851 selects 5 and advances it in either direction",
    "CHugoStateRun 0x404AF3..0x404B06 selects 6 below the movement threshold",
    "CHugoStateRun 0x404AF3..0x404B06 selects 7 above the movement threshold",
    "CHugoStateCrawl 0x403790..0x40379A selects moving action 8",
    "CHugoStateJump entry 0x4048DE..0x404901 chooses 9 when movement amount actor+0x298 is below 0.5",
    "CHugoStateJump entry 0x4048DE..0x404901 chooses 10 when movement amount actor+0x298 is at least 0.5",
    "CHugoStateFall 0x403F15..0x403F1F selects action 11",
    "CHugoStateDamage entry 0x403AD6 stores 12; update 0x403A0D..0x403A11 selects it",
    "CHugoStateDeath entry 0x403C1D..0x403C1F selects action 13",
)


@dataclass(frozen=True)
class TimelineKey:
    sample: int
    fraction_q12: int

    @property
    def fraction(self) -> float:
        return self.fraction_q12 / 4096.0


def decode_timeline(words: tuple[int, ...] | list[int], sample_count: int,
                    loop: bool) -> tuple[TimelineKey, ...]:
    require(sample_count > 0 and len(words) > 0, "Animation timeline must contain samples and keys")
    keys = []
    for word in words:
        require(0 <= word <= 0xffffffff and word & 0xf000 == 0,
                "Unsupported native timeline reserved bits")
        key = TimelineKey(word >> 16, word & 4095)
        require(key.sample < sample_count, "Native timeline references a missing vertex sample")
        require(loop or key.sample + 1 < sample_count or key.fraction_q12 == 0,
                "A non-looping timeline interpolates beyond its final sample")
        keys.append(key)
    return tuple(keys)


def _phase_indices(count: int, loop: bool, phase: float) -> tuple[int, int, float]:
    require(count > 0 and math.isfinite(phase), "Invalid animation sample count/phase")
    if count == 1:
        return 0, 0, 0.0
    phase = phase % 1.0 if loop else min(max(phase, 0.0), 1.0)
    coordinate = phase * (count if loop else count - 1)
    first = min(int(coordinate), count - 1)
    second = (first + 1) % count if loop else min(first + 1, count - 1)
    return first, second, coordinate - int(coordinate)


def sample_timeline(words: tuple[int, ...] | list[int], sample_count: int,
                    loop: bool, phase: float) -> tuple[int, int, float]:
    """Return the native two vertex samples and their interpolation weight.

    C3DPSXMesh::render at 0x4142D5..0x4143B9 interpolates the Q12 timeline
    coordinates first, including the last-to-first wrap, then blends vertices.
    A timeline slot is not a 300-Hz timer tick and is not a fixed-rate frame.
    """
    keys = decode_timeline(words, sample_count, loop)
    a, b, fraction = _phase_indices(len(keys), loop, phase)
    first, second = keys[a], keys[b]
    difference = second.sample + second.fraction - first.sample - first.fraction
    if difference < 0.0:
        difference += sample_count
    alpha = first.fraction + fraction * difference
    require(-1e-6 <= alpha <= 1.000001, "Native timeline skips an unsupported vertex interval")
    return first.sample, (first.sample + 1) % sample_count, alpha


def decode_rotation_words(quaternion_word: int, interpolation_word: int) -> dict:
    """Exact signed-byte quaternion and packed slerp constants (0x42F730).

    XYZW occupy the first word's most-to-least significant bytes, each /128.
    The second word is angle in turns /2048, signed cosine /1024, reciprocal
    sine /128. A zero reciprocal selects linear interpolation in 0x42FCF0.
    """
    require(0 <= quaternion_word <= 0xffffffff and 0 <= interpolation_word <= 0xffffffff,
            "Compressed quaternion words are not uint32")
    signed = lambda value, bits: value - (1 << bits) if value & (1 << (bits - 1)) else value
    q = [signed((quaternion_word >> shift) & 255, 8) / 128.0 for shift in (24, 16, 8, 0)]
    return dict(quaternion=q, angle_turns=(interpolation_word & 1023) / 2048.0,
                cosine=signed((interpolation_word >> 10) & 2047, 11) / 1024.0,
                reciprocal_sine=((interpolation_word >> 21) & 2047) / 128.0,
                raw_words=[quaternion_word, interpolation_word])


def quaternion_matrix(q: np.ndarray | list[float]) -> np.ndarray:
    """Original 0x40BAD0 convention, preserving its quantization (no renormalize)."""
    x, y, z, w = q
    return np.array(((1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w),
                     (2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w),
                     (2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y)))


def sample_rotation(keys: tuple[dict, ...] | list[dict], loop: bool, phase: float) -> np.ndarray:
    a, b, alpha = _phase_indices(len(keys), loop, phase)
    first, second = keys[a], keys[b]
    q0, q1 = np.asarray(first["quaternion"]), np.asarray(second["quaternion"])
    if a == b:
        return quaternion_matrix(q0)
    cosine = first["cosine"]
    if cosine < 0.0:
        q1 = -q1
        cosine = -cosine
    if first["reciprocal_sine"] == 0.0:
        q = q0 * (1.0 - alpha) + q1 * alpha
    else:
        angle = alpha * first["angle_turns"] * TAU_F32
        weight1 = math.sin(angle) * first["reciprocal_sine"]
        weight0 = math.cos(angle) - cosine * weight1
        q = q0 * weight0 + q1 * weight1
    return quaternion_matrix(q)


def sample_translation(keys: np.ndarray, loop: bool, phase: float) -> np.ndarray:
    """Native cubic Hermite with centered/one-sided tangents (0x40C850/0x40D250)."""
    a, b, t = _phase_indices(len(keys), loop, phase)
    if a == b:
        return keys[a].copy()

    def tangent(index: int) -> np.ndarray:
        if loop:
            return (keys[(index + 1) % len(keys)] - keys[(index - 1) % len(keys)]) * 0.5
        if index == 0:
            return keys[1] - keys[0]
        if index == len(keys) - 1:
            return keys[-1] - keys[-2]
        return (keys[index + 1] - keys[index - 1]) * 0.5

    t2, t3 = t*t, t*t*t
    return ((2*t3 - 3*t2 + 1)*keys[a] + (t3 - 2*t2 + t)*tangent(a)
            + (-2*t3 + 3*t2)*keys[b] + (t3 - t2)*tangent(b))


def nearest_path_phase(keys: np.ndarray, loop: bool, point: np.ndarray,
                       previous_phase: float = 0.0) -> float:
    """CSnapTracker's native phase search (0x417150/0x417190 → 0x40CE60).

    This is a tangent-plane search, not Euclidean closest-point fitting to the
    Hermite spline. The previous phase chooses the local branch; ten binary
    refinements interpolate endpoint positions and their normalized tangents.
    An iteration bound is added for malformed/degenerate cyclic paths.
    """
    count = len(keys)
    require(count > 0 and bool(np.isfinite(keys).all()) and bool(np.isfinite(point).all())
            and math.isfinite(previous_phase), "Invalid camera path input")
    if count == 1:
        return 0.0
    intervals = count if loop else count - 1

    def tangent(index: int) -> np.ndarray:
        before = (index - 1) % count if loop else max(0, index - 1)
        after = (index + 1) % count if loop else min(count - 1, index + 1)
        value = keys[after] - keys[before]
        length = float(np.linalg.norm(value))
        return value / length if length > 1e-12 else np.zeros(3)

    def projection(index: int) -> float:
        return float(tangent(index) @ (point - keys[index]))

    seed = previous_phase % 1.0 if loop else min(max(previous_phase, 0.0), 1.0)
    index = min(int(seed * intervals), count - 1)
    forward = projection(index) > 0.0
    for _ in range(count + 1):
        index += 1 if forward else -1
        if not loop and index >= count:
            return 1.0
        if not loop and index < 0:
            return 0.0
        index %= count
        signed = projection(index)
        if (forward and signed <= 0.0) or (not forward and signed > 0.0):
            if forward:
                index = (index - 1) % count
            break
    else:
        return seed
    following = (index + 1) % count if loop else min(index + 1, count - 1)
    first_tangent, next_tangent = tangent(index), tangent(following)
    fraction, step = 0.5, 0.25
    for _ in range(10):
        direction = first_tangent + (next_tangent - first_tangent) * fraction
        position = keys[index] + (keys[following] - keys[index]) * fraction
        fraction += step if float(direction @ (point - position)) > 0.0 else -step
        step *= 0.5
    return (index + fraction) / intervals


@dataclass(frozen=True)
class TransformTrack:
    group: int
    record: int
    kind: int
    initial: SourceTransform
    translations: np.ndarray
    translation_loop: bool
    rotations: tuple[dict, ...]
    rotation_loop: bool
    raw_sha256: str

    def sample(self, phase: float) -> SourceTransform:
        position = (sample_translation(self.translations, self.translation_loop, phase)
                    if len(self.translations) else self.initial.translation)
        matrix = (sample_rotation(self.rotations, self.rotation_loop, phase)
                  if self.rotations else self.initial.matrix)
        return SourceTransform(position, matrix)

    def manifest(self) -> dict:
        return dict(group=self.group, record=self.record, type=self.kind,
                    initial_translation=self.initial.translation.tolist(),
                    initial_basis=self.initial.matrix.tolist(),
                    translation_keys=self.translations.tolist(), translation_loop=self.translation_loop,
                    rotation_keys=list(self.rotations), rotation_loop=self.rotation_loop,
                    source_sha256=self.raw_sha256)


def parse_transform_track(record: Record) -> TransformTrack:
    r = Reader(record.data, record.label)
    initial = parse_transform(record)
    positions = np.empty((0, 3), dtype=np.float64)
    rotations: tuple[dict, ...] = ()
    translation_loop = rotation_loop = False
    if record.kind != 3000:
        require(r.u32(52) == 0x07070707, f"{r.label}: invalid transform animation marker")
        fields = ((56, 8, "rotation"), (64, 12, "translation")) if record.kind == 3003 else (
            (56, 12 if record.kind == 3001 else 8, "translation" if record.kind == 3001 else "rotation"),)
        minimum = {3001: 68, 3002: 64, 3003: 76}[record.kind]
        for at, stride, field in fields:
            count, flags, pointer = r.unpack("<HHI", at)
            require(count > 0 and flags in (0, 1) and pointer >= minimum and pointer % 4 == 0,
                    f"{r.label}: unsupported {field} sample header")
            raw = r.bytes(pointer, count * stride, field + " samples")
            if field == "translation":
                positions = np.frombuffer(raw, dtype="<f4").astype(np.float64).reshape(count, 3)
                require(bool(np.isfinite(positions).all()), f"{r.label}: non-finite translation keys")
                translation_loop = bool(flags & 1)
            else:
                pairs = np.frombuffer(raw, dtype="<u4").reshape(count, 2)
                rotations = tuple(decode_rotation_words(int(a), int(b)) for a, b in pairs)
                rotation_loop = bool(flags & 1)
    return TransformTrack(record.group, record.index, record.kind, initial, positions,
                          translation_loop, rotations, rotation_loop,
                          hashlib.sha256(record.data).hexdigest())


def _binding_manifest() -> dict:
    return {name: dict(clip=f"action_{i:02d}", confidence="static_executable",
                       evidence=ACTION_EVIDENCE[i]) for i, name in enumerate(ACTION_NAMES)}


def export_hugo_shadow(catalog: Catalog, output: Path, owner: Record) -> dict:
    """Export the independently rendered, constant-phase ground-shadow graph.

    CHugoMainActor keeps record+0x0C at runtime+0x0C (0x401BEA..0x401BFD).
    Unlike the primary graph it never receives the action ticker: graph+0x14
    and graph+0x18 remain source state 0 and phase 0. The render path projects
    the actor pose onto cached floor Z and scales its entire basis by height.
    Local static node transforms are baked once; actor pose belongs to runtime.
    """
    require(owner.kind == 10000, f"{owner.label}: shadow requires a Hugo owner")
    index = SceneIndex(catalog)
    reader = Reader(owner.data, owner.label)
    graph = parse_graph(owner, reader.u32(12))
    require(len(graph.states) == 1 and graph.node_count == 1,
            f"{owner.label}: unsupported Hugo shadow graph; expected one state and node")
    node = graph.states[0].nodes[0]
    transform_record = index.resolve(owner.group, node.transform_ref, (3000,))
    transform = (SourceTransform.identity() if transform_record is None
                 else parse_transform(transform_record))
    target = index.resolve(owner.group, node.renderable_ref, (2001,))
    require(target is not None, f"{owner.label}: shadow has no mesh")
    mesh = parse_mesh(target)
    require(mesh.sample_count == 1 and all(len(part.materials) <= 1
            and len(part.colors) == len(part.uv_bytes) == 1 for part in mesh.parts),
            f"{owner.label}: animated shadow samples are outside the recovered profile")
    selected = Selection(mesh, "hugo_shadow", transform.translation, transform.matrix,
                         () if transform_record is None else (transform_record.index,))
    data = export_glb(catalog, [selected])
    verification = verify_glb(data)
    relative = "animations/hugo_shadow.glb"
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return dict(
        path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
        role="ground_shadow", source_owner=index.evidence(owner),
        source_owner_sha256=hashlib.sha256(owner.data).hexdigest(),
        source_pointer_field=12, source_graph_offset=graph.offset,
        source_mesh=index.evidence(target), source_mesh_sha256=mesh.raw_sha256,
        source_transform=None if transform_record is None else index.evidence(transform_record),
        source_state_flags=graph.states[0].flags,
        source_state_duration_seconds=graph.states[0].duration,
        action_index=0, native_phase=0.0, phase_policy="constant_zero",
        authored_duration_used_for_playback=False, local_transform_baked=True,
        source_scale=SOURCE_UNIT_SCALE, axes="(x,z,-y)",
        bounds=verification["bounds"], vertices=verification["vertices"],
        triangles=verification["triangles"],
        render_policy=dict(
            native_event="0x22020005", translation="actor_render_xy_and_cached_floor_z",
            basis="actor_render_basis_times_height_scale",
            height_scale_equation="1 / (1 + coefficient * (actor_physics_z - floor_z))",
            height_scale_coefficient_source=HUGO_SHADOW_HEIGHT_SCALE_SOURCE,
            height_scale_coefficient_world=HUGO_SHADOW_HEIGHT_SCALE_SOURCE / SOURCE_UNIT_SCALE,
            native_height_clamp=None, native_scale_clamp=None, native_surface_offset=0.0,
            source_actor_z_field=0x4C, source_floor_z_field=0x24C,
            floor_source="actor_collision_cache", raycast_in_render_path=False,
            floor_solver_fully_recovered=False,
            visibility=dict(
                shared_with_primary_visual=True, hide_during_surface_death_replacement=True,
                hide_during_contact_death_replacement=True,
                blink_timer_field=0x370, blink_delta_ticks_field=0x368,
                blink_timer_update="max(0, remaining_ticks - delta_ticks)", blink_mask=0x20,
                blink_hidden_condition="(remaining_ticks & 0x20) != 0 and actor_0x4C4 == 0 and state != 6",
                native_override_field=0x4C4, native_override_meaning="pending_death_after_knockback",
                native_state_field=0x354, native_death_state=6,
                surface_death_graph_field=0x4C8)),
        material_policy="preserve_native_mesh_blend_runtime_adapter",
        executable_evidence=dict(
            sha256=EXE_SHA256, executed=False,
            relocation="0x401BEA..0x401BFD", graph_initialization="0x415AE0..0x415B56",
            constant_phase="source graph+0x18=0; only primary receives phase at 0x402EB0..0x402EBC",
            pose_and_scale="0x402EF8..0x402F63; float32 coefficient at 0x43E444",
            visibility_and_draw="0x402E06..0x402E33 and 0x402F66..0x402F93",
            pending_death="0x40276B..0x402833 and 0x403A49..0x403A88",
            surface_death_replacement="0x402E22..0x402EA2"))


def export_animations(catalog: Catalog, output: Path) -> dict:
    """Write local-source GLB morph targets and their native action manifest.

    Each GLB contains untransformed mesh coordinates. The runtime composes the
    recorded transform chain before applying one fixed idle normalization.
    This deliberately does not add an invented skeleton or glTF frame rate.
    """
    index = SceneIndex(catalog)
    owner = catalog.record(6, 183, 10000)
    graph = parse_graph(owner)
    require(len(graph.states) == 14 and graph.node_count == 8,
            "Unsupported Hugo action profile: expected 14 actions and eight slots")
    animation_dir = output / "animations"
    animation_dir.mkdir(parents=True, exist_ok=True)
    tracks: dict[str, TransformTrack] = {}
    mesh_cache: dict[tuple[int, int], Mesh] = {}
    clips = {}
    action_bindings = _binding_manifest()
    surface_deaths = {}
    contact_deaths = {}
    bind_points = []
    files = {}

    def flatten(current: Record, state_index: int, chain: list[str], prefix: str,
                ancestors: tuple[tuple[int, int], ...], graph_base: int | None = None
                ) -> tuple[list[Selection], list[dict], list[dict]]:
        key = (current.group, current.index)
        require(key not in ancestors and len(ancestors) < 16, "Cyclic or excessively nested animation graph")
        nested = parse_graph(current, graph_base)
        require(0 <= state_index < len(nested.states), "Missing nested action")
        selected, bindings, skipped = [], [], []
        for node in nested.states[state_index].nodes:
            target = index.resolve(current.group, node.renderable_ref)
            if target is None:
                continue
            node_chain = list(chain)
            transform_record = index.resolve(current.group, node.transform_ref, TRANSFORM_KINDS)
            if transform_record is not None:
                track_id = f"g{transform_record.group:03d}_r{transform_record.index:04d}"
                if track_id not in tracks:
                    tracks[track_id] = parse_transform_track(transform_record)
                node_chain.append(track_id)
            name = f"{prefix}_n{node.index:02d}"
            if target.kind == 8003:
                require(len(parse_graph(target).states) == 1,
                        "Nested Hugo owner has multiple actions; selection is not decoded")
                children, child_bindings, child_skipped = flatten(target, 0, node_chain, name, ancestors + (key,))
                selected.extend(children)
                bindings.extend(child_bindings)
                skipped.extend(child_skipped)
            elif target.kind == 2001:
                mesh_key = (target.group, target.index)
                if mesh_key not in mesh_cache:
                    mesh_cache[mesh_key] = parse_mesh(target)
                mesh = mesh_cache[mesh_key]
                decode_timeline(mesh.timeline_words, mesh.sample_count, bool(mesh.animation_flags & 1))
                selected.append(Selection(mesh, name, np.zeros(3), np.eye(3),
                                          tuple(tracks[track].record for track in node_chain)))
                bindings.append(dict(node=name, group=target.group, record=target.index,
                                     transform_chain=node_chain, stored_samples=mesh.sample_count,
                                     timeline_words=list(mesh.timeline_words),
                                     timeline_loop=bool(mesh.animation_flags & 1),
                                     timeline_count=len(mesh.timeline_words),
                                     source_sha256=mesh.raw_sha256))
            else:
                skipped.append(dict(group=target.group, record=target.index, type=target.kind,
                                    node_offset=node.offset,
                                    reason="handled by level effect system" if target.kind == 7500
                                    else "unsupported non-mesh renderable"))
        return selected, bindings, skipped

    for state in graph.states:
        clip_id = f"action_{state.index:02d}"
        selected, nodes, skipped = flatten(owner, state.index, [], clip_id, ())
        require(bool(selected), f"Hugo {clip_id} has no mesh nodes")
        data = export_glb(catalog, selected, include_samples=True)
        verify_glb(data)
        relative = f"animations/{clip_id}.glb"
        (output / relative).write_bytes(data)
        files[relative] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        movement_distance = float(np.linalg.norm(state.vector)) * SOURCE_UNIT_SCALE
        clips[clip_id] = dict(action_index=state.index, semantic=ACTION_NAMES[state.index],
                             path=relative, flags=state.flags,
                             source_descriptor_offset=state.offset,
                             authored_duration_seconds=state.duration,
                             authored_duration_timer_ticks=state.duration * NATIVE_TIMER_HZ,
                             phase_domain="distance" if state.flags & 1 else "seconds",
                             cycle_distance=movement_distance if state.flags & 1 else None,
                             source_motion_vector=state.vector.tolist(),
                             loop=state.index in (0, 3, 6, 7, 8, 11),
                             nodes=nodes, omitted_effects=skipped,
                             evidence=ACTION_EVIDENCE[state.index])
        if state.index == 0:
            for selection, binding in zip(selected, nodes):
                transform = SourceTransform.identity()
                for track_id in binding["transform_chain"]:
                    transform = transform.compose(tracks[track_id].sample(0.0))
                bind_points.extend(scene_axes(transform.points(part.vertices[0])) for part in selection.mesh.parts)

    # Surface +0x14 points to an embedded visual graph, not to the player's
    # secondary/shadow graph. Death entry asks that visual for action-0 duration
    # (0x403C36..0x403C4C), and rendering substitutes it at the actor transform
    # (0x402E2B..0x402E93). Preserve its own authored seconds and pose samples.
    for scene in catalog.scenes.values():
        for segment in scene.records:
            if segment.kind != 10400:
                continue
            reader = Reader(segment.data, segment.label)
            for surface_index in range(20):
                graph_base = reader.u32(0x9C + surface_index * 52 + 0x14)
                if graph_base == 0:
                    continue
                require(segment.header_size <= graph_base < len(segment.data),
                        f"{segment.label}: surface death graph outside variable data")
                profile = f"g{segment.group:03d}_r{segment.index:04d}_o{graph_base:08x}"
                if profile in surface_deaths:
                    surface_deaths[profile]["surface_types"].append(surface_index)
                    continue
                custom_graph = parse_graph(segment, graph_base)
                require(len(custom_graph.states) > 0, f"{segment.label}: empty surface death visual")
                state = custom_graph.states[0]
                clip_id = f"surface_death_{profile}"
                selected, nodes, skipped = flatten(segment, 0, [], clip_id, (), graph_base)
                require(bool(selected), f"{segment.label}: surface death visual contains no mesh")
                data = export_glb(catalog, selected, include_samples=True)
                verify_glb(data)
                relative = f"animations/{clip_id}.glb"
                (output / relative).write_bytes(data)
                files[relative] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                proof = "CHugoStateDeath 0x403C36..0x403C4C action-0 duration; render replacement 0x402E2B..0x402E93"
                clips[clip_id] = dict(action_index=0, semantic=clip_id, profile_role="surface_death",
                                     path=relative, flags=state.flags,
                                     source_owner=index.evidence(segment), source_graph_offset=graph_base,
                                     source_descriptor_offset=state.offset,
                                     authored_duration_seconds=state.duration,
                                     authored_duration_timer_ticks=state.duration * NATIVE_TIMER_HZ,
                                     phase_domain="seconds", cycle_distance=None,
                                     source_motion_vector=state.vector.tolist(), loop=False,
                                     nodes=nodes, omitted_effects=skipped, evidence=proof)
                action_bindings[clip_id] = dict(clip=clip_id, confidence="static_executable", evidence=proof)
                surface_deaths[profile] = dict(action=clip_id, group=segment.group,
                                              record=segment.index, graph_offset=graph_base,
                                              surface_types=[surface_index],
                                              duration_seconds=state.duration)
    # State actors can supply the same player-replacement graph through damage
    # payload+0x14. Their +0x248 object is a sound sequence, not another visual.
    # Keep this profile separate from both ordinary actions and surface deaths.
    for scene in catalog.scenes.values():
        for actor in scene.records:
            if actor.kind != 10300:
                continue
            graph_base = Reader(actor.data, actor.label).u32(0x244)
            if not graph_base:
                continue
            custom_graph = parse_graph(actor, graph_base)
            state = custom_graph.states[0]
            profile = f"g{actor.group:03d}_r{actor.index:04d}_o{graph_base:08x}"
            clip_id = f"contact_death_{profile}"
            selected, nodes, skipped = flatten(actor, 0, [], clip_id, (), graph_base)
            require(bool(selected), f"{actor.label}: contact death visual contains no mesh")
            data = export_glb(catalog, selected, include_samples=True)
            verify_glb(data)
            relative = f"animations/{clip_id}.glb"
            (output / relative).write_bytes(data)
            files[relative] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            proof = ("CSimpleStateActor +0x244 relocation 0x4082A2..0x4082BD; "
                     "damage payload+0x14 0x408C6C..0x408C82; "
                     "CHugoStateDeath action-0 duration 0x403C36..0x403C4C; "
                     "render replacement 0x402E2B..0x402E93")
            clips[clip_id] = dict(action_index=0, semantic=clip_id, profile_role="contact_death",
                                 path=relative, flags=state.flags,
                                 source_owner=index.evidence(actor), source_graph_offset=graph_base,
                                 source_descriptor_offset=state.offset,
                                 authored_duration_seconds=state.duration,
                                 authored_duration_timer_ticks=state.duration * NATIVE_TIMER_HZ,
                                 phase_domain="seconds", cycle_distance=None,
                                 source_motion_vector=state.vector.tolist(), loop=False,
                                 nodes=nodes, omitted_effects=skipped, evidence=proof)
            action_bindings[clip_id] = dict(clip=clip_id, confidence="static_executable", evidence=proof)
            contact_deaths[profile] = dict(action=clip_id, group=actor.group, record=actor.index,
                                          graph_offset=graph_base, source_field_offset=0x244,
                                          duration_seconds=state.duration)
    shadow = export_hugo_shadow(catalog, output, owner)
    files[shadow["path"]] = dict(bytes=shadow["bytes"], sha256=shadow["sha256"])
    all_points = np.concatenate(bind_points)
    lower, upper = all_points.min(axis=0), all_points.max(axis=0)
    manifest = dict(
        schema_version=1, source_owner=index.evidence(owner),
        source_owner_sha256=hashlib.sha256(owner.data).hexdigest(),
        source_scale=SOURCE_UNIT_SCALE, axes="(x,z,-y)",
        bind_bounds=dict(min=lower.tolist(), max=upper.tolist()),
        native_model_height=float(upper[1] - lower[1]),
        timing=dict(native_timer_hz=NATIVE_TIMER_HZ, animation_fps=None,
                    timer_evidence="0x41F88F timeGetTime; 0x41F8B0 ms*0.3; 0x41F8E6 ticks/300",
                    action_phase_evidence="0x403390, 0x416090, 0x4161A0: elapsed seconds or distance divided by period",
                    timeline_evidence="0x414280: normalized phase across native Q12 timeline slots",
                    playback_speed_scale=1.0),
        executable_evidence=dict(sha256=EXE_SHA256, executed=False,
                                 translation="0x40C850 + 0x40D250: cubic Hermite",
                                 rotation="0x42F730 + 0x42FCF0: packed quaternion/slerp",
                                 quaternion_matrix="0x40BAD0"),
        tracks={name: track.manifest() for name, track in tracks.items()},
        clips=clips, bindings=action_bindings, files=files,
        hugo_action_count=len(graph.states), surface_deaths=surface_deaths,
        contact_deaths=contact_deaths, hugo_shadow=shadow,
        fidelity_notes=[
            "Geometry, action IDs, transform keys and interpolation are recovered from local original data and static executable analysis.",
            "300 Hz is the original timer unit, not an animation frame rate. Moving action phase is driven by traveled distance.",
            "Godot still resolves physical contacts. Recovered player movement and gameplay rules are described by separate manifests; the complete original solver/state controller is not claimed.",
            "GLBs contain initial texture/color/UV samples; additional samples and native material timelines are exported separately in material_animation_manifest.json. Non-mesh effects use the level effect system; original dynamic shading is not restored here.",
            "The auxiliary Hugo graph is exported as a separate constant-phase ground shadow with recovered height scaling and shared blink conditions. Native pending-death flags and the damage phase are decoded; the complete legacy support/collision solver is not reproduced.",
            "Actions are selected directly without the original cross-state smoothing controller; crouch transition, alternate idle, jump variant, landing and death remain explicitly addressable.",
        ])
    (output / "animation_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest
