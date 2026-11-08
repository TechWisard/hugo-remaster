"""Source segment residency and camera-progress activation metadata.

This describes the native two-segment loader without emulating CD latency.
Its request and range helpers are small deterministic reference implementations
for the runtime. The evidence and lifecycle boundaries are in docs/scopes.md.
"""
from __future__ import annotations

import math

import numpy as np

from .binary import Reader, require
from .catalog import Catalog, Record
from .scene_graph import SceneIndex, TRANSFORM_KINDS, parse_transform


# CActorClientInfo starts at a class-specific embedded offset. Constructors of
# these classes retain its final two authored int32 words. Other listed actor
# classes explicitly replace their range with 0..1000 during construction.
AUTHORED_RANGE_OFFSETS = {10300: 0xDC, 10301: 0x8C, 10400: 0x90,
                          10401: 0x90, 10402: 0x90}
DEFAULT_RANGE_CLASSES = frozenset((10000, 10101, 10200, 10403,
                                   10500, 10501, 10600, 10602))
RANGE_CONSTRUCTOR_VA = {10300: "0x0040788a", 10301: "0x00406ff2",
                        10400: "0x0040598c", 10401: "0x00406850",
                        10402: "0x004067b0"}
MAX_RESIDENT_SEGMENTS = 2
CAMERA_PROGRESS_MULTIPLIER = 992.0


def _owner_id(record: Record) -> str:
    return f"g{record.group:03d}_o{record.index:04d}_t{record.kind}"


def _axes(vector: np.ndarray, scale: float = 1.0) -> list[float]:
    return [float(vector[0] * scale), float(vector[2] * scale), float(-vector[1] * scale)]


def decode_actor_range(record: Record) -> dict | None:
    """Return the native inclusive camera-progress gate, when this class has one.

    Reversed authored ranges are valid source data and disable the actor at
    every progress value. They must not be silently sorted or repaired.
    Collision-only Notify/Fall triggers have no ActorManager registration.
    """
    r = Reader(record.data, record.label)
    if record.kind in AUTHORED_RANGE_OFFSETS:
        at = AUTHORED_RANGE_OFFSETS[record.kind]
        minimum, maximum = r.unpack("<2i", at, "actor progress range")
        return dict(minimum=minimum, maximum=maximum,
                    never_in_range=minimum > maximum,
                    source="authored_client_info", source_field_offsets=[at, at + 4],
                    constructor_evidence_va=RANGE_CONSTRUCTOR_VA[record.kind])
    if record.kind in DEFAULT_RANGE_CLASSES:
        return dict(minimum=0, maximum=1000, never_in_range=False,
                    source="constructor_default", source_field_offsets=[])
    return None


def native_progress_value(camera_phase: float) -> int:
    """CTargetCam 0x40A8C5..0x40A901, constant float32 at 0x43E6D8."""
    require(math.isfinite(camera_phase), "Camera path phase must be finite")
    return math.trunc(camera_phase * CAMERA_PROGRESS_MULTIPLIER)


def actor_in_range(actor_range: dict, camera_phase: float) -> bool:
    value = native_progress_value(camera_phase)
    return int(actor_range["minimum"]) <= value <= int(actor_range["maximum"])


def choose_neighbor(trigger: dict, camera_position: list[float]) -> int | None:
    """Native 0x407730 plane test; there is deliberately no AABB gate.

    Both vectors use exported Godot axes. The source normal is a matrix column,
    not an inverse-transpose geometric normal, and is not normalized here.
    """
    point = np.asarray(camera_position, dtype=np.float64)
    origin = np.asarray(trigger["origin"], dtype=np.float64)
    normal = np.asarray(trigger["normal"], dtype=np.float64)
    require(all(v.shape == (3,) and bool(np.isfinite(v).all()) for v in (point, origin, normal)),
            "Scope plane requires finite three-component vectors")
    require(float(normal @ normal) > 0, "Scope plane has a zero source axis")
    return trigger["previous_group"] if float((point - origin) @ normal) < 0 else trigger["next_group"]


