extends SceneTree
## Scripted traversal of locally imported source scopes and real exit overlaps.
## This is not a manual or end-to-end gameplay/puzzle playthrough.
## Run: --headless --fixed-fps 60 --script res://tests/native_route_test.gd
## Optional user argument: --route-report=/absolute/path/report.json

class ObservedLevel extends OriginalLevel:
	var scope_events: Array = []
	var gate_events: Dictionary = {}

	func native_scope_loaded(group: int) -> void:
		scope_events.append(["load", group])
		super.native_scope_loaded(group)

	func native_scope_unloaded(group: int) -> void:
		scope_events.append(["unload", group])
		super.native_scope_unloaded(group)

	func set_native_owner_active(id: String, resident: bool, active: bool) -> void:
		gate_events[id] = [resident, active]
		super.set_native_owner_active(id, resident, active)


var checks: int = 0
var failures: Array[String] = []
var rows: Array[Dictionary] = []
var visited_segments: Dictionary = {}
var disabled_owner_checks: int = 0
var active_before_eviction: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	var gameplay: Dictionary = _json("res://assets/generated/gameplay_manifest.json")
	if catalog.is_empty() or gameplay.is_empty():
		push_error("NATIVE_ROUTE_TEST requires the locally imported original campaign")
		quit(2)
		return
	RemasterInput.configure()
	for title: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(title) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, title)
	_check(catalog.get("levels", []).size() == 8, "campaign has eight source chapters")
	for entry: Dictionary in catalog.get("levels", []):
		await _chapter(entry, gameplay)
	_check(visited_segments.size() == 60, "all sixty source child segments were resident")
	_check(active_before_eviction > 0, "eviction checks include previously active owners")
	var report: Dictionary = {
		"kind": "scripted_source_scope_traversal_and_exit_overlap",
		"manual_full_playthrough": false,
		"source_container_sha256": catalog.get("source_container_sha256", ""),
		"checks": checks, "failures": failures, "levels": rows,
		"unique_child_segments": visited_segments.size(),
		"disabled_owner_checks": disabled_owner_checks,
		"active_owners_before_eviction": active_before_eviction,
		"fixture": "Source adjacency drives request_group; source actor intervals select camera progress. Player and camera motion are paused during residency assertions. Real player physics is enabled for exit overlaps; source collision shapes and handlers are unchanged.",
		"limits": "Does not prove continuous walkability, enemy encounters, puzzle solutions, movie playback, native CD latency or a complete human playthrough."
	}
	var report_path: String = "user://native_route_test.json"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--route-report="):
			report_path = argument.trim_prefix("--route-report=")
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		push_error("Could not write route report: " + report_path)
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("NATIVE_ROUTE_TEST checks=%d failures=%d chapters=%d child_segments=%d exits=%d report=%s" % [
		checks, failures.size(), rows.size(), visited_segments.size(), _finished_count(), report_path])
	quit(0 if failures.is_empty() else 1)


