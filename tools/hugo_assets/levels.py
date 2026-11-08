"""Assemble original level geometry from owner records and their scoped handles."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

import numpy as np

from .binary import Reader, require
from .catalog import Catalog, Record
from .gltf import export_glb, native_material_name, scene_axes, verify_glb
from .material_animation import ANIMATION_TOKEN
from .mdic import sha256, write_json
from .mesh import Mesh, Selection, decode_material_flags, parse_mesh
from .scene_graph import (GRAPH_POINTER_FIELDS, TRANSFORM_KINDS, ObjectGraph,
                          SceneIndex, SourceTransform, parse_collision_mesh, parse_graph, parse_transform)


PLAYABLE_MAIN_GROUPS = (6, 17, 27, 36, 46, 55, 59, 69)
WORLD_TRANSFORM_FIELDS = {
    10000: 16, 10101: 28, 10200: 8, 10203: 8, 10204: 8,
    10300: 48, 10301: 12, 10400: 8, 10401: 8, 10402: 8,
    10500: 8, 10501: 8, 10600: 12, 10602: 8,
}
CLASS_NAMES = {
    10000: "Hugo", 10101: "CTargetCam", 10200: "CActorTrigger",
    10203: "CNotifyTrigger", 10204: "CFallTrigger", 10300: "CSimpleStateActor",
    10301: "CPowerUp", 10400: "CDefaultSegment", 10401: "COrnemental",
    10402: "CPlatform", 10403: "CBackmap", 10500: "CSpeaker",
    10501: "CLoudSpeaker", 10600: "CSegmentTrigger", 10602: "CEndOfLevelTrigger",
}
FIDELITY_LIMITS = [
    "Original owner positions, stored affine matrices, mesh topology and first stored vertex samples are exported.",
    "All graph actions and stored morph samples are present; the runtime must select one Action### and sample native tracks.",
    "GLB transforms start at their stored first matrix; native timing is in the level manifest, not baked glTF clips.",
    "Fall-trigger visual graphs are exported under Triggers for inspection and must be hidden until their runtime event.",
    "CEmitter parameters, sprite images and action anchors are decoded; the legacy update-clock frequency and three unused emitter words remain unverified.",
    "The player's auxiliary graph is catalogued but not activated without its runtime condition. Type-2000 is a non-mesh camera visual.",
    "Backmap geometry requires its recovered camera-centered placement policy in the runtime.",
    "Native terrain collision triangles, quadtree and numeric surface IDs are recovered; a Godot physics response still differs from native XY height queries.",
    "Materials retain decoded native blend selectors and vertex alpha; additive and inverse-source-color modes require the runtime adapter because core glTF cannot express them.",
    "Native texture/color/UV samples are exported separately and keyed by source mesh/part; the runtime must sample each instance's visual phase.",
    "Unlit double-sided compatibility materials retain source colors; native culling, lighting and transparent sorting remain incomplete.",
]


@dataclass
class MeshInstance:
    name: str
    owner_id: str
    mesh: Mesh
    local: SourceTransform
    world: SourceTransform
    source_node_offset: int | None
    transform_refs: tuple[dict, ...]
    action_index: int | None = None


@dataclass
class EffectInstance:
    name: str
    owner_id: str
    record: Record
    local: SourceTransform
    world: SourceTransform
    source_node_offset: int | None
    transform_refs: tuple[dict, ...]
    action_index: int | None = None


@dataclass
class LevelAssembly:
    main_group: int
    source_name: str
    groups: tuple[int, ...]
    owners: list[dict]
    instances: list[MeshInstance]
    effect_instances: list[EffectInstance]
    owner_transforms: dict[str, SourceTransform]
    bounds: list[list[float]]
    terrain_bounds: list[list[float]] | None
    spawn: list[float]
    source_spawn: list[float]
    spawn_owner_id: str
    validation: dict


def owner_id(record: Record) -> str:
    return f"g{record.group:03d}_o{record.index:04d}_t{record.kind}"


def _category(kind: int) -> str:
    if kind == 10403:
        return "background"
    if kind in (10400, 10401, 10402):
        return "static"
    if kind in (10000, 10300, 10301):
        return "actors"
    if kind in (10200, 10203, 10204, 10600, 10602):
        return "triggers"
    return "other"


def _corners(bounds: np.ndarray) -> np.ndarray:
    return np.array([[bounds[x, 0], bounds[y, 1], bounds[z, 2]]
                     for x in (0, 1) for y in (0, 1) for z in (0, 1)])


def _union(bounds: list[np.ndarray]) -> np.ndarray | None:
    if not bounds:
        return None
    value = np.array(bounds)
    return np.stack((value[:, 0].min(axis=0), value[:, 1].max(axis=0)))


def _scene_bounds(source_bounds: np.ndarray) -> np.ndarray:
    points = scene_axes(_corners(source_bounds))
    return np.stack((points.min(axis=0), points.max(axis=0)))


def _matrix(transform: SourceTransform) -> list[float]:
    axes = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float64)
    out = np.eye(4)
    out[:3, :3] = axes @ transform.matrix @ axes.T
    out[:3, 3] = scene_axes(transform.translation)
    return out.T.reshape(-1).tolist()  # glTF column-major storage


def _batch_geometry(raw: bytes) -> tuple[dict, bytes, dict[int, list[int]], dict]:
    """Merge equal native render states and bound Godot meshes to 128 surfaces.

    The batch contains the original vertex attributes without welding, and its
    indices differ only by the appended vertex offset.  Retain a source submesh
    index list for every batch.  Images and buffers are rebuilt without dead data.
    """
    json_size = struct.unpack_from("<I", raw, 12)[0]
    original = json.loads(raw[20:20 + json_size])
    source = raw[28 + json_size:]
    doc = dict(original, meshes=[], materials=[], accessors=[], bufferViews=[], buffers=[])
    binary = bytearray()
    types = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}

    def read_accessor(index: int) -> np.ndarray:
        acc = original["accessors"][index]
        view = original["bufferViews"][acc["bufferView"]]
        dtype = {5126: "<f4", 5123: "<u2"}[acc["componentType"]]
        return np.frombuffer(source, dtype=dtype, offset=view.get("byteOffset", 0),
                             count=acc["count"] * types[acc["type"]]).reshape(acc["count"], -1)

    def view(raw_bytes: bytes, target: int | None = None) -> int:
        binary.extend(b"\0" * (-len(binary) % 4))
        item = dict(buffer=0, byteOffset=len(binary), byteLength=len(raw_bytes))
        if target is not None:
            item["target"] = target
        doc["bufferViews"].append(item)
        binary.extend(raw_bytes)
        return len(doc["bufferViews"]) - 1

    def accessor(array: np.ndarray, kind: str, indices: bool = False) -> int:
        value = np.asarray(array, dtype="<u2" if indices else "<f4")
        item = dict(bufferView=view(value.tobytes(), 34963 if indices else 34962),
                    componentType=5123 if indices else 5126, count=len(value), type=kind)
        if kind == "VEC3":
            item.update(min=value.min(axis=0).tolist(), max=value.max(axis=0).tolist())
        doc["accessors"].append(item)
        return len(doc["accessors"]) - 1

    if "images" in original:
        doc["images"] = []
        for image in original["images"]:
            old = original["bufferViews"][image["bufferView"]]
            offset = old.get("byteOffset", 0)
            doc["images"].append(dict(image, bufferView=view(source[offset:offset + old["byteLength"]])))
    material_indices: dict[str, int] = {}
    material_keys = []
    for material in original["materials"]:
        settings = {k: v for k, v in material.items() if k not in ("name", "extras")}
        source_extras = material.get("extras", {})
        flags = source_extras.get("source_flags")
        textured = "baseColorTexture" in settings.get("pbrMetallicRoughness", {})
        render = decode_material_flags(flags, textured=textured)
        require(source_extras.get("native_render", render) == render,
                "GLB native material metadata disagrees with source flags")
        animation = source_extras.get("native_material_animation")
        # Core glTF represents all three nonopaque source modes as BLEND.
        # Their native equations remain different, as do other retained flags.
        # Never merge merely because their fallback glTF settings are equal.
        key = json.dumps(dict(gltf=settings, source_flags=flags,
                              material_animation=animation), sort_keys=True, separators=(",", ":"))
        material_keys.append(key)
        if key not in material_indices:
            material_indices[key] = len(doc["materials"])
            material_label = f"level_material_{len(doc['materials']):04d}"
            if animation:
                material_label += ANIMATION_TOKEN + animation["key"]
            doc["materials"].append(dict(settings,
                                         name=native_material_name(material_label, render),
                                         extras=dict(source_flags=flags, native_render=render,
                                                     native_blend_runtime_required=render["blend_selector"] in (1, 2),
                                                     preview_culling="double_sided_until_winding_verified",
                                                     source_materials=[])))
            if animation:
                doc["materials"][-1]["extras"]["native_material_animation"] = animation
        provenance = {k: v for k, v in source_extras.items() if k != "native_render"}
        doc["materials"][material_indices[key]]["extras"]["source_materials"].append(
            dict(name=material["name"], **provenance))

    mesh_mapping: dict[int, list[int]] = {}
    before = Counter()
    after = Counter()
    for mesh_index, mesh in enumerate(original["meshes"]):
        batches: dict[tuple, list[list[tuple[int, dict]]]] = {}
        for part_index, primitive in enumerate(mesh["primitives"]):
            before["surfaces"] += 1
            nv = original["accessors"][primitive["attributes"]["POSITION"]]["count"]
            require(nv <= 65535, "Level submesh exceeds the 16-bit vertex limit")
            key = (material_keys[primitive["material"]], tuple(sorted(primitive["attributes"])))
            choices = batches.setdefault(key, [[]])
            current = choices[-1]
            existing = sum(original["accessors"][p["attributes"]["POSITION"]]["count"] for _, p in current)
            if existing + nv > 65535:
                choices.append([])
            choices[-1].append((part_index, primitive))
        primitives = []
        for (material_key, attrs), choices in batches.items():
            for parts in choices:
                arrays = {attr: [] for attr in attrs}
                morph_count = len(parts[0][1].get("targets", []))
                morphs: list[list[np.ndarray]] = [[] for _ in range(morph_count)]
                indices = []
                offset = 0
                source_parts = []
                for source_part, primitive in parts:
                    count = original["accessors"][primitive["attributes"]["POSITION"]]["count"]
                    for attr in attrs:
                        arrays[attr].append(read_accessor(primitive["attributes"][attr]))
                    require(len(primitive.get("targets", [])) == morph_count,
                            "Cannot batch incompatible morph target counts")
                    for target_index, target in enumerate(primitive.get("targets", [])):
                        require(set(target) == {"POSITION"}, "Unsupported level morph attributes")
                        morphs[target_index].append(read_accessor(target["POSITION"]))
                    original_indices = read_accessor(primitive["indices"]).reshape(-1).astype(np.uint32)
                    indices.append(original_indices + offset)
                    source_parts.append(source_part)
                    before["vertices"] += count
                    before["triangles"] += len(original_indices) // 3
                    offset += count
                joined = {attr: np.concatenate(values) for attr, values in arrays.items()}
                joined_morphs = [np.concatenate(values) for values in morphs]
                combined = np.concatenate(indices)
                # Check every source triangle and every attribute after the index rebasing.
                index_start = 0
                for _, primitive in parts:
                    original_indices = read_accessor(primitive["indices"]).reshape(-1).astype(np.uint32)
                    batch_indices = combined[index_start:index_start + len(original_indices)]
                    for attr in attrs:
                        source_array = read_accessor(primitive["attributes"][attr])
                        require(np.array_equal(joined[attr][batch_indices], source_array[original_indices]),
                                "Material batching changed a triangle vertex attribute")
                    for target_index, target in enumerate(primitive.get("targets", [])):
                        source_array = read_accessor(target["POSITION"])
                        require(np.array_equal(joined_morphs[target_index][batch_indices], source_array[original_indices]),
                                "Material batching changed a morph triangle vertex")
                    index_start += len(original_indices)
                merged = dict(attributes={attr: accessor(value, {2: "VEC2", 3: "VEC3", 4: "VEC4"}[value.shape[1]])
                                          for attr, value in joined.items()},
                              indices=accessor(combined, "SCALAR", indices=True), mode=4,
                              material=material_indices[material_key],
                              extras=dict(source_submesh_indices=source_parts))
                animation = doc["materials"][merged["material"]]["extras"].get("native_material_animation")
                if animation:
                    require(len(source_parts) == 1,
                            "An animated source part cannot be merged into another surface")
                    merged["extras"]["native_material_animation"] = animation
                if joined_morphs:
                    merged["targets"] = [dict(POSITION=accessor(value, "VEC3")) for value in joined_morphs]
                primitives.append(merged)
                after.update(vertices=offset, triangles=len(combined) // 3, surfaces=1)
        mesh_mapping[mesh_index] = []
        for start in range(0, len(primitives), 128):
            mesh_mapping[mesh_index].append(len(doc["meshes"]))
            suffix = f"_surfaces_{start:04d}" if len(primitives) > 128 else ""
            doc["meshes"].append(dict(mesh, name=mesh["name"] + suffix,
                                       primitives=primitives[start:start + 128]))
    require(before["vertices"] == after["vertices"] and before["triangles"] == after["triangles"],
            "Material batching lost source geometry")
    doc["buffers"] = [dict(byteLength=len(binary))]
    binary.extend(b"\0" * (-len(binary) % 4))
    report = dict(source_surfaces=before["surfaces"], exported_surfaces=after["surfaces"],
                  source_vertices=before["vertices"], exported_vertices=after["vertices"],
                  source_triangles=before["triangles"], exported_triangles=after["triangles"],
                  maximum_surfaces_per_mesh=max(len(m["primitives"]) for m in doc["meshes"]),
                  exported_materials=len(doc["materials"]),
                  native_material_modes=dict(Counter(m["extras"]["native_render"]["blend_mode"]
                                                     for m in doc["materials"])),
                  checked_native_render_identity=True,
                  animated_materials=sum("native_material_animation" in m["extras"] for m in doc["materials"]),
                  checked_animated_surface_isolation=True,
                  checked_every_triangle_attribute=True, checked_every_morph_triangle_attribute=True,
                  surface_limit=128)
    return doc, bytes(binary), mesh_mapping, report


def assemble_level(catalog: Catalog, main_group: int, frame: int = 0) -> LevelAssembly:
    """Resolve actual owner instances.  Unreferenced mesh resources stay unplaced."""
    require(frame == 0, "Level assembly currently exports only the first stored pose")
    index = SceneIndex(catalog)
    groups = index.groups_for_main(main_group)
    names = [d["name"] for d in catalog.descriptors if d["group"] == main_group]
    name = names[0] if names else f"source_group_{main_group:03d}"
    mesh_cache: dict[tuple[int, int], Mesh] = {}
    graph_cache: dict[tuple[int, int], ObjectGraph] = {}
    owners: list[dict] = []
    instances: list[MeshInstance] = []
    effects: list[EffectInstance] = []
    owner_transforms: dict[str, SourceTransform] = {}
    unsupported = Counter()
    counts = Counter()
    spawn_owner: dict | None = None

    def mesh_of(record: Record) -> Mesh:
        key = record.group, record.index
        if key not in mesh_cache:
            mesh_cache[key] = parse_mesh(record)
        return mesh_cache[key]

    for group in groups:
        for record in catalog.scenes[group].records:
            if record.kind < 10000:
                continue
            rid = owner_id(record)
            reader = Reader(record.data, record.label)
            transform_field = WORLD_TRANSFORM_FIELDS.get(record.kind)
            world_record = (index.resolve(group, reader.u32(transform_field), TRANSFORM_KINDS)
                            if transform_field is not None else None)
            world = parse_transform(world_record) if world_record is not None else SourceTransform.identity()
            owner_transforms[rid] = world
            category = _category(record.kind)
            owner = dict(id=rid, type=record.kind, class_name=CLASS_NAMES.get(record.kind), category=category,
                         collision_role={10400: "segment", 10402: "platform"}.get(record.kind, "none"),
                         source_group=group, source_record=record.index, source_record_offset=record.offset,
                         source_provenance=index.evidence(record),
                         position=scene_axes(world.translation).tolist() if world_record is not None else None,
                         source_position=world.translation.tolist() if world_record is not None else None,
                         source_matrix=world.matrix.tolist() if world_record is not None else None,
                         matrix=_matrix(world) if world_record is not None else None,
                         bounds=None, source_bounds=None, mesh_nodes=[], mesh_instances=[],
                         actions=[], effect_nodes=[], effect_instances=[], source_renderables=[],
                         world_transform_ref=index.evidence(world_record) if world_record is not None else None,
                         transform_refs=[index.evidence(world_record)] if world_record is not None else [],
                         initial_state=None,
                         render_policy="runtime_event" if category == "triggers" else "initial_state",
                         unsupported_renderables=[])
            owner_instances: list[MeshInstance] = []
            owner_effects: list[EffectInstance] = []
            active_action: int | None = None
            if record.kind == 10101:
                alternate = index.resolve(group, reader.u32(40), TRANSFORM_KINDS)
                owner["camera_alternate_transform_ref"] = index.evidence(alternate) if alternate is not None else None

            def emit(target: Record | None, local: SourceTransform, node_offset: int | None,
                     chain: tuple[dict, ...], stack: tuple[tuple[int, int], ...] = ()) -> None:
                if target is None:
                    return
                owner["source_renderables"].append(index.evidence(target))
                if target.kind == 2001:
                    mesh = mesh_of(target)
                    action_prefix = f"_a{active_action:03d}" if active_action else ""
                    label = f"{rid}{action_prefix}_n{len(owner_instances):04d}_mg{target.group:03d}_r{target.index:04d}"
                    owner_instances.append(MeshInstance(label, rid, mesh, local, world.compose(local),
                                                        node_offset, chain, active_action))
                    return
                if target.kind == 8003:
                    key = target.group, target.index
                    require(key not in stack and len(stack) < 32, f"{target.label}: cyclic/deep nested visual graph")
                    graph = graph_cache.setdefault(key, parse_graph(target))
                    flatten(target, graph, local, chain, (*stack, key))
                    return
                if target.kind == 7500:
                    action_prefix = f"_a{active_action:03d}" if active_action else ""
                    label = f"{rid}{action_prefix}_e{len(owner_effects):04d}_g{target.group:03d}_r{target.index:04d}"
                    owner_effects.append(EffectInstance(label, rid, target, local, world.compose(local),
                                                        node_offset, chain, active_action))
                    return
                if target.kind == 2000:
                    counts["non_mesh_camera_visual_references"] += 1
                    return
                evidence = dict(index.evidence(target), reason="unsupported_renderable_type")
                owner["unsupported_renderables"].append(evidence)
                unsupported[target.kind] += 1

            def flatten(graph_record: Record, graph: ObjectGraph, parent: SourceTransform,
                        chain: tuple[dict, ...], stack: tuple[tuple[int, int], ...], state_index: int = 0) -> None:
                for node in graph.states[state_index].nodes:
                    tr = index.resolve(graph_record.group, node.transform_ref, TRANSFORM_KINDS)
                    local = parent.compose(parse_transform(tr)) if tr is not None else parent
                    next_chain = (*chain, dict(index.evidence(tr), graph_node_offset=node.offset)) if tr is not None else chain
                    target = index.resolve(graph_record.group, node.renderable_ref)
                    emit(target, local, node.offset, next_chain, stack)

            def collision_nodes(graph_record: Record, graph: ObjectGraph, state_index: int,
                                chain: tuple[dict, ...] = (),
                                stack: tuple[tuple[int, int], ...] = ()) -> list[dict]:
                key = graph_record.group, graph_record.index
                require(key not in stack and len(stack) < 32, f"{graph_record.label}: cyclic collider visual graph")
                result = []
                for node in graph.states[state_index].nodes:
                    tr = index.resolve(graph_record.group, node.transform_ref, TRANSFORM_KINDS)
                    next_chain = (*chain, dict(index.evidence(tr), graph_node_offset=node.offset)) if tr is not None else chain
                    result.append(dict(node_index=node.index, source_node_offset=node.offset,
                                       graph_record=dict(group=graph_record.group, record=graph_record.index),
                                       collision_mask_a=node.collision_mask_a, collision_mask_b=node.collision_mask_b,
                                       source_bounds=None if node.local_bounds is None else node.local_bounds.tolist(),
                                       bounds=None if node.local_bounds is None else _scene_bounds(node.local_bounds).tolist(),
                                       transform_chain=list(next_chain),
                                       coordinate_space="node local; transform_chain not applied"))
                    target = index.resolve(graph_record.group, node.renderable_ref)
                    if target is not None and target.kind == 8003:
                        nested = parse_graph(target)
                        require(len(nested.states) == 1, f"{target.label}: nested action selection is unsupported")
                        result.extend(collision_nodes(target, nested, 0, next_chain, (*stack, key)))
                return result

            if record.kind in (10400, 10401, 10402):
                target = index.resolve(group, reader.u32(12))
                emit(target, SourceTransform.identity(), None, ())
                counts["direct_owners"] += 1
            elif record.kind in GRAPH_POINTER_FIELDS:
                graph = parse_graph(record)
                owner["initial_state"] = 0
                owner["state_count"] = len(graph.states)
                owner["graph_offset"] = graph.offset
                owner["graph_node_count"] = graph.node_count
                owner["native_graph_state_bounds"] = graph.states[0].bounds.tolist()
                owner["native_graph_node_bounds"] = [dict(node=n.index, offset=n.offset,
                                                            collision_mask_a=n.collision_mask_a,
                                                            collision_mask_b=n.collision_mask_b,
                                                            bounds=n.local_bounds.tolist())
                                                      for n in graph.states[0].nodes if n.local_bounds is not None]
                for state in graph.states:
                    active_action = state.index
                    start = len(owner_instances)
                    effect_start = len(owner_effects)
                    flatten(record, graph, SourceTransform.identity(), (), ((record.group, record.index),), state.index)
                    # Godot's glTF importer makes node names unique across the
                    # whole document, not only among siblings. An owner prefix
                    # prevents its automatic suffixes from breaking state lookup.
                    action_name = f"{rid}_Action{state.index:03d}"
                    owner["actions"].append(dict(index=state.index, node_name=action_name,
                                                  node_path=f"{rid}/{action_name}",
                                                  duration=state.duration, flags=state.flags,
                                                  source_descriptor_offset=state.offset,
                                                  source_bounds=state.bounds.tolist(),
                                                  root_motion_source_vector=state.vector.tolist(),
                                                  root_motion_vector=scene_axes(state.vector).tolist(),
                                                  root_motion_length=float(np.linalg.norm(state.vector)) * 0.01,
                                                  phase_domain="distance" if state.flags & 1 else "seconds",
                                                  cycle_distance=float(np.linalg.norm(state.vector)) * 0.01 if state.flags & 1 else None,
                                                  collision_nodes=collision_nodes(record, graph, state.index),
                                                  mesh_nodes=[i.name for i in owner_instances[start:]],
                                                  effect_nodes=[i.name for i in owner_effects[effect_start:]],
                                                  bounds=None))
                counts["graph_owners"] += 1
                if record.kind == 10000:
                    auxiliary = parse_graph(record, reader.u32(12))
                    owner["auxiliary_graph_offset"] = auxiliary.offset
                    owner["auxiliary_graph_render_policy"] = "activation_not_recovered"
                    counts["unplaced_auxiliary_graphs"] += 1
            elif record.kind == 10403:
                target = index.resolve(group, reader.u32(8))
                yaw_relative = reader.u32(16)
                distance, *offset = reader.unpack("<4f", 20)
                require(yaw_relative in (0, 1) and distance > 0
                        and bool(np.isfinite([distance, *offset]).all()), f"{record.label}: invalid backmap parameters")
                owner["render_policy"] = "camera_centered"
                owner["camera_offset"] = scene_axes(np.array(offset)).tolist()
                owner["source_camera_offset"] = offset
                owner["offset_rotates_with_camera_yaw"] = bool(yaw_relative)
                owner["source_temporary_far"] = distance
                owner["temporary_far"] = distance * 0.01
                emit(target, SourceTransform.identity(), None, ())
                counts["camera_centered_backmaps"] += 1
            elif transform_field is None:
                owner["render_policy"] = "owner_layout_not_recovered"
                counts["unsupported_owner_layouts"] += 1

            bounds = []
            action_bounds: dict[int, list[np.ndarray]] = {}
            for instance in owner_instances:
                points = np.concatenate([instance.world.points(part.vertices[0]) for part in instance.mesh.parts])
                bound = np.stack((points.min(axis=0), points.max(axis=0)))
                if instance.action_index in (None, 0):
                    bounds.append(bound)
                if instance.action_index is not None:
                    action_bounds.setdefault(instance.action_index, []).append(bound)
                owner["mesh_nodes"].append(instance.name)
                owner["mesh_instances"].append(dict(name=instance.name, action=instance.action_index,
                                                     source_mesh=dict(group=instance.mesh.group,
                                                                      record=instance.mesh.record_index),
                                                     source_node_offset=instance.source_node_offset,
                                                     transform_chain=list(instance.transform_refs),
                                                     stored_samples=instance.mesh.sample_count,
                                                     timeline_words=list(instance.mesh.timeline_words),
                                                     timeline_loop=bool(instance.mesh.animation_flags & 1)))
                owner["transform_refs"].extend(instance.transform_refs)
            source_bounds = _union(bounds)
            if source_bounds is not None:
                owner["source_bounds"] = source_bounds.tolist()
                owner["bounds"] = _scene_bounds(source_bounds).tolist()
            for action in owner["actions"]:
                bound = _union(action_bounds.get(action["index"], []))
                if bound is not None:
                    action["bounds"] = _scene_bounds(bound).tolist()
            for instance in owner_effects:
                owner["effect_nodes"].append(instance.name)
                owner["effect_instances"].append(dict(name=instance.name, action=instance.action_index,
                                                       effect_key=f"g{instance.record.group:03d}_r{instance.record.index:04d}",
                                                       source_effect=index.evidence(instance.record),
                                                       source_node_offset=instance.source_node_offset,
                                                       transform_chain=list(instance.transform_refs)))
                owner["transform_refs"].extend(instance.transform_refs)
            # Preserve each provenance reference once, in its first observed order.
            owner["transform_refs"] = list({json.dumps(e, sort_keys=True): e
                                             for e in owner["transform_refs"]}.values())
            owners.append(owner)
            instances.extend(owner_instances)
            effects.extend(owner_effects)
            if record.kind == 10000:
                require(spawn_owner is None and owner["position"] is not None,
                        f"Group {main_group}: missing or ambiguous player spawn")
                spawn_owner = owner
    require(bool(instances), f"Group {main_group}: no placed mesh geometry")
    require(spawn_owner is not None, f"Group {main_group}: no supported player spawn")
    visible = [np.array(o["bounds"]) for o in owners
               if o["bounds"] is not None and o["category"] not in ("triggers", "background")]
    terrain = [np.array(o["bounds"]) for o in owners if o["bounds"] is not None and o["collision_role"] == "segment"]
    world_bounds = _union(visible)
    terrain_bounds = _union(terrain)
    require(world_bounds is not None, f"Group {main_group}: no initial visible geometry")
    counts.update(owners=len(owners), mesh_instances=len(instances), unique_mesh_records=len(mesh_cache),
                  effect_instances=len(effects), unique_emitter_records=len({(e.record.group, e.record.index) for e in effects}),
                  exported_actions=sum(len(o["actions"]) for o in owners),
                  source_groups=len(groups), non_rendering_owners=sum(not o["mesh_nodes"] and not o["effect_nodes"] for o in owners),
                  instance_vertices=sum(i.mesh.vertex_count for i in instances),
                  instance_triangles=sum(i.mesh.triangle_count for i in instances),
                  unresolved_references=0)
    validation = dict(counts, unsupported_renderable_types=dict(sorted(unsupported.items())),
                      owner_type_counts=dict(sorted(Counter(o["type"] for o in owners).items())),
                      checked_reference_bounds=True, checked_mesh_indices=True,
                      initial_state_policy="first state, first stored matrix and first stored vertex sample")
    return LevelAssembly(main_group, name, groups, owners, instances, effects, owner_transforms,
                         world_bounds.tolist(), None if terrain_bounds is None else terrain_bounds.tolist(),
                         spawn_owner["position"], spawn_owner["source_position"], spawn_owner["id"], validation)


def _instanced_glb(catalog: Catalog, assembly: LevelAssembly) -> tuple[bytes, dict]:
    unique: dict[tuple[int, int], Mesh] = {}
    for instance in assembly.instances:
        unique.setdefault((instance.mesh.group, instance.mesh.record_index), instance.mesh)
    selections = [Selection(mesh, f"mg{key[0]:03d}_r{key[1]:04d}", np.zeros(3), np.eye(3))
                  for key, mesh in unique.items()]
    raw = export_glb(catalog, selections, include_samples=True)
    doc, binary, mesh_mapping, batch_report = _batch_geometry(raw)
    mesh_indices = {key: mesh_mapping[i] for i, key in enumerate(unique)}
    nodes: list[dict] = []
    category_indices = {}
    for key, label in (("static", "Static"), ("actors", "Actors"), ("triggers", "Triggers"),
                       ("background", "Background"), ("other", "Other")):
        category_indices[key] = len(nodes)
        nodes.append(dict(name=label, children=[]))
    owner_indices = {}
    action_indices = {}
    for owner in assembly.owners:
        # Empty native owners remain useful named transform nodes for runtime events.
        at = len(nodes)
        owner_indices[owner["id"]] = at
        nodes[category_indices[owner["category"]]]["children"].append(at)
        nodes.append(dict(name=owner["id"], matrix=_matrix(assembly.owner_transforms[owner["id"]]), children=[],
                          extras=dict(owner_id=owner["id"], source_group=owner["source_group"],
                                      source_record=owner["source_record"], source_type=owner["type"],
                                      category=owner["category"], collision_role=owner["collision_role"],
                                      render_policy=owner["render_policy"])))
        for action in owner["actions"]:
            action_at = len(nodes)
            action_indices[(owner["id"], action["index"])] = action_at
            nodes[at]["children"].append(action_at)
            nodes.append(dict(name=action["node_name"], children=[],
                              extras=dict(owner_id=owner["id"], action_index=action["index"],
                                          default_visible=action["index"] == 0)))
    for instance in assembly.instances:
        parent_at = (owner_indices[instance.owner_id] if instance.action_index is None
                     else action_indices[(instance.owner_id, instance.action_index)])
        nodes[parent_at]["children"].append(len(nodes))
        mesh_node = dict(name=instance.name, matrix=_matrix(instance.local),
                         extras=dict(owner_id=instance.owner_id, source_group=instance.mesh.group,
                                     source_record=instance.mesh.record_index,
                                     source_node_offset=instance.source_node_offset,
                                     source_transform_refs=list(instance.transform_refs)))
        split_meshes = mesh_indices[(instance.mesh.group, instance.mesh.record_index)]
        nodes.append(mesh_node)
        if len(split_meshes) == 1:
            mesh_node["mesh"] = split_meshes[0]
        else:
            mesh_node["children"] = []
            for split_index, mesh_index in enumerate(split_meshes):
                mesh_node["children"].append(len(nodes))
                nodes.append(dict(name=f"{instance.name}_part{split_index:03d}", mesh=mesh_index,
                                  extras=dict(owner_id=instance.owner_id)))
    for instance in assembly.effect_instances:
        parent_at = (owner_indices[instance.owner_id] if instance.action_index is None
                     else action_indices[(instance.owner_id, instance.action_index)])
        nodes[parent_at]["children"].append(len(nodes))
        nodes.append(dict(name=instance.name, matrix=_matrix(instance.local),
                          extras=dict(owner_id=instance.owner_id,
                                      effect_key=f"g{instance.record.group:03d}_r{instance.record.index:04d}",
                                      source_type=7500, source_node_offset=instance.source_node_offset,
                                      source_transform_refs=list(instance.transform_refs))))
    root = len(nodes)
    nodes.append(dict(name=f"g{assembly.main_group:03d}", children=list(category_indices.values())))
    for node in nodes:
        if node.get("children") == []:
            del node["children"]
    require(len({node["name"] for node in nodes}) == len(nodes),
            "Level GLB node names must be globally unique before Godot import")
    for owner in assembly.owners:
        for action in owner["actions"]:
            node_index = action_indices[(owner["id"], action["index"])]
            require(nodes[node_index]["name"] == action["node_name"]
                    and action["node_path"] == f"{owner['id']}/{action['node_name']}"
                    and node_index in nodes[owner_indices[owner["id"]]]["children"],
                    "Action manifest path does not match its GLB owner/child nodes")
    doc["nodes"] = nodes
    doc["scenes"] = [dict(name=assembly.source_name, nodes=[root])]
    doc["extras"] = dict(source_main_group=assembly.main_group, source_groups=list(assembly.groups),
                         initial_state=0, source_unit_scale=0.01,
                         trigger_visibility="hide Triggers until a runtime event activates it",
                         action_visibility="show exactly one Action### per owner; all action geometry is present")
    encoded = json.dumps(doc, separators=(",", ":"), allow_nan=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    size = 28 + len(encoded) + len(binary)
    result = (struct.pack("<4sII", b"glTF", 2, size)
              + struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
              + struct.pack("<II", len(binary), 0x004E4942) + binary)
    report = verify_glb(result)
    # Verify matrices after JSON round-trip, independently of the writer helper.
    reparsed = json.loads(result[20:20 + len(encoded)])
    by_name = {n["name"]: n for n in reparsed["nodes"]}
    error = 0.0
    for instance in assembly.instances:
        a = np.array(by_name[instance.owner_id]["matrix"]).reshape(4, 4).T
        b = np.array(by_name[instance.name]["matrix"]).reshape(4, 4).T
        points = instance.mesh.parts[0].vertices[0]
        local = np.column_stack((scene_axes(points), np.ones(len(points))))
        actual = (local @ (a @ b).T)[:, :3]
        expected = scene_axes(instance.world.points(points))
        error = max(error, float(np.max(np.abs(actual - expected))))
    for instance in assembly.effect_instances:
        a = np.array(by_name[instance.owner_id]["matrix"]).reshape(4, 4).T
        b = np.array(by_name[instance.name]["matrix"]).reshape(4, 4).T
        points = np.array([[0, 0, 0], [100, 0, 0], [0, 100, 0], [0, 0, 100]], dtype=np.float64)
        actual = (np.column_stack((scene_axes(points), np.ones(4))) @ (a @ b).T)[:, :3]
        error = max(error, float(np.max(np.abs(actual - scene_axes(instance.world.points(points))))))
    require(error < 1e-4, "Level GLB instance matrices do not reproduce source-space placements")
    report.update(instance_count=len(assembly.instances), owner_nodes=len(assembly.owners),
                  checked_unique_node_names=True, checked_action_node_paths=True,
                  effect_anchor_nodes=len(assembly.effect_instances), checked_effect_anchor_matrices=True,
                  checked_instance_matrices=True, maximum_matrix_roundtrip_error=error,
                  matrix_roundtrip_tolerance=1e-4,
                  world_bounds=assembly.bounds, material_batching=batch_report)
    return result, report


def export_level(assembly: LevelAssembly, catalog: Catalog, output: Path) -> dict:
    """Write one level inside a caller-owned staging output directory."""
    label = f"g{assembly.main_group:03d}"
    level_dir = output / "levels"
    level_dir.mkdir(parents=True, exist_ok=True)
    geometry_path, manifest_path = f"levels/{label}.glb", f"levels/{label}.json"
    require(not (output / geometry_path).exists() and not (output / manifest_path).exists(),
            f"Level output {label} already exists; use a new staging directory")
    encoded, verified = _instanced_glb(catalog, assembly)
    entry = dict(id=label, main_group=assembly.main_group, source_name=assembly.source_name,
                 groups=list(assembly.groups), geometry_path=geometry_path, manifest_path=manifest_path,
                 geometry_sha256=hashlib.sha256(encoded).hexdigest(), bounds=assembly.bounds,
                 terrain_bounds=assembly.terrain_bounds, spawn=assembly.spawn,
                 source_spawn=assembly.source_spawn, spawn_owner_id=assembly.spawn_owner_id,
                 validation=dict(assembly.validation, glb=verified))
    from .animation import parse_transform_track
    from .effects import export_emitter
    from .scopes import decode_scope_policy
    tracks = {}
    collision_meshes = {}
    effect_definitions = {}
    index = SceneIndex(catalog)
    scope_policy = decode_scope_policy(catalog, assembly.main_group)
    segments = scope_policy["segments"]
    for segment in segments:
        records = [o for o in assembly.owners if o["source_group"] == segment["group"]]
        segment["owner_ids"] = [o["id"] for o in records]
        terrain = [o for o in records if o["type"] == 10400]
        segment["terrain_owner_ids"] = [o["id"] for o in terrain]
        bounds = _union([np.array(o["bounds"]) for o in terrain if o["bounds"] is not None])
        segment["bounds"] = None if bounds is None else bounds.tolist()
    for instance in assembly.effect_instances:
        key = f"g{instance.record.group:03d}_r{instance.record.index:04d}"
        if key not in effect_definitions:
            effect_definitions[key] = export_emitter(instance.record, catalog, output, index)
    # Event parameters can reference paths which are not the initial world or
    # visual transform (for example Getaway's camera-effect path g069/r0007).
    for group in assembly.groups:
        for record in catalog.scenes[group].records:
            if record.kind in TRANSFORM_KINDS:
                tracks[f"g{group:03d}_r{record.index:04d}"] = parse_transform_track(record).manifest()
    for owner in assembly.owners:
        references = ([owner["world_transform_ref"]] if owner["world_transform_ref"] is not None else [])
        if owner.get("camera_alternate_transform_ref") is not None:
            references.append(owner["camera_alternate_transform_ref"])
        references += [ref for instance in owner["mesh_instances"] for ref in instance["transform_chain"]]
        references += [ref for instance in owner["effect_instances"] for ref in instance["transform_chain"]]
        for ref in references:
            key = f"g{ref['group']:03d}_r{ref['record']:04d}"
            if key not in tracks:
                tracks[key] = parse_transform_track(catalog.record(ref["group"], ref["record"])).manifest()
        if owner["type"] == 10400:
            require(len(owner["mesh_instances"]) == 1, f"{owner['id']}: segment must have one mesh reference")
            ref = owner["mesh_instances"][0]["source_mesh"]
            key = f"g{ref['group']:03d}_r{ref['record']:04d}"
            if key not in collision_meshes:
                collision = parse_collision_mesh(catalog.record(ref["group"], ref["record"]))
                if collision is None:
                    owner["collision_mesh_key"] = None
                    owner["collision_geometry"] = "none_in_source"
                    continue
                points = np.concatenate([t.vertices for t in collision.triangles])
                collision_meshes[key] = dict(source_group=collision.group, source_record=collision.record,
                                             source_root_offset=collision.root_offset,
                                             source_quadtree=list(collision.nodes),
                                             faces=scene_axes(points).tolist(),
                                             surface_types=[t.surface_type for t in collision.triangles],
                                             source_triangles=[[t.submesh, t.triangle] for t in collision.triangles],
                                             triangle_count=len(collision.triangles),
                                             triangle_reference_count=collision.triangle_reference_count,
                                             leaf_count=collision.leaf_count,
                                             coordinate_space="mesh local, same axes/scale as GLB",
                                             surface_type_semantics="native numeric ID; labels are not inferred")
            owner["collision_mesh_key"] = key
            owner["collision_geometry"] = "native_mesh_quadtree"
    entry["validation"]["native_collision"] = dict(
        meshes=len(collision_meshes),
        unique_triangles=sum(m["triangle_count"] for m in collision_meshes.values()),
        triangle_references=sum(m["triangle_reference_count"] for m in collision_meshes.values()),
        checked_every_source_face_index=True, render_triangle_fallbacks=0,
        segments_without_source_tree=sum(o.get("collision_geometry") == "none_in_source" for o in assembly.owners))
    entry["validation"]["native_scopes"] = scope_policy["validation"]
    manifest = dict(schema_version=1, **entry, source_container_sha256=sha256(catalog.container.data),
                    coordinate_system=dict(source="X,Y ground plane; Z up", output="Y-up; x=source_x, y=source_z, z=-source_y",
                                           mapping="(source_x, source_z, -source_y) * 0.01"),
                    owners=assembly.owners, native_transform_tracks=tracks,
                    native_collision_meshes=collision_meshes, effect_definitions=effect_definitions,
                    segments=segments, first_segment_group=segments[0]["group"] if segments else None,
                    native_scope_policy=scope_policy,
                    fidelity_limits=FIDELITY_LIMITS)
    (output / geometry_path).write_bytes(encoded)
    write_json(output / manifest_path, manifest)
    return entry


def export_campaign(catalog: Catalog, output: Path) -> dict:
    """Export all eight original playable scenes into an importer staging folder.

    Existing campaign files are never replaced.  The caller can atomically
    publish its complete asset directory after this function has succeeded.
    """
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    require(not (output / "levels").exists() and not (output / "campaign.json").exists()
            and not (output / "effects").exists(),
            "Campaign output already exists; import into a fresh staging directory")
    index = SceneIndex(catalog)
    audit = index.audit()
    entries = []
    with tempfile.TemporaryDirectory(prefix=".level-stage-", dir=output) as temporary:
        stage = Path(temporary)
        for main in PLAYABLE_MAIN_GROUPS:
            assembly = assemble_level(catalog, main)
            entries.append(export_level(assembly, catalog, stage))
        campaign = dict(schema_version=1, source_container_sha256=sha256(catalog.container.data),
                        levels=entries, validation=dict(audit, exported_levels=len(entries),
                                                       source_main_groups=list(PLAYABLE_MAIN_GROUPS)),
                        fidelity_limits=FIDELITY_LIMITS)
        write_json(stage / "campaign.json", campaign)
        os.replace(stage / "levels", output / "levels")
        if (stage / "effects").exists():
            os.replace(stage / "effects", output / "effects")
        os.replace(stage / "campaign.json", output / "campaign.json")
    return campaign