def plan_scope_request(policy: dict, resident_groups: list[int], requested_group: int) -> dict:
    """Describe a settled request, with unload before load at capacity.

    Native loading/cancellation is asynchronous. This helper returns membership
    after completion; it does not invent the duration of the intervening I/O.
    The native comparison is by absolute container offset, not spatial bounds.
    """
    offsets = {int(s["group"]): int(s["source_container_offset"]) for s in policy["segments"]}
    require(len(resident_groups) == len(set(resident_groups))
            and len(resident_groups) <= MAX_RESIDENT_SEGMENTS,
            "Invalid resident segment set")
    require(requested_group in offsets and all(g in offsets for g in resident_groups),
            "Scope request escapes its main scene")
    current = sorted(resident_groups, key=offsets.__getitem__)
    if requested_group in current:
        return dict(requested_group=requested_group, unload_groups=[], load_groups=[], resident_after=current)
    unload = []
    if len(current) == MAX_RESIDENT_SEGMENTS:
        if offsets[requested_group] < offsets[current[0]]:
            unload = [current[-1]]
        elif offsets[requested_group] > offsets[current[-1]]:
            unload = [current[0]]
        else:
            # 0x42DCF7 would dereference a null candidate here. Source triggers
            # only request adjacent segments and cannot reach this case.
            require(False, "Unsupported interior request between two resident segment offsets")
    after = sorted([g for g in current if g not in unload] + [requested_group], key=offsets.__getitem__)
    return dict(requested_group=requested_group, unload_groups=unload,
                load_groups=[requested_group], resident_after=after)


