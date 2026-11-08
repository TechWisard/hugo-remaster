extends SceneTree
## Opt-in integration test with the imported original campaign.
## Exercises a real moving CPlatform and rollback to its chapter checkpoint.
## Run with --headless --fixed-fps 60 --script res://tests/native_platform_test.gd.

const LevelScript = preload("res://scripts/original_level.gd")
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary

func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame

func _run() -> void:
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("SKIP original campaign assets are not installed")
		quit(0)
		return
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	var gameplay: Dictionary = _json("res://assets/generated/gameplay_manifest.json")
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	var level_id: String = arguments[0] if arguments.size() > 0 else "g036"
	var platform_id: String = arguments[1] if arguments.size() > 1 else "g044_o0128_t10402"
	var entry: Dictionary = {}
	for candidate: Dictionary in catalog.levels:
		if str(candidate.id) == level_id:
			entry = candidate
			break
	var level: OriginalLevel = LevelScript.new() as OriginalLevel
	level.entry = entry
	level.data = _json("res://assets/generated/" + str(entry.manifest_path))
	level.gameplay = gameplay.levels[entry.id]
	level.native_rules = gameplay.native_rules
	root.add_child(level)
	_check(level._ready_ok, str(entry.id) + " actual exported chapter loads")
	level.set_physics_process(false)
	level.scopes.suspended = true
	var group: int = int(level.gameplay.owners[platform_id].source.group)
	level.scopes.restore_membership({"resident_groups": [group]})
	var id: String = platform_id
	var visual: Node3D = level.owner_nodes[id]
	var body: AnimatableBody3D = visual.get_node("NativePlatform") as AnimatableBody3D
	var shape: CollisionShape3D = body.get_child(0) as CollisionShape3D
	var motion: NativeActorMotion = level.actor_motions[id]
	var player: HugoPlayer = level.player
	if level_id == "g036":
		level.checkpoint_id = "g044_o0130_t10300"
		level.save_native_world()
	_check(body != null and motion != null and player.using_native_movement, "actual CPlatform body/motion/native player wiring")
	_check(body.get_parent() == visual and not body.sync_to_physics, "actual parent-child AnimatableBody hierarchy")
	# Keep the source platform hierarchy, shape, path and player unchanged;
	# isolate that contact from unrelated traps and terrain in the same chapter.
	for actor: NativeStateActor in level.state_actors.values():
		actor.set_native_scope(false, false)
	for graph: NativeGraphColliders in level.pickup_graphs.values():
		graph.enabled = false
	level.player_graph.enabled = false
	for other_motion: NativeActorMotion in level.actor_motions.values():
		other_motion.set_physics_process(false)
	for speaker: NativeSpeaker in level.speakers.values():
		speaker.set_physics_process(false)
		speaker.reset_native_world()
	level.effects.set_physics_process(false)
	for node: Node in level.find_children("*", "PhysicsBody3D", true, false):
		if node != body and node != player:
			(node as PhysicsBody3D).collision_layer = 0
	body.collision_layer = 1
	visual.show()
	player.controls_enabled = false
	player.set_native_surface()
	var box: BoxShape3D = shape.shape as BoxShape3D
	var local_top: Vector3 = shape.position + Vector3.UP * box.size.y * 0.5
	player.global_position = body.global_transform * local_top + Vector3.UP * 0.05
	player.velocity = Vector3.ZERO
	level.camera_rig.snap_to_target()
	await _ticks(30)
	_check(player.is_on_floor(), "player settles on the real source platform")
	var start_player: Vector3 = player.global_position
	var start_platform: Vector3 = body.global_position
	var start_relative: Vector3 = body.to_local(player.global_position)
	motion.set_physics_process(true)
	var samples: Array[Dictionary] = []
	var grounded_frames: int = 0
	var maximum_horizontal_error: float = 0.0
	var maximum_vertical_error: float = 0.0
	var maximum_platform_speed: float = 0.0
	for i: int in range(120):
		await _ticks(1)
		var relative: Vector3 = body.to_local(player.global_position)
		var difference: Vector3 = relative - start_relative
		maximum_horizontal_error = maxf(maximum_horizontal_error, Vector2(difference.x, difference.z).length())
		maximum_vertical_error = maxf(maximum_vertical_error, absf(difference.y))
		maximum_platform_speed = maxf(maximum_platform_speed, player.get_platform_velocity().length())
		if player.is_on_floor():
			grounded_frames += 1
		if i % 10 == 0 or i == 119:
			samples.append({"frame": i + 1, "phase": motion.sampled_path_phase,
				"player": _array(player.global_position), "platform": _array(body.global_position),
				"relative": _array(relative), "reported_platform_velocity": _array(player.get_platform_velocity()),
				"on_floor": player.is_on_floor()})
	var travel: float = body.global_position.distance_to(start_platform)
	_check(travel > (0.5 if level_id == "g006" else 3.0), "authored source path actually moves the platform")
	_check(maximum_platform_speed > (0.1 if level_id == "g006" else 1.0), "physics recognizes platform velocity")
	_check(grounded_frames >= 116, "player remains supported during source path motion")
	# Physics follows the body's preceding tick; source visual transforms are
	# already at the next pose. Bound that offset, rather than demanding no lag.
	_check(maximum_horizontal_error < maximum_platform_speed / 60.0 + 0.04, "player carried horizontally without walking")
	_check(maximum_vertical_error < maximum_platform_speed / 60.0 + 0.04, "player carried vertically without jumping")
	var reset_report: Dictionary = {}
	if level_id == "g036":
		level.restore_native_world()
		var restored: Vector3 = player.global_position
		var old_platform_velocity: Vector3 = player.get_platform_velocity()
		var reset_samples: Array[Dictionary] = []
		for frame: int in range(4):
			await _ticks(1)
			reset_samples.append({"frame": frame + 1, "position": _array(player.global_position),
				"velocity": _array(player.velocity), "on_floor": player.is_on_floor(),
				"platform_velocity": _array(player.get_platform_velocity())})
		var reset_delta: Vector3 = player.global_position - restored
		_check(Vector2(reset_delta.x, reset_delta.z).length() < 0.2, "checkpoint teleport discards old platform carry")
		reset_report = {"restored": _array(restored), "old_platform_velocity": _array(old_platform_velocity),
			"delta_after_four_ticks": _array(reset_delta), "samples": reset_samples}
	var report: Dictionary = {"checks": checks, "failures": failures, "platform": id,
		"source_path": motion.source.world_transform_ref, "native_motion": motion.native.motion,
		"start_player": _array(start_player), "start_platform": _array(start_platform),
		"platform_travel": travel, "grounded_frames": grounded_frames,
		"maximum_horizontal_drift": maximum_horizontal_error, "maximum_vertical_drift": maximum_vertical_error,
		"maximum_reported_platform_speed": maximum_platform_speed, "samples": samples, "reset": reset_report}
	var output := FileAccess.open("user://native_platform_result.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "  "))
	output.close()
	print("NATIVE_PLATFORM_TEST: ", "PASS" if failures.is_empty() else "FAIL", " checks=", checks, " travel=", travel,
		" horizontal_drift=", maximum_horizontal_error, " vertical_drift=", maximum_vertical_error, " grounded=", grounded_frames)
	level.free()
	await process_frame
	OS.delay_msec(100)
	quit(0 if failures.is_empty() else 1)
