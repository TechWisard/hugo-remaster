class_name NativeActorMotion
extends Node
## Source action graphs, including mesh morphs, effect anchors and world paths.
## Phases passed to sample_state are the signed ticker result, not elapsed time.

const NativeMaterialsScript = preload("res://scripts/native_materials.gd")

var owner_visual: Node3D
var source: Dictionary
var native: Dictionary
var tracks: Dictionary
var sampler: HugoOriginalAnimation
var player: Node3D
var autonomous: bool = true
var active_action: int = 0
var sampled_visual_phase: float = 0.0
var sampled_path_phase: float = 0.0
var binding_error: String = ""
var _actions: Dictionary = {}
var _instances: Array[Dictionary] = []
var _world_track: Dictionary = {}
var _visual_phase: float = 0.0
var _path_phase: float = 0.0
var _last_position := Vector3.ZERO
var _source_transform := Transform3D.IDENTITY


func _ready() -> void:
	process_physics_priority = -40
	_source_transform = owner_visual.transform
	var bound_nodes: Dictionary = {}
	for action: Dictionary in source.get("actions", []):
		var index: int = int(action.index)
		var info: Dictionary = action.duplicate()
		var expected_path: String = str(action.node_name)
		var node: Node3D = owner_visual.get_node_or_null(expected_path) as Node3D
		# A glTF importer can rename repeated names globally. Binding a guessed
		# prefix would display the wrong source action. Reject mismatched data.
		if node == null or _actions.has(index) or bound_nodes.has(node.get_instance_id() if node != null else 0):
			binding_error = "Native action binding failed: owner=%s action=%d expected=%s" % [
				str(source.get("id", owner_visual.name)), index, expected_path]
			push_error(binding_error + ". Reimport matching generated level geometry and manifest.")
			set_physics_process(false)
			return
		bound_nodes[node.get_instance_id()] = true
		info["node"] = node
		_actions[index] = info
	for instance: Dictionary in source.get("mesh_instances", []):
		_register_instance(instance, true)
	for instance: Dictionary in source.get("effect_instances", []):
		_register_instance(instance, false)
	var world_ref: Variant = source.get("world_transform_ref")
	if world_ref is Dictionary:
		_world_track = tracks.get(track_key(world_ref), {})
	var parameters: Dictionary = native.get("motion", {})
	_visual_phase = float(parameters.get("visual_initial_phase", 0.0))
	_path_phase = float(parameters.get("transform_initial_phase", 0.0))
	set_action_index(0)
	if autonomous:
		sample_state(active_action, _visual_phase, _path_phase,
			{"animate_transform": parameters.has("transform_period_seconds")})
	_last_position = owner_visual.global_position


func _register_instance(instance: Dictionary, morph: bool) -> void:
	var node: Node3D = owner_visual.find_child(str(instance.name), true, false) as Node3D
	if node == null:
		return
	var chain: Array[Dictionary] = resolve_chain(instance.get("transform_chain", []))
	var morph_nodes: Array[MeshInstance3D] = []
	# Texture animation is independent of the stored vertex-sample count.
	if morph:
		_gather_meshes(node, morph_nodes)
	_instances.append({"node": node,
		"action": int(instance.action) if instance.get("action") != null else -1,
		"chain": chain, "morph_nodes": morph_nodes, "data": instance})


func _physics_process(delta: float) -> void:
	if not binding_error.is_empty() or not autonomous or not is_instance_valid(owner_visual):
		return
	# The original update discards a stall exceeding one second.
	if delta > 1.0:
		delta = 0.0
	var parameters: Dictionary = native.get("motion", {})
	var path_period: float = float(parameters.get("transform_period_seconds", 0.0))
	if path_period > 0.0:
		_path_phase = ticker_phase(_path_phase + delta / path_period)
		apply_world_phase(_path_phase)
	var action: Dictionary = get_action_info(active_action)
	if str(action.get("phase_domain", "seconds")) == "distance":
		var cycle_distance: float = float(action.get("root_motion_length", 0.0))
		if cycle_distance > 0.0:
			_visual_phase = ticker_phase(_visual_phase + owner_visual.global_position.distance_to(_last_position) / cycle_distance)
	else:
		var period: float = float(parameters.get("visual_period_seconds", action.get("duration", 0.0)))
		if period > 0.0:
			_visual_phase = ticker_phase(_visual_phase + delta / period)
	_last_position = owner_visual.global_position
	sample_state(active_action, _visual_phase, _path_phase, {"animate_transform": false})


