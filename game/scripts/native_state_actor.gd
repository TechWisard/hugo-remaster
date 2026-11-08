class_name NativeStateActor
extends Node
## Execute the recovered CSimpleStateActor table and its directed collisions.

const GraphScript = preload("res://scripts/native_graph_colliders.gd")

var source_id: String
var native: Dictionary
var visual: Node3D
var level: Node3D
var area: Area3D # Kept for callers migrating from the old coarse trigger.
var motion: NativeActorMotion
var graph_colliders: NativeGraphColliders
var state_index: int = 0
var previous_state: int = 0
var hit_points: int = 0
var removed: bool = false
var elapsed: float = 0.0
var visual_phase: float = 0.0
var path_phase: float = 0.0
var visual_loops: int = 0
var path_loops: int = 0
var physical_flags: int = 0
var persistent_activation: bool = false
var scope_resident: bool = true
var scope_active: bool = true
var remember_removed_on_unload: bool = false
var _states: Array = []
var _voices: Array[AudioStreamPlayer3D] = []
var _sound_cues_played: Dictionary = {}
var _initial_health: int = 0
var _restored: Dictionary = {}
var _initial_transform := Transform3D.IDENTITY
var _last_position := Vector3.ZERO
var _last_damage_id: int = -1
var _transitioning: bool = false
var _last_transition_changed: bool = false


func _ready() -> void:
	process_physics_priority = -30
	_states = native.get("state_machine", {}).get("states", [])
	_initial_health = int(native.get("state_machine", {}).get("initial_health_base", 0))
	if native.get("state_machine", {}).get("health_adds_difficulty_index", false):
		_initial_health += int(level.get("difficulty"))
	hit_points = _initial_health
	_initial_transform = visual.transform
	# Logic comes from the graph, never from the enclosing rendered mesh AABB.
	if is_instance_valid(area):
		area.monitoring = false
		area.monitorable = false
	if not _restored.is_empty():
		apply_saved_state(_restored)
	else:
		_transition(int(native.get("state_machine", {}).get("initial_state", 0)), scope_resident)
		_apply_initial_phases()
	if is_instance_valid(motion):
		graph_colliders = GraphScript.new()
		graph_colliders.source = motion.source
		graph_colliders.owner_visual = visual
		graph_colliders.motion = motion
		graph_colliders.receiver = self
		graph_colliders.space = level
		graph_colliders.tracks = motion.tracks
		graph_colliders.sampler = motion.sampler
		add_child(graph_colliders)
	_last_position = visual.global_position
	set_physics_process(scope_active)


func is_logic_enabled() -> bool:
	return scope_active and not removed and not _states.is_empty() and int(_states[state_index].get("visual_action", -1)) >= 0


func set_native_scope(resident: bool, active: bool) -> void:
	scope_resident = resident
	scope_active = resident and active
	set_physics_process(scope_active)
	if not resident:
		_stop_voices()
	if is_instance_valid(graph_colliders):
		graph_colliders.enabled = scope_active
		graph_colliders.refresh()


func removed_after_scope_unload() -> bool:
	# State flag0x2000 latches actor+0xb4 at0x409457. Destructor0x4079c7
	# registers its persistent ID as removed when that latch is set.
	return removed or remember_removed_on_unload


func restore(saved: Dictionary) -> void:
	_restored = saved
	if is_node_ready() and not saved.is_empty():
		apply_saved_state(saved)


func apply_saved_state(saved: Dictionary) -> void:
	if _states.is_empty():
		return
	removed = false
	_transition(clampi(int(saved.get("state", 0)), 0, _states.size() - 1), false)
	previous_state = int(saved.get("previous_state", 0))
	hit_points = int(saved.get("health", _initial_health))
	elapsed = float(saved.get("elapsed", 0.0))
	visual_phase = NativeActorMotion.ticker_phase(float(saved.get("visual_phase", 0.0)))
	path_phase = NativeActorMotion.ticker_phase(float(saved.get("path_phase", 0.0)))
	visual_loops = int(saved.get("visual_loops", 0))
	path_loops = int(saved.get("path_loops", 0))
	persistent_activation = bool(saved.get("persistent_activation", persistent_activation))
	remember_removed_on_unload = bool(saved.get("remember_removed_on_unload", false))
	_last_damage_id = int(saved.get("last_damage_id", -1))
	_sample(false)
	var pose: Array = saved.get("transform", [])
	if pose.size() == 12:
		visual.global_transform = Transform3D(Basis(Vector3(pose[0], pose[1], pose[2]),
			Vector3(pose[3], pose[4], pose[5]), Vector3(pose[6], pose[7], pose[8])),
			Vector3(pose[9], pose[10], pose[11]))
	removed = bool(saved.get("removed", false))
	visual.visible = not removed and int(_states[state_index].get("visual_action", -1)) >= 0
	_sound_cues_played.clear()
	for key: String in saved.get("played_sound_cues", []):
		_sound_cues_played[key] = true
	_last_position = visual.global_position


