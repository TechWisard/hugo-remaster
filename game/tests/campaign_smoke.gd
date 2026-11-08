extends SceneTree
## Opt-in integration checks against locally imported original data.
## Run with --headless --fixed-fps 60 --script res://tests/campaign_smoke.gd.

const LevelScript = preload("res://scripts/original_level.gd")
var failures: Array[String] = []
var checks: int = 0
var rows: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("SKIP original campaign assets are not installed")
		quit(0)
		return
	for title: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(title) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, title)
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	var gameplay: Dictionary = _json("res://assets/generated/gameplay_manifest.json")
	_check(catalog.get("levels", []).size() == 8, "eight recovered chapters")
	for entry: Dictionary in catalog.get("levels", []):
		var level: OriginalLevel = LevelScript.new()
		level.entry = entry
		level.data = _json("res://assets/generated/" + str(entry.manifest_path))
		level.gameplay = gameplay.levels[entry.id]
		level.native_rules = gameplay.get("native_rules", {})
		root.add_child(level)
		await _ticks(40)
		_check(level._ready_ok, str(entry.id) + " initialized")
		_check(level._collision_count > 0, str(entry.id) + " native collision bodies")
		_check(level.camera_rig.source_ready, str(entry.id) + " native camera paths")
		_check(level.player.global_position.is_finite(), str(entry.id) + " finite player")
		_check(level.player.global_position.distance_to(level.spawn_point) < 8.0, str(entry.id) + " spawn stays near source")
		_check(level.player.is_on_floor(), str(entry.id) + " source spawn has floor")
		_check(level.max_health == 10 and level.lives == 4, str(entry.id) + " native initial stats")
		_check(level.total_diamonds == int(level.gameplay.health_bar.diamonds_total_native), str(entry.id) + " original diamond total")
		_check(level.state_actors.size() == level.gameplay.actors.size(), str(entry.id) + " every state actor instantiated")
		_check(level.pickup_graphs.size() == level.gameplay.pickups.size(), str(entry.id) + " every pickup uses source boxes")
		_check(level.scopes != null and level.scopes.resident_groups.size() > 0 and level.scopes.resident_groups.size() <= 2, str(entry.id) + " native segment residency is bounded")
		_check(level.player.using_native_movement, str(entry.id) + " source movement is enabled")
		var action_binding_counts: Dictionary = _test_action_bindings(level)
		rows.append({"id": entry.id, "spawn": _array(level.spawn_point),
			"settled": _array(level.player.global_position), "on_floor": level.player.is_on_floor(),
			"collision_bodies": level._collision_count, "actors": level.state_actors.size(),
			"pickups": level.pickup_areas.size(), "diamonds": level.total_diamonds,
			"action_binding_checks": action_binding_counts})
		if str(entry.id) == "g006":
			await _test_beach(level)
		level.queue_free()
		await process_frame
		await process_frame
	var report: Dictionary = {"checks": checks, "failures": failures, "levels": rows}
	var output := FileAccess.open("user://campaign_smoke_result.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("CAMPAIGN_SMOKE ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func _test_action_bindings(level: OriginalLevel) -> Dictionary:
	var total_actions: int = 0
	var total_motions: int = 0
	for id: String in level.actor_motions:
		var motion: NativeActorMotion = level.actor_motions[id]
		var actions: Array = motion.source.get("actions", []) as Array
		total_motions += 1
		total_actions += actions.size()
		_check(motion.binding_error.is_empty(), id + " has no unresolved action binding")
		_check(motion._actions.size() == actions.size(), id + " binds every authored action")
		var initial_action: int = motion.active_action
		var owner_visible: bool = motion.owner_visual.visible
		var bindings_valid: bool = motion.binding_error.is_empty()
		var distinct_nodes: Dictionary = {}
		for action: Dictionary in actions:
			var index: int = int(action.index)
			var node: Node3D = motion._actions.get(index, {}).get("node") as Node3D
			var valid: bool = is_instance_valid(node)
			_check(valid, id + " action%d resolves an actual imported Node3D" % index)
			if not valid:
				bindings_valid = false
				continue
			_check(node == motion.owner_visual.get_node_or_null(str(action.node_name)),
				id + " action%d resolves the exact authored path" % index)
			_check(not distinct_nodes.has(node.get_instance_id()), id + " action%d owns a distinct node" % index)
			distinct_nodes[node.get_instance_id()] = true
			# .visible is local: source residency/range gates live on the separate
			# scope wrapper and must not turn this into an is_visible_in_tree test.
			_check(node.visible == (index == initial_action), id + " only its current action is locally visible")
		if not bindings_valid:
			continue
		# Exercise every imported action synchronously, without advancing the VM,
		# transforms, physics or residency, then put the previous selection back.
		for action: Dictionary in actions:
			var index: int = int(action.index)
			motion.set_action_index(index)
			_check(_only_action_visible(motion, index), id + " selects exactly action%d" % index)
		motion.set_action_index(-1)
		_check(_only_action_visible(motion, -1), id + " negative visual action hides all action groups")
		motion.set_action_index(initial_action)
		_check(_only_action_visible(motion, initial_action), id + " restores its native active action")
		_check(motion.owner_visual.visible == owner_visible, id + " action switching preserves owner/scope visibility")
	return {"motions": total_motions, "actions": total_actions}


func _only_action_visible(motion: NativeActorMotion, selected: int) -> bool:
	for key: int in motion._actions:
		var node: Node3D = motion._actions[key].get("node") as Node3D
		if not is_instance_valid(node) or node.visible != (key == selected):
			return false
	return true


func _test_beach(level: OriginalLevel) -> void:
	# Freeze residency while fixtures move the player outside the authored camera route.
	level.scopes.suspended = true
	var native_owners: Dictionary = level.gameplay.owners
	var pickup_id: String = ""
	for id: String in level.pickup_areas:
		var pickup: Dictionary = native_owners[id].get("pickup", {})
		if int(pickup.get("diamonds", 0)) > 0 and not pickup.get("starts_inactive", false) and level.scopes.is_owner_active(id):
			pickup_id = id
			break
	_check(not pickup_id.is_empty(), "beach has an active diamond")
	if not pickup_id.is_empty():
		var area: Area3D = level.pickup_areas[pickup_id]
		var graph: NativeGraphColliders = level.pickup_graphs[pickup_id]
		graph.refresh()
		_check(not graph.active_boxes.is_empty(), "fixture uses an active original pickup collider")
		var center: Vector3 = graph.active_boxes[0].center
		var query := PhysicsRayQueryParameters3D.create(center + Vector3.UP * 0.5,
			center - Vector3.UP * level.player.character_height * 2.0, 1, [level.player.get_rid()])
		var ground: Dictionary = level.get_world_3d().direct_space_state.intersect_ray(query)
		_check(not ground.is_empty(), "pickup fixture has a native floor")
		# A midpoint of the enclosing render AABB can place the player inside
		# terrain. Stand on the actual native floor under the current graph box.
		level.player.global_position = ground.position + Vector3.UP * 0.05 if not ground.is_empty() else center
		level.player.velocity = Vector3.ZERO
		await _ticks(3)
		_check(level._collecting.has(pickup_id), "source overlap starts pickup animation")
		await _ticks(40)
		_check(level.collected.has(pickup_id), "real overlap collects a diamond")
		var old_count: int = level.diamonds
		_check(not level.collect_pickup(pickup_id, native_owners[pickup_id], area), "pickup is not awarded twice")
		_check(level.diamonds == old_count, "duplicate pickup keeps count")
		level.save_native_world()
		var next_id: String = ""
		for id: String in level.pickup_areas:
			if id != pickup_id and int(native_owners[id].get("pickup", {}).get("diamonds", 0)) > 0 and not native_owners[id].get("pickup", {}).get("starts_inactive", false) and level.scopes.is_owner_active(id):
				next_id = id
				break
		if not next_id.is_empty():
			level.collect_pickup(next_id, native_owners[next_id], level.pickup_areas[next_id])
			await _ticks(40)
			level.restore_native_world()
			await _ticks(2)
			_check(level.collected.has(pickup_id) and not level.collected.has(next_id), "checkpoint restores the removed-item set")
			_check(level.diamonds == old_count, "checkpoint rolls back the diamond counter")
	var hidden_id: String = ""
	for id: String in level.pickup_areas:
		if native_owners[id].get("pickup", {}).get("starts_inactive", false):
			hidden_id = id
			break
	if not hidden_id.is_empty():
		var group: int = int(native_owners[hidden_id].source.group)
		if not level.scopes.is_owner_resident(hidden_id):
			level.scopes.restore_membership({"resident_groups": [group]})
		var range_info: Dictionary = level.scopes.policy.get("actor_ranges", {}).get(hidden_id, {})
		level.scopes.camera_progress = int(range_info.get("minimum", 0))
		level.scopes.refresh_gates()
		level.queue_native_event({"target": hidden_id, "event": 0x22000002, "param1": 0, "param2": 0})
		await _ticks(2)
		_check((level.owner_nodes[hidden_id] as Node3D).visible, "native event activates a hidden power-up")
		_check((level.pickup_graphs[hidden_id] as NativeGraphColliders).enabled, "activated power-up becomes collectible")
	level.finish_level()
	_check(level.completed and level.hud.modal.visible and not level.player.controls_enabled, "chapter completion opens the continuation")


func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("CHECK FAILED: " + message)


func _json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
