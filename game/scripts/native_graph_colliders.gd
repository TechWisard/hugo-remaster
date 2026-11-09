class_name NativeGraphColliders
extends Node
## Directed native logic collisions, sampled from the active graph action.
## category = node+20; receive_mask = node+24. Bounds are node-local boxes.
## Native dispatch: receiver.receive_mask & other.category, payload OWN collider first.

signal collided(other: NativeGraphColliders, own_node: Dictionary, other_node: Dictionary)

var source: Dictionary
var owner_visual: Node3D
var motion: NativeActorMotion
var player: Node3D
var receiver: Node
var space: Node
var tracks: Dictionary
var sampler: HugoOriginalAnimation
var enabled: bool = true
var active_boxes: Array[Dictionary] = []
var active_action: int = -1
var sampled_phase: float = 0.0
var physical_body: AnimatableBody3D
var _physical_shape: CollisionShape3D
var _actions: Dictionary = {}
var _bounds := AABB()
var _category_union: int = 0
var _receive_union: int = 0
var _space_key: int = 0
var _action_has_animated_boxes: Dictionary = {}
var _pose_cached: bool = false
var _cached_action: int = -1
var _cached_phase: float = 0.0
var _cached_transform := Transform3D.IDENTITY
var _cached_physical_flags: int = 0
var refreshed_poses: int = 0
var reused_poses: int = 0
var sampled_local_poses: int = 0
var reused_local_poses: int = 0
var physical_layer_changes: int = 0
static var _spaces: Dictionary = {}


func _ready() -> void:
	process_physics_priority = 100
	if space == null:
		space = get_parent()
	_space_key = space.get_instance_id()
	if not _spaces.has(_space_key):
		_spaces[_space_key] = []
	(_spaces[_space_key] as Array).append(self)
	for action: Dictionary in source.get("actions", []):
		var nodes: Array[Dictionary] = []
		var animated: bool = false
		for item: Dictionary in action.get("collision_nodes", []):
			var bounds: Variant = item.get("bounds")
			if not bounds is Array or bounds.size() != 2:
				continue
			var low: Vector3 = _vector(bounds[0])
			var high: Vector3 = _vector(bounds[1])
			if not low.is_finite() or not high.is_finite() or low.x > high.x or low.y > high.y or low.z > high.z:
				continue
			var chain: Array[Dictionary] = []
			var node_animated: bool = false
			for reference: Dictionary in item.get("transform_chain", []):
				var key: String = "g%03d_r%04d" % [int(reference.group), int(reference.record)]
				var track: Dictionary = tracks.get(key, {})
				if not track.is_empty():
					chain.append(track)
					node_animated = node_animated or (track.get("translation_keys", []) as Array).size() > 1 \
						or (track.get("rotation_keys", []) as Array).size() > 1
			animated = animated or node_animated
			nodes.append({"node_index": int(item.get("node_index", 0)),
				"source_node_offset": int(item.get("source_node_offset", 0)),
				"graph_record": item.get("graph_record", {}),
				"category": int(item.get("collision_mask_a", 0)),
				"receive_mask": int(item.get("collision_mask_b", 0)),
				"owner_graph": _is_owner_graph(item.get("graph_record", {})), "physical_slot": false,
				"local_center": (low + high) * 0.5,
				"half_extents": (high - low) * 0.5, "chain": chain, "animated": node_animated})
		# 0x415f42 skips NULL graph boxes before constructing the packed collider
		# array. Its child0 can therefore be graph node1, node2, etc.
		var first_node: Dictionary = {}
		for node: Dictionary in nodes:
			if node.owner_graph and (first_node.is_empty() or int(node.node_index) < int(first_node.node_index)):
				first_node = node
		if not first_node.is_empty():
			first_node["physical_slot"] = true
		_actions[int(action.index)] = nodes
		_action_has_animated_boxes[int(action.index)] = animated
	refresh()


func _exit_tree() -> void:
	if _spaces.has(_space_key):
		(_spaces[_space_key] as Array).erase(self)
		if (_spaces[_space_key] as Array).is_empty():
			_spaces.erase(_space_key)


func _physics_process(_delta: float) -> void:
	# A single coordinator samples all peers before testing a pair. This avoids
	# mixing the previous pose of one actor with the new pose of another actor.
	var peers: Array = _spaces.get(_space_key, [])
	if peers.is_empty() or peers[0] != self:
		return
	for peer: NativeGraphColliders in peers:
		peer.refresh()
	for i: int in range(peers.size()):
		var a: NativeGraphColliders = peers[i]
		if a.active_boxes.is_empty():
			continue
		for j: int in range(i + 1, peers.size()):
			var b: NativeGraphColliders = peers[j]
			if b.active_boxes.is_empty():
				continue
			if (a._receive_union & b._category_union) == 0 and (b._receive_union & a._category_union) == 0:
				continue
			if not a._bounds.grow(0.000001).intersects(b._bounds):
				continue
			_test_pair(a, b)