func native_checkpoint_snapshot() -> Dictionary:
	# Native event 30 writes only this bool for records whose +0x264 is set.
	if native.get("state_machine", {}).get("persistent_checkpoint_item", false):
		return {"persistent_activation": persistent_activation}
	return {}


func reset_native_checkpoint(was_removed: bool, saved: Dictionary = {}) -> void:
	if _states.is_empty():
		return
	persistent_activation = bool(saved.get("persistent_activation", false))
	remember_removed_on_unload = false
	removed = was_removed or persistent_activation
	_stop_voices()
	_sound_cues_played.clear()
	_last_damage_id = -1
	if removed:
		visual.hide()
		if is_instance_valid(graph_colliders):
			graph_colliders.refresh()
		return
	# Child segments are re-created natively. Main-scene actors receive event31;
	# their handler does not serialize or restore HP.
	var source_group: int = int(native.get("source", {}).get("group", -1))
	var level_data: Variant = level.get("data")
	var main_group: int = int(level_data.get("main_group", -2)) if level_data is Dictionary else -2
	if source_group != main_group:
		hit_points = _initial_health
	visual.transform = _initial_transform
	previous_state = 0
	visual_phase = 0.0
	path_phase = 0.0
	_transition(0, true)
	_apply_initial_phases()
	_last_position = visual.global_position


func _apply_initial_phases() -> void:
	var machine: Dictionary = native.get("state_machine", {})
	# 0x4084a6 applies record+0x1c/+0x20 percentages AFTER state0 entry.
	visual_phase = NativeActorMotion.ticker_phase(float(machine.get("initial_visual_phase", 0.0)))
	path_phase = NativeActorMotion.ticker_phase(float(machine.get("initial_transform_phase", 0.0)))
	_sample(true)


func _physics_process(delta: float) -> void:
	if not scope_active or removed or _states.is_empty():
		return
	if delta > 1.0:
		delta = 0.0
	elapsed += delta
	var state: Dictionary = _states[state_index]
	if _flag(state, 4, "animate_transform"):
		var period: float = float(state.get("transform_period", 0.0))
		if period > 0.0:
			var next_phase: float = path_phase + delta / period * (-1.0 if _flag(state, 0x40, "reverse_transform") else 1.0)
			var wrapped: bool = next_phase > 1.0 or next_phase < 0.0
			path_phase = NativeActorMotion.ticker_phase(next_phase)
			if wrapped:
				path_loops += 1
				if path_loops >= int(state.get("transform_loop_limit", 0)) and _try_transition(8):
					return
		if is_instance_valid(motion):
			motion.apply_world_phase(path_phase)
	var action: Dictionary = motion.get_action_info(int(state.get("visual_action", -1))) if is_instance_valid(motion) else {}
	var step: float = 0.0
	if str(action.get("phase_domain", "seconds")) == "distance":
		var length: float = float(action.get("root_motion_length", 0.0))
		if length > 0.0:
			step = visual.global_position.distance_to(_last_position) / length
			if _flag(state, 0x40, "reverse_transform"):
				step = -step
	else:
		var period: float = float(state.get("visual_period", 0.0))
		# 0x408796: every time-driven period <=0 freezes, including 195 source states.
		if period > 0.0:
			step = delta / period * (-1.0 if _flag(state, 0x80, "reverse_visual") else 1.0)
	var next_visual: float = visual_phase + step
	var visual_wrapped: bool = next_visual > 1.0 or next_visual < 0.0
	visual_phase = NativeActorMotion.ticker_phase(next_visual)
	_last_position = visual.global_position
	_sample(false)
	_play_sound_cues(state)
	if visual_wrapped:
		visual_loops += 1
		if visual_loops >= int(state.get("visual_loop_limit", 0)) and _try_transition(16):
			return
	if elapsed > float(state.get("timeout_seconds", 0.0)):
		_try_transition(32)