func _chapter(entry: Dictionary, gameplay: Dictionary) -> void:
	var label: String = str(entry.id)
	var failures_before: int = failures.size()
	var level := ObservedLevel.new()
	level.entry = entry
	level.data = _json("res://assets/generated/" + str(entry.manifest_path))
	level.gameplay = gameplay.get("levels", {}).get(label, {})
	level.native_rules = gameplay.get("native_rules", {})
	root.add_child(level)
	if not _check(level._ready_ok and is_instance_valid(level.scopes), label + " initialized with native scopes"):
		level.queue_free()
		await process_frame
		return
	# The fixture drives discrete source requests, not an invented camera route.
	# Keep the player at its source spawn while remote segments are inspected.
	level.scopes.suspended = true
	level.player.set_physics_process(false)
	level.player.controls_enabled = false
	level.camera_rig.set_physics_process(false)
	level.camera_rig.controls_enabled = false
	var policy: Dictionary = level.scopes.policy
	var segments: Array = policy.get("segments", [])
	var by_group: Dictionary = {}
	for segment: Dictionary in segments:
		by_group[int(segment.group)] = segment
	var order: Array[int] = []
	var initial: Array[int] = _group_ids(policy.get("initial_segment_groups", []))
	_check(initial.size() == 1 and level.scopes.resident_groups == initial, label + " starts with only the first source segment")
	_check(level.scopes.is_group_resident(0) and level.scopes.is_group_resident(int(entry.main_group)), label + " global and main scopes remain resident after JSON decoding")
	_check(int(policy.get("max_resident_segments", 0)) == 2, label + " authored resident cap is two")
	if initial.is_empty() or not by_group.has(initial[0]):
		_check(false, label + " has a valid initial adjacency entry")
		level.queue_free()
		await process_frame
		return
	var cursor: int = initial[0]
	while by_group.has(cursor) and not order.has(cursor):
		order.append(cursor)
		var next: Variant = by_group[cursor].get("next_group")
		if next == null:
			break
		_check(by_group.has(int(next)) and int(by_group[int(next)].get("previous_group", -1)) == cursor, label + " source adjacency is reciprocal at " + str(cursor))
		cursor = int(next)
	_check(order.size() == segments.size(), label + " authored adjacency reaches every child segment")
	var row: Dictionary = {"id": label, "groups": order.duplicate(), "steps": [], "checkpoint": {}, "exit": {}}
	_mark_residents(level)
	await _ticks(2)
	_check_all_nonresident(level, label + " initial")
	var saved_groups: Array[int] = []
	var save_at: int = maxi(1, order.size() / 2)
	for i: int in range(1, order.size()):
		await _request(level, order[i], row, "forward")
		if i == save_at:
			level.save_native_world()
			saved_groups = level.scopes.resident_groups.duplicate()
			_check(_group_ids(level._checkpoint_state.get("resident_groups", [])) == saved_groups, label + " native world save captures resident membership")
	for i: int in range(order.size() - 2, -1, -1):
		await _request(level, order[i], row, "return")
	_check(level.scopes.resident_groups == [order[0], order[1]], label + " return reaches the first two source segments")
	if not saved_groups.is_empty():
		var before: Array[int] = level.scopes.resident_groups.duplicate()
		level.scope_events.clear()
		level.restore_native_world()
		var expected_events: Array = []
		for group: int in before:
			expected_events.append(["unload", group])
		for group: int in saved_groups:
			expected_events.append(["load", group])
		_check(level.scope_events == expected_events, label + " checkpoint reloads both old scopes before restoring the saved scopes")
		_check(level.scopes.resident_groups == saved_groups, label + " checkpoint restores exact membership")
		row.checkpoint = {"saved": saved_groups, "before_restore": before, "after_restore": level.scopes.resident_groups.duplicate(), "callbacks": level.scope_events.duplicate(true)}
		# respawn changes controls, but this residency fixture still holds movement.
		level.player.controls_enabled = false
		await _ticks(3)
		_check_all_nonresident(level, label + " checkpoint")
	row.exit = await _exit_overlap(level, order, by_group, row)
	row["failures"] = failures.size() - failures_before
	rows.append(row)
	print("NATIVE_ROUTE_CHAPTER ", JSON.stringify({"id": label, "segments": order.size(), "steps": row.steps.size(), "exit": row.exit, "failures": row.failures}))
	level.queue_free()
	await process_frame
	await process_frame