func refresh() -> void:
	if not enabled or sampler == null:
		_clear_world_pose()
		return
	if is_instance_valid(receiver) and receiver.has_method("is_logic_enabled") and not receiver.call("is_logic_enabled"):
		_clear_world_pose()
		return
	var base := Transform3D.IDENTITY
	if is_instance_valid(player):
		active_action = int(player.call("get_native_visual_action"))
		sampled_phase = float(player.call("get_native_visual_phase"))
		base = player.call("get_native_visual_transform") as Transform3D
	elif is_instance_valid(owner_visual):
		if not owner_visual.is_visible_in_tree():
			_clear_world_pose()
			return
		active_action = motion.active_action if is_instance_valid(motion) else 0
		sampled_phase = motion.sampled_visual_phase if is_instance_valid(motion) else 0.0
		base = owner_visual.global_transform
	else:
		_clear_world_pose()
		return
	var physical_flags: int = int(receiver.get("physical_flags")) if is_instance_valid(receiver) and is_instance_valid(owner_visual) else 0
	var relevant_phase: float = sampled_phase if bool(_action_has_animated_boxes.get(active_action, false)) else 0.0
	# Source graphs are immutable after binding. A fixed action/transform and
	# fixed authored box tracks produce identical OBBs, regardless of render phase.
	# State transitions still call refresh immediately, before subsequent pairs.
	if _pose_cached and active_action == _cached_action and relevant_phase == _cached_phase \
		and base == _cached_transform and physical_flags == _cached_physical_flags:
		reused_poses += 1
		return
	# The physical body remains registered while an active pose moves. Its
	# layer changes only when the finished source state actually enables or
	# disables slot0; a temporary 0 -> 1 cycle needlessly rebuilds broadphase.
	_clear_world_pose(false)
	for item: Dictionary in _actions.get(active_action, []):
		var world_pose: Transform3D = base * _local_pose(item)
		var box: Dictionary = make_box(world_pose, item.local_center, item.half_extents)
		box["category"] = item.category
		box["receive_mask"] = item.receive_mask
		box["node_index"] = item.node_index
		box["source_node_offset"] = item.source_node_offset
		box["graph_record"] = item.graph_record
		box["transform"] = world_pose
		box["local_center"] = item.local_center
		box["half_extents"] = item.half_extents
		box["physical_slot"] = item.physical_slot
		active_boxes.append(box)
		_category_union |= int(item.category)
		_receive_union |= int(item.receive_mask)
		_bounds = box.aabb if active_boxes.size() == 1 else _bounds.merge(box.aabb)
	_sync_physical_body(physical_flags)
	_cached_action = active_action
	_cached_phase = relevant_phase
	_cached_transform = base
	_cached_physical_flags = physical_flags
	_pose_cached = true
	refreshed_poses += 1


func invalidate_pose() -> void:
	## Explicitly resample bound tracks after diagnostic edits. Normal world
	## movement/visibility only invalidates world boxes, not immutable local data.
	for action: int in _actions:
		var animated: bool = false
		for item: Dictionary in _actions[action]:
			item.erase("static_pose")
			item.animated = false
			for track: Dictionary in item.chain:
				item.animated = bool(item.animated) or (track.get("translation_keys", []) as Array).size() > 1 \
					or (track.get("rotation_keys", []) as Array).size() > 1
			animated = animated or bool(item.animated)
		_action_has_animated_boxes[action] = animated
	_clear_world_pose()


func _local_pose(item: Dictionary) -> Transform3D:
	if item.has("static_pose"):
		reused_local_poses += 1
		return item.static_pose as Transform3D
	var pose := Transform3D.IDENTITY
	for track: Dictionary in item.chain:
		pose = pose * sampler.sample_native_transform(track, sampled_phase)
	pose = sampler.to_godot_transform(pose)
	if not bool(item.animated):
		item["static_pose"] = pose
	sampled_local_poses += 1
	return pose


func _clear_world_pose(disable_physical: bool = true) -> void:
	_pose_cached = false
	active_boxes.clear()
	_category_union = 0
	_receive_union = 0
	if disable_physical:
		_set_physical_layer(0)


func _set_physical_layer(layer: int) -> void:
	if is_instance_valid(physical_body) and physical_body.collision_layer != layer:
		physical_body.collision_layer = layer
		physical_layer_changes += 1