func get_action_info(index: int) -> Dictionary:
	return _actions.get(index, {})


func reset_playback(index: int = 0, visual_phase: float = 0.0, path_phase: float = 0.0) -> void:
	_visual_phase = ticker_phase(visual_phase)
	_path_phase = ticker_phase(path_phase)
	sample_state(index, _visual_phase, _path_phase,
		{"animate_transform": native.get("motion", {}).has("transform_period_seconds")})
	_last_position = owner_visual.global_position


func reset_native_checkpoint() -> void:
	# Invoke for reloaded child-scope autonomous objects. State actors have
	# their separate event31 contract and must not use this convenience method.
	owner_visual.transform = _source_transform
	var parameters: Dictionary = native.get("motion", {})
	reset_playback(0, float(parameters.get("visual_initial_phase", 0.0)),
		float(parameters.get("transform_initial_phase", 0.0)))


func set_action_index(index: int) -> void:
	if not binding_error.is_empty():
		return
	active_action = index
	for key: int in _actions:
		var node: Node3D = _actions[key].get("node") as Node3D
		if is_instance_valid(node):
			node.visible = key == index


func apply_world_phase(phase: float) -> void:
	if binding_error.is_empty() and is_instance_valid(owner_visual) and sampler != null and not _world_track.is_empty():
		sampled_path_phase = ticker_phase(phase)
		owner_visual.transform = sampler.to_godot_transform(sampler.sample_native_transform(_world_track, sampled_path_phase))


func sample_state(index: int, visual_phase: float, path_phase: float, state: Dictionary) -> void:
	if not binding_error.is_empty() or not is_instance_valid(owner_visual) or sampler == null:
		return
	if active_action != index:
		set_action_index(index)
	sampled_visual_phase = ticker_phase(visual_phase)
	sampled_path_phase = ticker_phase(path_phase)
	if state.get("animate_transform", false):
		apply_world_phase(sampled_path_phase)
	# Collision boxes are sampled separately, without this rendering distance cull.
	if is_instance_valid(player) and owner_visual.global_position.distance_squared_to(player.global_position) > 32400.0:
		return
	for item: Dictionary in _instances:
		if int(item.action) >= 0 and int(item.action) != index:
			continue
		if not item.chain.is_empty():
			(item.node as Node3D).transform = sample_chain(item.chain, sampled_visual_phase)
		for mesh: MeshInstance3D in item.morph_nodes:
			sampler.apply_native_morph(mesh, item.data, sampled_visual_phase)
			NativeMaterialsScript.apply_phase(mesh, sampled_visual_phase)


func resolve_chain(references: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for reference: Dictionary in references:
		var track: Dictionary = tracks.get(track_key(reference), {})
		if not track.is_empty():
			result.append(track)
	return result


func sample_chain(chain: Array, phase: float) -> Transform3D:
	var combined := Transform3D.IDENTITY
	for track: Dictionary in chain:
		combined = combined * sampler.sample_native_transform(track, phase)
	return sampler.to_godot_transform(combined)


static func ticker_phase(value: float) -> float:
	# CTicker 0x416100 keeps the exact endpoint 1 until the following update.
	return fposmod(value, 1.0) if value > 1.0 or value < 0.0 else value


static func track_key(reference: Dictionary) -> String:
	return "g%03d_r%04d" % [int(reference.group), int(reference.record)]


func _gather_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_gather_meshes(child, result)