func _request(level: ObservedLevel, group: int, row: Dictionary, direction: String) -> void:
	var before: Array[int] = level.scopes.resident_groups.duplicate()
	if group in before:
		level.scope_events.clear()
		_check(not level.scopes.request_group(group) and level.scope_events.is_empty(), str(level.entry.id) + " resident request is idempotent " + str(group))
		return
	var expected: Array[int] = before.duplicate()
	var evicted: int = -1
	if expected.size() == 2:
		# Source adjacency is ordered by container offsets. Do not infer a third
		# resident or use an all-groups-loaded fallback in this integration gate.
		evicted = expected[-1] if group < expected[0] else expected[0]
		expected.erase(evicted)
		_set_source_progress(level, evicted)
		await _ticks(2)
		for id: String in level.scopes.owner_groups:
			if int(level.scopes.owner_groups[id]) == evicted and level.scopes.is_owner_active(id):
				active_before_eviction += 1
	expected.append(group)
	expected.sort()
	level.scope_events.clear()
	_check(level.scopes.request_group(group), str(level.entry.id) + " requests adjacent group " + str(group))
	var expected_events: Array = []
	if evicted >= 0:
		expected_events.append(["unload", evicted])
	expected_events.append(["load", group])
	_check(level.scope_events == expected_events, str(level.entry.id) + " unload precedes load " + str(group))
	_check(level.scopes.resident_groups == expected and level.scopes.resident_groups.size() <= 2, str(level.entry.id) + " exact bounded resident window " + str(group))
	var frozen: Dictionary = _group_clocks(level, evicted) if evicted >= 0 else {}
	_set_source_progress(level, group)
	await _ticks(3)
	if evicted >= 0:
		_check_group_disabled(level, evicted, str(level.entry.id) + " " + direction)
		_check(_group_clocks(level, evicted) == frozen, str(level.entry.id) + " unloaded group clocks and transforms remain frozen " + str(evicted))
	_check(level.scopes.is_group_resident(0) and level.scopes.is_group_resident(int(level.entry.main_group)), str(level.entry.id) + " persistent scopes survive " + str(group))
	_mark_residents(level)
	row.steps.append({"direction": direction, "requested": group, "evicted": evicted, "resident": level.scopes.resident_groups.duplicate(), "callbacks": level.scope_events.duplicate(true), "camera_progress": level.scopes.camera_progress})


func _set_source_progress(level: ObservedLevel, group: int) -> void:
	# Exercise authored active intervals of the segment being inspected. These
	# are fixture inputs; they do not claim a simulated continuous camera path.
	var ranges: Array[Dictionary] = []
	var candidates: Array[int] = [0, 992]
	for id: String in level.scopes.owner_groups:
		if int(level.scopes.owner_groups[id]) != group:
			continue
		var span: Dictionary = level.scopes.policy.get("actor_ranges", {}).get(id, {})
		if span.is_empty() or int(span.minimum) > int(span.maximum):
			continue
		ranges.append(span)
		candidates.append(clampi(int(span.minimum), 0, 992))
		candidates.append(clampi(int(span.maximum), 0, 992))
		candidates.append(clampi((int(span.minimum) + int(span.maximum)) / 2, 0, 992))
	var best: int = 0
	var score: int = -1
	for progress: int in candidates:
		var count: int = 0
		for span: Dictionary in ranges:
			if progress >= int(span.minimum) and progress <= int(span.maximum):
				count += 1
		if count > score:
			best = progress
			score = count
	level.camera_rig.native_phase = float(best) / 992.0
	level.scopes.camera_progress = best
	level.scopes.refresh_gates()


func _group_clocks(level: ObservedLevel, group: int) -> Dictionary:
	var clocks: Dictionary = {}
	for id: String in level.scopes.owner_groups:
		if int(level.scopes.owner_groups[id]) != group:
			continue
		var values: Array = []
		if level.state_actors.has(id):
			var actor: NativeStateActor = level.state_actors[id]
			values.append([actor.state_index, actor.elapsed, actor.visual_phase, actor.path_phase])
		if level.actor_motions.has(id):
			var motion: NativeActorMotion = level.actor_motions[id]
			values.append([motion.active_action, motion.sampled_visual_phase, motion.sampled_path_phase])
		if level.owner_nodes.has(id):
			values.append((level.owner_nodes[id] as Node3D).global_transform)
		clocks[id] = values
	return clocks