func receive_event(event: int, param1: Variant = 0, param2: Variant = 0, sender: String = "") -> void:
	if removed or _transitioning or _states.is_empty():
		return
	match event:
		0x22000001:
			_try_transition(1)
		0x22000002:
			if _try_transition(256) and _last_transition_changed:
				var nodes: Dictionary = level.get("owner_nodes")
				if not sender.is_empty() and nodes.has(sender):
					# Native event02 copies the full sender pose AFTER state entry.
					visual.global_transform = (nodes[sender] as Node3D).global_transform
		0x22000003:
			if param1 is Dictionary:
				receive_native_damage(int(param1.get("amount", 0)), int(param1.get("attack_id", -1)), sender)
			elif param1 is float or param1 is int:
				var serial: int = int(param2.get("attack_id", -1)) if param2 is Dictionary else -1
				receive_native_damage(int(param1), serial, sender)
		0x22000004:
			_try_transition(512, int(param1) if param1 is float or param1 is int else 0)
	# Event12 belongs to Hugo/HealthBar; CSimpleStateActor does not handle it.


func receive_native_damage(amount: int, attack_id: int = -1, _sender: String = "") -> bool:
	if removed or _transitioning or _states.is_empty() or amount <= 0:
		return false
	if attack_id >= 0 and attack_id == _last_damage_id:
		return false
	if attack_id >= 0:
		_last_damage_id = attack_id
	hit_points -= amount
	if hit_points <= 0 and _has_condition(4):
		_try_transition(4)
	else:
		_try_transition(128)
	return true


func receive_logic_collision(own_node: Dictionary, _other_node: Dictionary, other: NativeGraphColliders) -> void:
	if removed or _transitioning or _states.is_empty():
		return
	var own_category: int = int(own_node.get("category", 0))
	var state: Dictionary = _states[state_index]
	var damage: int = int(state.get("contact_damage", 0))
	if (own_category & 8) != 0 and damage > 0 and is_instance_valid(other.player):
		level.call("damage_player", damage, visual.global_position,
			float(state.get("knockback_multiplier", 1.0)), int(native.get("state_machine", {}).get("damage_event", 0x22000003)))
	# Presence of mask2 selects this branch even if no argument matches; native
	# code does not fall back to mask64 in that case (0x408d5b / 0x40911c).
	if _has_condition(2):
		_try_transition(2, own_category, other.player)
	else:
		_try_transition(64, 0, other.player)


func snapshot() -> Dictionary:
	var pose: Transform3D = visual.global_transform
	return {"state": state_index, "previous_state": previous_state,
		"health": hit_points, "removed": removed, "elapsed": elapsed,
		"visual_phase": visual_phase, "path_phase": path_phase,
		"visual_loops": visual_loops, "path_loops": path_loops,
		"persistent_activation": persistent_activation, "last_damage_id": _last_damage_id,
		"remember_removed_on_unload": remember_removed_on_unload,
		"played_sound_cues": _sound_cues_played.keys(),
		"transform": [pose.basis.x.x, pose.basis.x.y, pose.basis.x.z,
			pose.basis.y.x, pose.basis.y.y, pose.basis.y.z,
			pose.basis.z.x, pose.basis.z.y, pose.basis.z.z,
			pose.origin.x, pose.origin.y, pose.origin.z]}


func _has_condition(condition: int) -> bool:
	for transition: Dictionary in _states[state_index].get("transitions", []):
		if (int(transition.mask) & condition) != 0:
			return true
	return false


func _try_transition(condition: int, argument: int = 0, checkpoint_target: Node3D = null) -> bool:
	_last_transition_changed = false
	for transition: Dictionary in _states[state_index].get("transitions", []):
		if (int(transition.mask) & condition) == 0:
			continue
		if condition == 2 and (int(transition.argument) & argument) == 0:
			continue
		if condition == 512 and int(transition.argument) != argument:
			continue
		var target: int = int(transition.next_state)
		if target == -2000:
			return true # First matching table entry ends the search, without a change.
		if target == -1:
			target = previous_state
		if target == -2:
			hit_points = _initial_health
			visual_phase = 0.0
			path_phase = 0.0
			target = 0
		_last_transition_changed = _transition(target, true, checkpoint_target)
		return true
	return false