func _is_owner_graph(reference: Dictionary) -> bool:
	return not source.has("source_group") or (int(reference.get("group", -1)) == int(source.source_group)
		and int(reference.get("record", -1)) == int(source.source_record))


func _sync_physical_body(physical_flags: int) -> void:
	if not is_instance_valid(receiver) or not is_instance_valid(owner_visual):
		_set_physical_layer(0)
		return
	# Native wrapper is attached to packed CCharacterCollD child0, not a union.
	# 0x41a8c1 tests flags as nonzero; bits8/16 do not distinguish floor/wall.
	if (physical_flags & 0x18) == 0:
		_set_physical_layer(0)
		return
	for box: Dictionary in active_boxes:
		if not box.physical_slot:
			continue
		if not is_instance_valid(physical_body):
			physical_body = AnimatableBody3D.new()
			physical_body.name = "NativePhysicalSlot0"
			physical_body.sync_to_physics = false
			physical_body.collision_mask = 0
			physical_body.set_meta("native_owner", str(source.get("id", "")))
			owner_visual.add_child(physical_body)
			_physical_shape = CollisionShape3D.new()
			_physical_shape.shape = BoxShape3D.new()
			physical_body.add_child(_physical_shape)
		var size: Vector3 = (box.half_extents as Vector3) * 2.0
		if (_physical_shape.shape as BoxShape3D).size != size:
			(_physical_shape.shape as BoxShape3D).size = size
		if _physical_shape.position != box.local_center:
			_physical_shape.position = box.local_center
		if physical_body.global_transform != box.transform:
			physical_body.global_transform = box.transform
		_set_physical_layer(1)
		return
	_set_physical_layer(0)


static func _test_pair(a: NativeGraphColliders, b: NativeGraphColliders) -> void:
	# Copies retain the collider payload from this collision pass even if its
	# handler changes the active state/action. No guessed reach or attack cone.
	var a_boxes: Array = a.active_boxes.duplicate()
	var b_boxes: Array = b.active_boxes.duplicate()
	for own: Dictionary in a_boxes:
		for other: Dictionary in b_boxes:
			var to_a: bool = (int(own.receive_mask) & int(other.category)) != 0
			var to_b: bool = (int(other.receive_mask) & int(own.category)) != 0
			if not to_a and not to_b:
				continue
			if not boxes_intersect(own, other):
				continue
			if to_a:
				a._deliver(b, own, other)
			if to_b:
				b._deliver(a, other, own)


func _deliver(other: NativeGraphColliders, own_node: Dictionary, other_node: Dictionary) -> void:
	if not enabled:
		return
	if is_instance_valid(player):
		if (int(own_node.category) & 2) != 0 and bool(player.get("is_attacking")):
			if is_instance_valid(other.receiver) and other.receiver.has_method("receive_native_damage"):
				other.receiver.call("receive_native_damage", 1, int(player.get("attack_serial")), str(source.get("id", "player")))
	elif is_instance_valid(receiver) and receiver.has_method("receive_logic_collision"):
		receiver.call("receive_logic_collision", own_node, other_node, other)
	collided.emit(other, own_node, other_node)


static func make_box(pose: Transform3D, local_center: Vector3, half_extents: Vector3) -> Dictionary:
	var center: Vector3 = pose * local_center
	var edges: Array[Vector3] = [pose.basis.x * half_extents.x,
		pose.basis.y * half_extents.y, pose.basis.z * half_extents.z]
	var radius: Vector3 = edges[0].abs() + edges[1].abs() + edges[2].abs()
	return {"center": center, "edges": edges, "aabb": AABB(center - radius, radius * 2.0)}


static func boxes_intersect(a: Dictionary, b: Dictionary) -> bool:
	if not (a.aabb as AABB).grow(0.000001).intersects(b.aabb):
		return false
	var ae: Array = a.edges
	var be: Array = b.edges
	var difference: Vector3 = b.center - a.center
	# Separating-axis test also supports source bases containing scale/shear.
	for index: int in range(3):
		if _separated(ae[(index + 1) % 3].cross(ae[(index + 2) % 3]), difference, ae, be):
			return false
		if _separated(be[(index + 1) % 3].cross(be[(index + 2) % 3]), difference, ae, be):
			return false
		for other_index: int in range(3):
			if _separated(ae[index].cross(be[other_index]), difference, ae, be):
				return false
	return true


static func _separated(axis: Vector3, difference: Vector3, a: Array, b: Array) -> bool:
	if axis.length_squared() < 0.000000000001:
		return false
	var radius: float = 0.0
	for edge: Vector3 in a:
		radius += absf(axis.dot(edge))
	for edge: Vector3 in b:
		radius += absf(axis.dot(edge))
	return absf(axis.dot(difference)) > radius + 0.000001 * axis.length()


static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