func _check_group_disabled(level: ObservedLevel, group: int, label: String) -> void:
	var issues: Array[String] = []
	var owner_count: int = 0
	for id: String in level.scopes.owner_groups:
		if int(level.scopes.owner_groups[id]) != group:
			continue
		owner_count += 1
		if level.scopes.is_owner_resident(id) or level.scopes.is_owner_active(id) or level.gate_events.get(id, []) != [false, false]:
			issues.append(id + " residence/gate callback")
		if level._scope_wrappers.has(id) and (level._scope_wrappers[id] as Node3D).visible:
			issues.append(id + " visible wrapper")
		if level.owner_nodes.has(id):
			var visual: Node3D = level.owner_nodes[id]
			if visual.is_visible_in_tree():
				issues.append(id + " visible owner")
			for body: Node in visual.find_children("*", "PhysicsBody3D", true, false):
				if (body as PhysicsBody3D).collision_layer != 0:
					issues.append(id + " active physical body " + str(body.name))
		if level.actor_motions.has(id) and (level.actor_motions[id] as NativeActorMotion).is_physics_processing():
			issues.append(id + " motion update")
		if level.state_actors.has(id):
			var actor: NativeStateActor = level.state_actors[id]
			if actor.scope_resident or actor.scope_active or actor.is_physics_processing():
				issues.append(id + " state update")
			if is_instance_valid(actor.graph_colliders) and (actor.graph_colliders.enabled or not actor.graph_colliders.active_boxes.is_empty()):
				issues.append(id + " state logic collision")
		if level.pickup_graphs.has(id):
			var graph: NativeGraphColliders = level.pickup_graphs[id]
			if graph.enabled or not graph.active_boxes.is_empty():
				issues.append(id + " pickup logic collision")
		if level.speakers.has(id) and (level.speakers[id] as Node).is_physics_processing():
			issues.append(id + " speaker update")
		for area: Area3D in level._owner_areas.get(id, []):
			if area.monitoring:
				issues.append(id + " Area3D monitoring")
	disabled_owner_checks += owner_count
	_check(owner_count > 0, label + " unloaded source group has owners " + str(group))
	_check(issues.is_empty(), label + " unloaded group %d disables rendering, updates and collision: %s" % [group, "; ".join(issues)])


func _check_all_nonresident(level: ObservedLevel, label: String) -> void:
	for segment: Dictionary in level.scopes.policy.get("segments", []):
		var group: int = int(segment.group)
		if not level.scopes.is_group_resident(group):
			_check_group_disabled(level, group, label)


