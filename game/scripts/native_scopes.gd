class_name NativeScopes
extends Node
## Native settled two-segment residency and inclusive camera-progress gates.
## Resources remain prebuilt in memory; unloaded owners cannot update/render/collide.
## This does not invent the duration of the original asynchronous CD reads.

var policy: Dictionary
var owner_groups: Dictionary = {}
var level: Node3D
var resident_groups: Array[int] = []
var camera_progress: int = 0
var suspended: bool = false
var _offsets: Dictionary = {}
var _active: Dictionary = {}
var _resident: Dictionary = {}
var _started: bool = false


func prepare(saved: Dictionary = {}) -> void:
	process_physics_priority = 50 # Original phase2 follows actor motion and camera tracking.
	_offsets.clear()
	for segment: Dictionary in policy.get("segments", []):
		_offsets[int(segment.group)] = int(segment.source_container_offset)
	resident_groups.clear()
	var initial: Array = saved.get("resident_groups", policy.get("initial_segment_groups", []))
	for group: Variant in initial:
		if _offsets.has(int(group)) and not resident_groups.has(int(group)) and resident_groups.size() < 2:
			resident_groups.append(int(group))
	if resident_groups.is_empty() and not _offsets.is_empty():
		for group: Variant in policy.get("initial_segment_groups", []):
			resident_groups.append(int(group))
	_sort_residents()


func start() -> void:
	_started = true
	_update_progress()
	refresh_gates(true)


func is_group_resident(group: int) -> bool:
	# JSON stores numbers as floats; Array.has is type-sensitive in Godot.
	for persistent: Variant in policy.get("persistent_groups", [0, int(policy.get("main_group", -1))]):
		if int(persistent) == group:
			return true
	return group in resident_groups


func is_owner_resident(id: String) -> bool:
	return not owner_groups.has(id) or is_group_resident(int(owner_groups[id]))


func is_owner_active(id: String) -> bool:
	if not is_owner_resident(id):
		return false
	var range_info: Dictionary = policy.get("actor_ranges", {}).get(id, {})
	return range_info.is_empty() or (camera_progress >= int(range_info.minimum) and camera_progress <= int(range_info.maximum))


func snapshot() -> Dictionary:
	return {"resident_groups": resident_groups.duplicate()}


func _physics_process(_delta: float) -> void:
	if not _started or suspended or not is_instance_valid(level):
		return
	_update_progress()
	var rig: Node3D = level.get("camera_rig") as Node3D
	var camera: Camera3D = rig.get("camera") as Camera3D if is_instance_valid(rig) else null
	if is_instance_valid(camera):
		evaluate_planes(camera.global_position)
	refresh_gates()


func evaluate_planes(camera_position: Vector3) -> void:
	# No AABB proximity gate: every resident source plane is tested each phase2.
	for trigger: Dictionary in policy.get("triggers", []):
		if not is_group_resident(int(trigger.group)) or not is_owner_active(str(trigger.id)):
			continue
		var origin: Vector3 = _vector(trigger.origin)
		var normal: Vector3 = _vector(trigger.normal)
		var requested: Variant = trigger.previous_group if (camera_position - origin).dot(normal) < 0.0 else trigger.next_group
		if requested != null:
			request_group(int(requested))


func request_group(group: int) -> bool:
	if not _offsets.has(group) or group in resident_groups:
		return false
	var evicted: int = -1
	if resident_groups.size() == 2:
		if int(_offsets[group]) < int(_offsets[resident_groups[0]]):
			evicted = resident_groups[-1]
		elif int(_offsets[group]) > int(_offsets[resident_groups[-1]]):
			evicted = resident_groups[0]
		else:
			# Authored adjacency never requests an interior missing segment.
			return false
	if evicted >= 0:
		_unload(evicted)
	resident_groups.append(group)
	_sort_residents()
	if is_instance_valid(level) and level.has_method("native_scope_loaded"):
		level.call("native_scope_loaded", group)
	refresh_gates()
	return true


func restore_membership(saved: Dictionary) -> void:
	# Rollback unloads even segments that remain in the saved set, then rebuilds
	# their actor state. The caller restores native removed-ID data beforehand.
	for group: int in resident_groups.duplicate():
		_unload(group)
	var desired: Array = saved.get("resident_groups", policy.get("initial_segment_groups", []))
	if desired.is_empty():
		desired = policy.get("initial_segment_groups", [])
	for value: Variant in desired:
		var group: int = int(value)
		if not _offsets.has(group) or group in resident_groups or resident_groups.size() >= 2:
			continue
		resident_groups.append(group)
		_sort_residents()
		if is_instance_valid(level) and level.has_method("native_scope_loaded"):
			level.call("native_scope_loaded", group)
	_update_progress()
	refresh_gates(true)


func refresh_gates(force: bool = false) -> void:
	for id: String in owner_groups:
		var resident: bool = is_owner_resident(id)
		var active: bool = is_owner_active(id)
		if force or _active.get(id) != active or _resident.get(id) != resident:
			_active[id] = active
			_resident[id] = resident
			if is_instance_valid(level) and level.has_method("set_native_owner_active"):
				level.call("set_native_owner_active", id, resident, active)


func _unload(group: int) -> void:
	if is_instance_valid(level) and level.has_method("native_scope_unloaded"):
		level.call("native_scope_unloaded", group)
	resident_groups.erase(group)
	refresh_gates()


func _update_progress() -> void:
	var rig: Node = level.get("camera_rig") as Node if is_instance_valid(level) else null
	if is_instance_valid(rig):
		camera_progress = int(float(rig.get("native_phase")) * float(policy.get("actor_progress", {}).get("phase_multiplier", 992.0)))


func _sort_residents() -> void:
	resident_groups.sort_custom(func(a: int, b: int) -> bool: return int(_offsets[a]) < int(_offsets[b]))


static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