def decode_scope_policy(catalog: Catalog, main_group: int) -> dict:
    """Validate source child tables and export one main scene's runtime policy."""
    index = SceneIndex(catalog)
    groups = index.groups_for_main(main_group)
    scene = catalog.scenes[main_group]
    chunk = catalog.scene_chunks.get(main_group)
    require(chunk is not None and scene.header_size == 288,
            f"Group {main_group}: unsupported native main-scope header")
    r = Reader(catalog.container.payload(chunk), f"Main scope {main_group}")
    r.check(0, 288, "main-scope header")
    capacity, first_offset, count = r.unpack("<3I", 20)
    require(count == len(scene.child_sizes) and count <= 32,
            f"Group {main_group}: invalid native child table count")
    offsets = r.unpack("<" + "I" * count, 160)
    container_groups = {group.index: group for group in catalog.container.groups}
    require(all(group in container_groups for group in groups),
            f"Group {main_group}: missing native container group")
    require(tuple(offsets) == tuple(container_groups[group].offset for group in groups[1:]),
            f"Group {main_group}: native child offsets disagree with validated group ownership")
    require(first_offset == (offsets[0] if offsets else 0),
            f"Group {main_group}: first native child is inconsistent")
    segments = index.segment_neighbors(main_group)
    payload_sizes = []
    for segment in segments:
        group, ordinal = segment["group"], segment["ordinal"]
        child = catalog.scene_chunks[group]
        declared = r.u32(32 + ordinal * 4)
        require(declared == scene.child_sizes[ordinal]
                and declared == child.payload_size + 16 and child.header_size == 16,
                f"Group {main_group}: native child payload/buffer size is inconsistent")
        payload_sizes.append(child.payload_size)
        segment.update(source_container_offset=container_groups[group].offset,
                       source_serial=group + 1, native_residency_policy_decoded=True,
                       source_payload_size=child.payload_size,
                       buffer_end="start" if ordinal % 2 == 0 else "end",
                       buffer_byte_offset=0 if ordinal % 2 == 0 else capacity - child.payload_size)
    required_capacity = max([0] + payload_sizes + [a + b for a, b in zip(payload_sizes, payload_sizes[1:])])
    require(capacity >= required_capacity, f"Group {main_group}: overlapping native two-segment buffers")
    by_group = {segment["group"]: segment for segment in segments}
    triggers = []
    actor_ranges = {}
    for group in groups:
        for record in catalog.scenes[group].records:
            active_range = decode_actor_range(record)
            if active_range is not None:
                actor_ranges[_owner_id(record)] = dict(active_range, source_group=group,
                                                       source_record=record.index, type=record.kind)
            if record.kind != 10600:
                continue
            rr = Reader(record.data, record.label)
            require(record.header_size == 96 and len(record.data) == 96 and group in by_group,
                    f"{record.label}: unsupported segment-trigger layout or parent scope")
            word = rr.u32(12)
            transform = index.resolve(group, word, TRANSFORM_KINDS)
            require(transform is not None and transform.kind == 3000,
                    f"{record.label}: unsupported animated segment-trigger plane")
            pose = parse_transform(transform)
            axis = pose.matrix[:, 1]
            require(float(axis @ axis) > 0, f"{record.label}: degenerate segment-trigger axis")
            segment = by_group[group]
            triggers.append(dict(id=_owner_id(record), group=group, source_record=record.index,
                                 origin=_axes(pose.translation, .01), normal=_axes(axis),
                                 source_origin=pose.translation.tolist(), source_normal=axis.tolist(),
                                 previous_group=segment["previous_group"], next_group=segment["next_group"],
                                 transform_track=f"g{transform.group:03d}_r{transform.index:04d}",
                                 source_reference=index.evidence(record),
                                 transform_reference=index.evidence(transform),
                                 transform_field_offset=12, source_axis_index=1,
                                 trigger_reference="camera_position", requires_aabb_intersection=False,
                                 update_event=0x22020004,
                                 evidence_va=["0x00407644", "0x00407771", "0x00407786",
                                              "0x004077a9", "0x004077d1", "0x00407834"]))
    return dict(schema_version=1, main_group=main_group, main_scope_serial=main_group + 1,
                persistent_groups=[0, main_group], max_resident_segments=MAX_RESIDENT_SEGMENTS,
                initial_segment_groups=[segments[0]["group"]] if segments else [],
                trigger_reference="camera_position", segments=segments, triggers=triggers,
                source_buffer_capacity=capacity, required_adjacent_payload_capacity=required_capacity,
                source_header_fields=dict(buffer_capacity=20, first_child=24, child_count=28,
                                          child_sizes=32, child_offsets=160),
                residency=dict(request="existing non-unloading scope: no-op; otherwise create category-4 proxy",
                               eviction="new offset below window: unload highest; above window: unload lowest",
                               load_order="finish eviction before starting the pending segment load",
                               activation="resource construction complete then scope activation event",
                               initial_activation="wait for first segment, activate child and main together",
                               render_only_preload=False,
                               reentry="recreate source resources and actors, with native saved actor removals"),
                actor_progress=dict(phase_multiplier=CAMERA_PROGRESS_MULTIPLIER,
                                    rounding="truncate_toward_zero", inclusive_ranges=True,
                                    source="CTargetCam CSnapTracker phase", initial_value=0,
                                    activation_events=[0x22020000, 0x22020002],
                                    deactivation_event=0x22020001,
                                    update_events_by_flag={"1": 0x22020003, "2": 0x22020004,
                                                          "4": 0x22020005},
                                    scope_activate_event=0x22010100,
                                    scope_deactivate_event=0x22010101,
                                    evidence_va=["0x0040a8c5", "0x0040a8d1", "0x0041c3a0",
                                                 "0x0041bc53", "0x0041bd09", "0x0041bdd4"]),
                actor_ranges=actor_ranges,
                checkpoint=dict(save="non_unloading_resident_offsets", max_saved_segments=2,
                                restore="unload_all_then_recreate_saved",
                                suspend_updates_during_restore=True,
                                restore_actor_saved_data_after_resource_construction=True,
                                initial_checkpoint_after_first_segment_activation=True,
                                evidence_va=["0x0041b330", "0x0042da69", "0x0042daf2",
                                             "0x0042d928", "0x0041bf1b"]),
                validation=dict(child_offsets_checked=count, neighbor_links_checked=2 * count,
                                trigger_planes_checked=len(triggers), actor_ranges_checked=len(actor_ranges),
                                authored_never_active_ranges=sum(v["never_in_range"] for v in actor_ranges.values()),
                                no_guessed_spatial_scope_bounds=True),
                evidence_va=["0x0042fb20", "0x0042dd40", "0x0042db70", "0x0042d8db",
                             "0x0042d680", "0x0041b650"],
                fidelity_limits=["Native asynchronous CD/resource-load latency is not inferred from asset bytes.",
                                 "Only validated source adjacency requests are modeled; arbitrary teleport requests need a reload.",
                                 "Scope residency and camera-progress actor gates are separate requirements.",
                                 "Actor-specific checkpoint payloads remain the gameplay decoder/runtime's responsibility."])