func _exit_overlap(level: ObservedLevel, order: Array[int], by_group: Dictionary, row: Dictionary) -> Dictionary:
	var label: String = str(level.entry.id)
	var exits: Array[String] = []
	for id: String in level.gameplay.get("owners", {}):
		if int(level.gameplay.owners[id].get("type", 0)) == 10602:
			exits.append(id)
	if not _check(exits.size() == 1, label + " has one recovered native end trigger"):
		return {"finished": false, "reason": "missing or ambiguous native exit"}
	var exit_id: String = exits[0]
	var native: Dictionary = level.gameplay.owners[exit_id]
	var exit_group: int = int(native.source.group)
	# Move the residency window through source neighbors from its checkpoint.
	var cursor: int = level.scopes.resident_groups[-1]
	while not level.scopes.is_group_resident(exit_group):
		var direction: String = "next_group" if order.find(exit_group) > order.find(cursor) else "previous_group"
		var next: Variant = by_group[cursor].get(direction)
		if next == null:
			_check(false, label + " exit group is reachable through source adjacency")
			return {"finished": false, "id": exit_id, "reason": "broken adjacency"}
		cursor = int(next)
		await _request(level, cursor, row, "exit_route")
	_set_source_progress(level, exit_group)
	await _ticks(3)
	_check(level.scopes.is_owner_resident(exit_id) and level.scopes.is_owner_active(exit_id), label + " native exit owner is resident and active")
	var areas: Array = level._owner_areas.get(exit_id, [])
	if not _check(areas.size() == 1 and areas[0] is Area3D, label + " original exit Area3D exists"):
		return {"finished": false, "id": exit_id, "reason": "no source area"}
	var area: Area3D = areas[0]
	var shape: CollisionShape3D
	for child: Node in area.get_children():
		if child is CollisionShape3D:
			shape = child
	if not _check(is_instance_valid(shape) and shape.shape is BoxShape3D, label + " original exit uses its native box"):
		return {"finished": false, "id": exit_id, "reason": "no source box"}
	var low: Vector3 = _vector(native.bounds.world_min)
	var high: Vector3 = _vector(native.bounds.world_max)
	var native_bounds := AABB(low, high - low)
	var box_size: Vector3 = (shape.shape as BoxShape3D).size
	var shape_bounds: AABB = shape.global_transform * AABB(-box_size * 0.5, box_size)
	_check(shape_bounds.position.distance_to(low) < 0.002 and shape_bounds.end.distance_to(high) < 0.002, label + " runtime exit shape matches recovered native bounds")
	_check(area.monitoring and (area.collision_mask & level.player.collision_layer) != 0, label + " source exit monitoring and body mask are enabled")
	_check(not level.completed, label + " chapter has not been completed by the fixture")
	var center: Vector3 = native_bounds.get_center()
	var feet: Vector3 = center - Vector3.UP * level.player.character_height * 0.5
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(center.x, high.y + level.player.character_height + 1.0, center.z),
		Vector3(center.x, low.y - level.player.character_height * 2.0 - 1.0, center.z), 1,
		[level.player.get_rid()])
	var floor_hit: Dictionary = level.get_world_3d().direct_space_state.intersect_ray(query)
	var placement: String = "inside_native_exit_volume"
	if not floor_hit.is_empty():
		var grounded_feet: Vector3 = (floor_hit.position as Vector3) + Vector3.UP * 0.05
		if grounded_feet.y < high.y - 0.02 and grounded_feet.y + level.player.character_height > low.y + 0.02:
			feet = grounded_feet
			placement = "source_collision_floor_inside_exit"
	# Move out first, so the test requires a fresh physics body_entered signal.
	level.player.global_position = feet + Vector3.RIGHT * (native_bounds.size.x + level.player.character_height * 3.0)
	level.player.velocity = Vector3.ZERO
	await _ticks(3)
	_check(not area.overlaps_body(level.player), label + " exit is clear before entry")
	var observations: Dictionary = {"body_entered": 0, "level_finished": 0}
	area.body_entered.connect(func(body: Node3D) -> void:
		if body == level.player:
			observations.body_entered += 1)
	level.level_finished.connect(func() -> void: observations.level_finished += 1)
	level.player.global_position = feet
	level.player.velocity = Vector3.ZERO
	level.player.set_physics_process(true)
	for i: int in range(12):
		await _ticks(1)
		if level.completed:
			break
	_check(observations.body_entered == 1, label + " real physics overlap enters the native exit")
	_check(level.completed and observations.level_finished == 1 and level.hud.modal.visible, label + " native exit handler completes the chapter")
	await _ticks(3)
	_check(observations.level_finished == 1, label + " staying in the exit does not finish twice")
	return {"id": exit_id, "source_group": exit_group, "resident_groups": level.scopes.resident_groups.duplicate(),
		"source_world_bounds": [native.bounds.world_min, native.bounds.world_max], "placement": placement,
		"requested_feet": _array(feet), "settled_feet": _array(level.player.global_position),
		"body_entered": observations.body_entered, "level_finished": observations.level_finished,
		"finished": level.completed, "diamonds": level.diamonds, "source_total": level.total_diamonds}


func _mark_residents(level: ObservedLevel) -> void:
	for group: int in level.scopes.resident_groups:
		visited_segments[group] = true


func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame


func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
		push_error("NATIVE_ROUTE_CHECK_FAILED " + label)
	return value


func _finished_count() -> int:
	var result: int = 0
	for row: Dictionary in rows:
		if row.get("exit", {}).get("finished", false):
			result += 1
	return result


static func _group_ids(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value: Variant in values:
		result.append(int(value))
	return result


static func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