func _transition(target: int, emit_events: bool, checkpoint_target: Node3D = null) -> bool:
	if target < 0 or target >= _states.size() or _transitioning:
		return false
	_transitioning = true
	previous_state = state_index
	state_index = target
	var state: Dictionary = _states[state_index]
	if emit_events and is_instance_valid(checkpoint_target) and _flag(state, 0x4000, "checkpoint_on_collision"):
		level.call("set_native_checkpoint", source_id, visual.global_position)
	if _flag(state, 1, "reset_visual_phase_on_entry"):
		visual_phase = 1.0 if _flag(state, 0x80, "reverse_visual") else 0.0
	if _flag(state, 2, "reset_transform_phase_on_entry"):
		path_phase = 1.0 if _flag(state, 0x40, "reverse_transform") else 0.0
	_sound_cues_played.clear()
	if _flag(state, 0x400, "stop_previous_sound_sequence"):
		_stop_voices()
	removed = _flag(state, 0x200, "remove_actor_on_entry")
	if _flag(state, 0x100, "save_world_state_on_entry"):
		persistent_activation = true
		if emit_events:
			level.call("save_native_world")
	if _flag(state, 0x2000, "remember_removed_on_scope_unload"):
		remember_removed_on_unload = true
	elapsed = 0.0
	visual_loops = 0
	path_loops = 0
	physical_flags = int(state.get("physics_mask", int(state.get("flags", 0)) & 0x18))
	var action: int = int(state.get("visual_action", -1))
	visual.visible = not removed and action >= 0
	if is_instance_valid(motion):
		motion.set_action_index(action)
	_sample(true)
	if is_instance_valid(graph_colliders):
		graph_colliders.refresh()
	_last_position = visual.global_position
	if emit_events:
		for message: Dictionary in state.get("entry_events", []):
			level.call("queue_native_event", message, source_id)
	_transitioning = false
	return true


func _sample(world: bool) -> void:
	if not is_instance_valid(motion) or _states.is_empty():
		return
	var state: Dictionary = _states[state_index]
	motion.sample_state(int(state.get("visual_action", -1)), visual_phase, path_phase,
		{"animate_transform": world and _flag(state, 4, "animate_transform")})


static func _flag(state: Dictionary, bit: int, name: String) -> bool:
	return bool(state.get(name, (int(state.get("flags", 0)) & bit) != 0))


func _play_sound_cues(state: Dictionary) -> void:
	if bool(state.get("suppress_sound_sequence_repeat", false)) and visual_loops > 0:
		return
	var cues: Array = state.get("sound_sequence", {}).get("cues", [])
	for index: int in range(cues.size()):
		var cue: Dictionary = cues[index]
		var key: String = "%d:%d:%d" % [state_index, visual_loops, index]
		if visual_phase < float(cue.get("normalized_phase", 0.0)) or _sound_cues_played.has(key):
			continue
		_sound_cues_played[key] = true
		var sound: Variant = cue.get("sound", {})
		var path: String = str(sound.get("path", "")) if sound is Dictionary else ""
		if not path.is_empty() and level.has_method("play_native_sound"):
			var pitch: float = randf_range(0.75, 1.25) if state.get("randomize_sound_pitch", false) else 1.0
			var voice: AudioStreamPlayer3D = level.call("play_native_sound", sound, visual.global_position, visual, pitch) as AudioStreamPlayer3D
			if is_instance_valid(voice):
				_voices.append(voice)
	for index: int in range(_voices.size() - 1, -1, -1):
		if not is_instance_valid(_voices[index]):
			_voices.remove_at(index)
	if _sound_cues_played.size() > 128:
		for key: String in _sound_cues_played.keys():
			if int(key.split(":")[1]) < visual_loops - 1:
				_sound_cues_played.erase(key)


func _stop_voices() -> void:
	for voice: AudioStreamPlayer3D in _voices:
		if is_instance_valid(voice):
			if voice.has_method("stop_source"):
				voice.call("stop_source")
			else:
				voice.stop()
			voice.queue_free()
	_voices.clear()
