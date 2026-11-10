extends SceneTree
## Real native-player physics on small authored fixtures. Movement uses keyboard
## input; no pose/velocity writes or fabricated floor flags during a scenario.

const PlayerScript = preload("res://scripts/player.gd")
const StepScript = preload("res://scripts/native_step.gd")
var checks: int = 0
var failures: Array[String] = []
var scenarios: Array[Dictionary] = []
var report_path: String = "user://native_step_test.json"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--step-report="):
			report_path = argument.trim_prefix("--step-report=")
	RemasterInput.configure()
	_release()
	await _low_step(0.08, true)
	await _low_step(0.11, false)
	await _high_wall_and_platform()
	await _low_ceiling()
	await _uncapped_riser()
	await _floor_end()
	_release()
	var result: Dictionary = {"checks": checks, "failures": failures,
		"fixture_count": scenarios.size(), "scenarios": scenarios,
		"ordinary_keyboard_input": true, "player_pose_writes_during_scenarios": 0,
		"original_assets_required": false, "synthetic_physics_fixtures": true,
		"source_sha256": {"player": FileAccess.get_sha256("res://scripts/player.gd"),
			"step": FileAccess.get_sha256("res://scripts/native_step.gd"),
			"test": FileAccess.get_sha256("res://tests/native_step_test.gd")}}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		_check(false, "step report can be written")
	else:
		file.store_string(JSON.stringify(result, "\t"))
		file.close()
	print("NATIVE_STEP checks=", checks, " fixtures=", scenarios.size(),
		" failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _low_step(height: float, test_crouch: bool) -> void:
	var fixture: Dictionary = _fixture(height)
	var player: HugoPlayer = fixture.player
	await _settle(player)
	var crouch: Dictionary = {}
	if test_crouch:
		_key(KEY_CTRL, true)
		crouch = await _drive(player, 50)
		_check(player.is_crouching and player.position.z > 0.98 and float(crouch.max_y) < 0.04,
			"crouching reaches the small riser but does not receive standing auto-step")
		_key(KEY_CTRL, false)
	var trace: Dictionary = await _drive(player, 90)
	_check(player.position.z < -2.0 and player.is_on_floor(),
		"ordinary W crosses the %.0f cm step and returns to real floor support" % (height * 100.0))
	_check(float(trace.max_y) > height - 0.02 and float(trace.max_y) < height + 0.04,
		"%.0f cm step uses its actual cap height without a jump or excessive lift" % (height * 100.0))
	_check(int(trace.top_samples) > 0 and int(trace.unsupported_top_samples) == 0,
		"%.0f cm cap has current floor flags during supported traversal" % (height * 100.0))
	_check(int(trace.jumping_ticks) == 0 and float(trace.max_upward_velocity) < 0.01,
		"auto-step never injects native jump state or upward launch velocity")
	var jump: Dictionary = {}
	if not test_crouch:
		var before_jump: Vector3 = player.position
		_key(KEY_SPACE, true)
		await _ticks(3)
		_key(KEY_SPACE, false)
		_check(player._jump_in_progress and not player.is_on_floor() and player.position.y > before_jump.y + 0.2,
			"a fresh Space press after stepping still launches the native jump")
		var airborne_position: Vector3 = player.position
		var airborne_velocity: Vector3 = player.velocity
		_check(not StepScript.try_step(player, Vector3.FORWARD * 0.1, 0.18)
			and player.position == airborne_position and player.velocity == airborne_velocity,
			"step helper cannot move or ground the genuinely airborne native jump")
		jump = {"height_after_three_ticks": player.position.y - before_jump.y,
			"native_jump": player._jump_in_progress, "on_floor": player.is_on_floor()}
	scenarios.append({"id": "step_%.0fcm" % (height * 100.0), "walking": trace,
		"crouching": crouch, "native_jump": jump})
	await _dispose(fixture)


func _high_wall_and_platform() -> void:
	var fixture: Dictionary = _fixture(0.4)
	var player: HugoPlayer = fixture.player
	await _settle(player)
	var trace: Dictionary = await _drive(player, 70)
	_check(int(trace.side_contacts) > 0 and player.position.z > 0.98 and player.position.z < 1.1,
		"40 cm static wall is reached and continues to block forward input")
	_check(float(trace.max_y) < 0.04 and player.is_on_floor(),
		"an obstacle above step height cannot create a climb or unsupported lift")
	# The same encounter with a low native platform side must remain outside
	# this static-terrain repair; no player teleport/reset is used between them.
	(fixture.obstacle as StaticBody3D).free()
	_box(fixture.root, Vector3(0, 0.055, 0), Vector3(6, 0.11, 1.2), true)
	var platform: Dictionary = await _drive(player, 30)
	_check(int(platform.side_contacts) > 0 and player.position.z > 0.98 and float(platform.max_y) < 0.04,
		"a low AnimatableBody platform side is not treated as a static terrain step")
	scenarios.append({"id": "high_wall_and_platform_side", "wall": trace, "platform": platform})
	await _dispose(fixture)


func _low_ceiling() -> void:
	var fixture: Dictionary = _fixture(0.08, true)
	var player: HugoPlayer = fixture.player
	await _settle(player)
	var trace: Dictionary = await _drive(player, 70)
	_check(int(trace.side_contacts) > 0 and player.position.z > 0.98,
		"ceiling at 3.04 m prevents the 3 m player from stepping onto an 8 cm cap")
	_check(float(trace.max_y) < 0.04 and player.is_on_floor(),
		"upward clearance sweep does not push the standing shape through the low ceiling")
	scenarios.append({"id": "low_ceiling", "trace": trace})
	await _dispose(fixture)


func _uncapped_riser() -> void:
	var fixture: Dictionary = _fixture(0.0, false, 0.0)
	var player: HugoPlayer = fixture.player
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(PackedVector3Array([
		Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3(5, 0.11, 0),
		Vector3(-5, 0, 0), Vector3(5, 0.11, 0), Vector3(-5, 0.11, 0)]))
	collision.shape = shape
	body.add_child(collision)
	(fixture.root as Node3D).add_child(body)
	await _settle(player)
	var trace: Dictionary = await _drive(player, 70)
	_check(int(trace.side_contacts) > 0 and player.position.z > 0.38 and player.position.z < 0.5,
		"a thin vertical riser at the floor edge is reached but cannot become a bridge")
	_check(float(trace.max_y) < 0.04 and player.is_on_floor(),
		"an uncapped vertical sheet cannot provide a raised horizontal landing")
	scenarios.append({"id": "uncapped_riser_before_void", "trace": trace})
	await _dispose(fixture)


func _floor_end() -> void:
	var fixture: Dictionary = _fixture(0.0, false, 0.0)
	var player: HugoPlayer = fixture.player
	await _settle(player)
	var trace: Dictionary = await _drive(player, 75)
	_check(player.position.z < -1.0 and player.position.y < -0.5 and not player.is_on_floor(),
		"ordinary W beyond the genuine floor edge still falls into the unsupported gap")
	_check(int(trace.center_ray_miss_ticks) == 0 and float(trace.max_y) < 0.04,
		"no floor flag or artificial upward step survives after the full body clears the edge")
	var before: Vector3 = player.position
	_check(not StepScript.try_step(player, Vector3.FORWARD * 0.1, 0.18) and player.position == before,
		"step helper cannot create support under a genuinely falling body")
	scenarios.append({"id": "genuine_floor_end", "trace": trace})
	await _dispose(fixture)


func _fixture(step_height: float, ceiling: bool = false, floor_start: float = -12.0) -> Dictionary:
	var stage := Node3D.new()
	root.add_child(stage)
	var floor_body := StaticBody3D.new()
	var floor_collision := CollisionShape3D.new()
	var floor_shape := ConcavePolygonShape3D.new()
	floor_shape.backface_collision = true
	floor_shape.set_faces(PackedVector3Array([
		Vector3(-5, 0, floor_start), Vector3(5, 0, 8), Vector3(5, 0, floor_start),
		Vector3(-5, 0, floor_start), Vector3(-5, 0, 8), Vector3(5, 0, 8)]))
	floor_collision.shape = floor_shape
	floor_body.add_child(floor_collision)
	stage.add_child(floor_body)
	var obstacle: StaticBody3D
	if step_height > 0:
		obstacle = _box(stage, Vector3(0, step_height * 0.5, 0), Vector3(6, step_height, 1.2))
	if ceiling:
		_box(stage, Vector3(0, 3.19, 0), Vector3(8, 0.3, 30))
	var player: HugoPlayer = PlayerScript.new()
	player.model_path = ""
	player.character_height = 3.0
	player.position = Vector3(0, 0.02, 2.4)
	_check(player.set_native_configuration(_profile()), "fixture enables the recovered 3 m native controller")
	stage.add_child(player)
	return {"root": stage, "player": player, "obstacle": obstacle}


func _box(parent: Node3D, at: Vector3, size: Vector3, platform: bool = false) -> StaticBody3D:
	var body: StaticBody3D = AnimatableBody3D.new() if platform else StaticBody3D.new()
	if platform:
		(body as AnimatableBody3D).sync_to_physics = false
	body.position = at
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body


func _settle(player: HugoPlayer) -> void:
	await _ticks(12)
	_check(player.is_on_floor() and absf(player.position.y) < 0.04,
		"fixture starts on its actual thin floor with no forced grounded state")


func _drive(player: HugoPlayer, frames: int) -> Dictionary:
	_key(KEY_W, true)
	var trace: Dictionary = {"frames": frames, "max_y": player.position.y,
		"max_upward_velocity": 0.0, "top_samples": 0, "unsupported_top_samples": 0,
		"side_contacts": 0, "jumping_ticks": 0, "center_ray_miss_ticks": 0, "samples": []}
	for frame: int in range(frames):
		await _ticks(1)
		if frame == 0:
			_check(Input.is_action_pressed("move_forward"), "physical W event reaches the configured movement action")
		trace.max_y = maxf(float(trace.max_y), player.position.y)
		trace.max_upward_velocity = maxf(float(trace.max_upward_velocity), player.velocity.y)
		if player._jump_in_progress: trace.jumping_ticks += 1
		if absf(player.position.z) < 0.2 and player.position.y > 0.04:
			trace.top_samples += 1
			if not player.is_on_floor(): trace.unsupported_top_samples += 1
		if player.position.z < -0.6 and player.is_on_floor():
			var query := PhysicsRayQueryParameters3D.create(player.position + Vector3.UP * 0.04,
				player.position - Vector3.UP * 0.08, player.collision_mask, [player.get_rid()])
			query.hit_back_faces = true
			if player.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
				trace.center_ray_miss_ticks += 1
		for hit: int in range(player.get_slide_collision_count()):
			if absf(player.get_slide_collision(hit).get_normal().y) < 0.2:
				trace.side_contacts += 1
		trace.samples.append({"tick": frame, "position": [player.position.x, player.position.y, player.position.z],
			"velocity": [player.velocity.x, player.velocity.y, player.velocity.z],
			"on_floor": player.is_on_floor(), "jumping": player._jump_in_progress})
	_key(KEY_W, false)
	return trace


func _dispose(fixture: Dictionary) -> void:
	_release()
	(fixture.root as Node3D).free()
	await _ticks(2)


func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


func _release() -> void:
	for code: Key in [KEY_W, KEY_CTRL, KEY_SPACE]:
		_key(code, false)


func _ticks(count: int) -> void:
	for frame: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _profile() -> Dictionary:
	# Same recovered constants as NativeFatalFixture; the fixture has no assets.
	return {"schema_version": 1, "native_timer_hz": 300.0,
		"ground_max_speed": 8.25, "ground_response_per_tick": 0.05,
		"crawl_speed": 3.0, "crawl_response_per_tick": 0.9,
		"jump_initial_velocity": 1800.0 / 121.0, "jump_gravity": 4500.0 / 121.0,
		"jump_horizontal_speed": 11.25, "jump_response_per_tick": 0.01,
		"fall_horizontal_speed": 3.0, "fall_response_per_tick": 0.005,
		"fall_gravity": 216.0, "fall_terminal_speed": 9.0,
		"standing_box_size": [0.8, 3.0, 0.8], "crouching_box_size": [0.8, 2.0, 0.8],
		"walk_run_animation_threshold": 3.9, "invulnerability_seconds": 2.0}
