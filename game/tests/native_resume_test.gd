extends SceneTree
## Real save/recreate/contact pipeline with synthetic graphs, no game assets.

const TEST_PATH: String = "user://native_resume_test.json"
const LEVEL_ID: String = "resume_fixture"
const TARGET_ID: String = "target"


class ResumeFixture extends OriginalLevel:
	var native_controls: bool = false
	var starts_at := Vector3(0.0, 0.05, 0.0)
	var floor_slope: float = 0.0

	func _ready() -> void:
		RemasterInput.configure()
		entry = {"id": LEVEL_ID}
		data = {"main_group": 0}
		gameplay = {"native_player": {"id": "player"}}
		if native_controls:
			gameplay.native_player["movement"] = _native_profile()
		owners = {"player": {"id": "player", "type": 10000},
			TARGET_ID: {"id": TARGET_ID, "type": 10300, "source_group": 1}}
		_restore_flags()
		spawn_point = starts_at
		scene_bounds = AABB(Vector3(-50, -10, -50), Vector3(100, 100, 100))
		health = int(restored_run.get("health", 10))
		max_health = 10
		lives = 4
		var floor_body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(100, 1, 100)
		shape.shape = box
		floor_body.position.y = -0.5
		floor_body.rotation.z = floor_slope
		floor_body.add_child(shape)
		add_child(floor_body)
		# Exercise the production creation/resume path, not a test player.
		_create_player()
		# A fixed input basis isolates player-state continuity from camera easing.
		var input_camera := Camera3D.new()
		add_child(input_camera)
		player.movement_camera = input_camera
		_sampler = HugoOriginalAnimation.new()
		add_child(_sampler)
		player_graph = NativeGraphColliders.new()
		player_graph.source = {"id": "player", "actions": [
			{"index": 2, "collision_nodes": [_box(2, 4)]}]}
		player_graph.player = player
		player_graph.sampler = _sampler
		player_graph.space = self
		add_child(player_graph)
		var visual := Node3D.new()
		visual.position.x = 20.0
		add_child(visual)
		owner_nodes[TARGET_ID] = visual
		var action := Node3D.new()
		action.name = "TargetAction000"
		visual.add_child(action)
		var motion := NativeActorMotion.new()
		motion.owner_visual = visual
		motion.sampler = _sampler
		motion.autonomous = false
		motion.source = {"id": TARGET_ID, "actions": [{"index": 0,
			"node_name": "TargetAction000", "collision_nodes": [_box(4, 2)]}]}
		add_child(motion)
		var actor := NativeStateActor.new()
		actor.source_id = TARGET_ID
		actor.level = self
		actor.visual = visual
		actor.motion = motion
		actor.native = {"source": {"group": 1}, "state_machine": {
			"initial_state": 0, "initial_health_base": 5,
			"states": [{"visual_action": 0, "visual_period": 0.0,
				"timeout_seconds": 1000.0, "flags": 0, "transitions": [],
				"entry_events": []}]}}
		actor.restore(restored_run.get("actors", {}).get(TARGET_ID, {}))
		state_actors[TARGET_ID] = actor
		add_child(actor)
		# Only the intended overlap is dispatched by the fixture. Creation,
		# snapshots, attack acceptance and damage deduplication remain production.
		player_graph.set_physics_process(false)
		actor.graph_colliders.set_physics_process(false)
		actor.set_physics_process(false)
		_restore_checkpoint()
		_ready_ok = true

	static func _box(category: int, receive_mask: int) -> Dictionary:
		return {"node_index": 0, "collision_mask_a": category,
			"collision_mask_b": receive_mask,
			"bounds": [[-0.5, 0.0, -0.5], [0.5, 1.0, 0.5]],
			"transform_chain": []}

	static func _native_profile() -> Dictionary:
		return {"schema_version": 1, "native_timer_hz": 300.0,
			"ground_max_speed": 8.25, "ground_response_per_tick": 0.05,
			"crawl_speed": 3.0, "crawl_response_per_tick": 0.9,
			"jump_initial_velocity": 1800.0 / 121.0, "jump_gravity": 4500.0 / 121.0,
			"jump_horizontal_speed": 11.25, "jump_response_per_tick": 0.01,
			"fall_horizontal_speed": 3.0, "fall_response_per_tick": 0.005,
			"fall_gravity": 216.0, "fall_terminal_speed": 9.0,
			"standing_box_size": [0.8, 3.0, 0.8], "crouching_box_size": [0.8, 2.0, 0.8],
			"walk_run_animation_threshold": 3.9, "invulnerability_seconds": 2.0}


var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	await _round_trip(false)
	await _round_trip(true)
	await _missed_attacks_round_trip()
	await _movement_round_trip("run")
	await _movement_round_trip("crawl")
	await _movement_round_trip("ascending jump")
	await _movement_round_trip("fall")
	await _hurt_round_trip()
	await _checkpoint_cold_reset()
	await _buffered_landing(false)
	await _buffered_landing(true)
	await _slope_controls()
	_cleanup()
	print("NATIVE_RESUME checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _round_trip(legacy: bool) -> void:
	var prefix: String = "legacy v2" if legacy else "current v2"
	var first := ResumeFixture.new()
	root.add_child(first)
	await _ticks(8)
	_check(first.player.is_on_floor(), prefix + ": real player settles on floor")
	_check(first.player.start_attack(), prefix + ": first accepted attack starts")
	_contact(first)
	var actor: NativeStateActor = first.state_actors[TARGET_ID]
	_check(actor.hit_points == 4, prefix + ": initial graph overlap deals one HP")
	await _ticks(6)
	var visual_phase: float = first.player.get_native_visual_phase()
	var run: Dictionary = first.run_state()
	if legacy:
		run.erase("attack_serial")
		run.erase("player_runtime")
	var saved: Dictionary = _save_and_read(run, prefix)
	first.free()
	await _ticks(2)
	var resumed := ResumeFixture.new()
	resumed.restored_run = saved
	root.add_child(resumed)
	if not legacy and visual_phase > 0.0:
		_check(is_equal_approx(resumed.player.get_native_visual_phase(), visual_phase), "real imported attack animation resumes at its saved phase")
	await _ticks(8)
	actor = resumed.state_actors[TARGET_ID]
	_check(actor.hit_points == 4, prefix + ": damaged enemy survives actual save/recreate")
	if not legacy:
		_check(resumed.player.is_attacking and not resumed.player.start_attack(), prefix + ": active attack resumes with its remaining recovery")
		_contact(resumed)
		_check(actor.hit_points == 4, prefix + ": resuming the same attack does not deal a duplicate hit")
		await _ticks(30)
	_check(resumed.player.start_attack(), prefix + ": first attack after resume is accepted")
	_contact(resumed)
	_check(actor.hit_points == 3, prefix + ": first resumed attack damages the saved enemy")
	_contact(resumed)
	_check(actor.hit_points == 3, prefix + ": repeated overlap of that attack is still deduplicated")
	resumed.free()
	await _ticks(2)


func _missed_attacks_round_trip() -> void:
	var first := ResumeFixture.new()
	root.add_child(first)
	await _ticks(8)
	# No contact: the player's serial may be newer than every enemy's last ID.
	_check(first.player.start_attack(), "missed attack starts through the real controller")
	await _ticks(30)
	_check(first.player.start_attack(), "second missed attack starts after recovery")
	var serial: int = first.player.attack_serial
	var saved: Dictionary = _save_and_read(first.run_state(), "missed attacks")
	first.free()
	await _ticks(2)
	var resumed := ResumeFixture.new()
	resumed.restored_run = saved
	root.add_child(resumed)
	await _ticks(30)
	_check(resumed.player.start_attack(), "attack after missed-attack resume starts")
	_check(resumed.player.attack_serial > serial, "accepted attack sequence stays monotonic across resume without an enemy hit")
	_contact(resumed)
	_check((resumed.state_actors[TARGET_ID] as NativeStateActor).hit_points == 4,
		"attack after missed-attack resume reaches the actual damage receiver")
	resumed.free()
	await _ticks(2)


func _movement_round_trip(label: String) -> void:
	var first := ResumeFixture.new()
	first.native_controls = true
	if label == "fall":
		first.starts_at.y = 15.0
	root.add_child(first)
	await _ticks(8)
	Input.action_press("move_forward")
	if label == "crawl":
		Input.action_press("crouch")
	if label == "ascending jump":
		Input.action_press("jump")
		await _ticks(1)
		Input.action_release("jump")
	await _ticks(5)
	if label == "fall" or label == "ascending jump":
		_check(first.player.velocity.y < 0.0 if label == "fall" else first.player.velocity.y > 0.0,
			label + ": actual input/physics reaches the intended flight state")
	else:
		_check(first.player.is_on_floor() and first.player.is_crouching == (label == "crawl"),
			label + ": actual input/physics reaches the intended grounded state")
	var before_velocity: Vector3 = first.player.velocity
	var saved: Dictionary = _save_and_read(first.run_state(), label)
	var reference: Array[Vector3] = []
	for i: int in range(24):
		await _ticks(1)
		reference.append(first.player.global_position)
	first.free()
	await _ticks(2)
	var resumed := ResumeFixture.new()
	resumed.native_controls = true
	resumed.restored_run = saved
	root.add_child(resumed)
	_check(resumed.player.velocity.is_equal_approx(before_velocity), label + ": resume preserves momentum before the first physics update")
	var maximum_deviation: float = 0.0
	for position: Vector3 in reference:
		await _ticks(1)
		maximum_deviation = maxf(maximum_deviation, resumed.player.global_position.distance_to(position))
	_check(maximum_deviation < 0.01, label + ": resumed trajectory matches uninterrupted movement (error %.6f)" % maximum_deviation)
	Input.action_release("move_forward")
	Input.action_release("crouch")
	resumed.free()
	await _ticks(2)


func _hurt_round_trip() -> void:
	var first := ResumeFixture.new()
	first.native_controls = true
	root.add_child(first)
	await _ticks(8)
	_check(first.damage_player(1, first.player.global_position + Vector3.RIGHT, 0.25), "horizontal damage enters the real hurt/invulnerability path")
	await _ticks(4)
	_check(first.player.is_hurt and first.player.is_invulnerable, "save is taken during hurt and invulnerability")
	var saved: Dictionary = _save_and_read(first.run_state(), "hurt")
	first.free()
	await _ticks(2)
	var resumed := ResumeFixture.new()
	resumed.native_controls = true
	resumed.restored_run = saved
	root.add_child(resumed)
	_check(resumed.health == 8 and resumed.player.is_hurt, "hurt reaction and damaged health survive resume")
	_check(not resumed.damage_player(1, resumed.player.global_position, 0.0), "resuming cannot bypass the remaining invulnerability interval")
	await _ticks(120)
	_check(resumed.damage_player(1, resumed.player.global_position, 0.0), "restored invulnerability expires normally")
	_check(resumed.health == 6, "only the later accepted hit changes health")
	resumed.free()
	await _ticks(2)


func _checkpoint_cold_reset() -> void:
	var level := ResumeFixture.new()
	level.native_controls = true
	root.add_child(level)
	await _ticks(8)
	level.save_native_world()
	Input.action_press("move_forward")
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	await _ticks(5)
	_check(level.player.velocity.y > 0.0 and level.damage_player(1, level.player.global_position, 0.0),
		"checkpoint regression starts during a damaged jump")
	Input.action_release("move_forward")
	level.restore_native_world()
	_check(level.player.velocity == Vector3.ZERO and not level.player.is_hurt and not level.player.is_invulnerable,
		"native checkpoint still clears movement, hurt and invulnerability")
	_check(level.health == level.max_health and level.player.global_position.is_equal_approx(level.starts_at),
		"native checkpoint restores source position and health rather than modern runtime state")
	level.free()
	await _ticks(2)


func _buffered_landing(native_controls: bool) -> void:
	var label: String = "native" if native_controls else "prototype"
	var level := ResumeFixture.new()
	level.native_controls = native_controls
	level.starts_at.y = 2.0
	root.add_child(level)
	var buffer_height: float = 0.2 if native_controls else 0.5
	for i: int in range(120):
		if level.player.global_position.y < buffer_height or level.player.is_on_floor():
			break
		await _ticks(1)
	_check(not level.player.is_on_floor() and level.player.velocity.y < 0.0,
		label + ": buffered input starts just before actual landing")
	Input.action_press("jump")
	await _ticks(4)
	_check(not level.player.is_on_floor() and level.player.velocity.y > 0.0,
		label + ": a landing-frame jump is consumed once and leaves the floor")
	await _ticks(100)
	_check(level.player.is_on_floor(), label + ": holding the buffered jump does not jump again after landing")
	Input.action_release("jump")
	level.free()
	await _ticks(2)


func _slope_controls() -> void:
	var level := ResumeFixture.new()
	level.native_controls = true
	level.floor_slope = deg_to_rad(8.0)
	root.add_child(level)
	await _ticks(8)
	Input.action_press("move_right")
	Input.action_press("crouch")
	var start: Vector3 = level.player.global_position
	var grounded_frames: int = 0
	var crouched_frames: int = 0
	for i: int in range(60):
		await _ticks(1)
		grounded_frames += int(level.player.is_on_floor())
		crouched_frames += int(level.player.is_crouching)
	_check(level.player.global_position.x > start.x + 1.0 and level.player.global_position.y > start.y + 0.1,
		"normal movement climbs the real sloped collider")
	_check(grounded_frames == 60 and crouched_frames == 60,
		"held crouch remains active on an uphill floor (%d/60 grounded, %d/60 crouched)" % [grounded_frames, crouched_frames])
	Input.action_release("crouch")
	await _ticks(2)
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	await _ticks(10)
	_check(not level.player.is_on_floor() and level.player.velocity.y > 0.0,
		"fresh jump leaves an uphill floor without reusing its stale floor flag")
	await _ticks(60)
	_check(level.player.is_on_floor(), "uphill jump lands normally")
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	await _ticks(5)
	_check(not level.player.is_on_floor() and level.player.velocity.y > 0.0,
		"landing on a slope permits the next fresh jump")
	Input.action_release("move_right")
	level.free()
	await _ticks(2)


func _save_and_read(run: Dictionary, label: String) -> Dictionary:
	var state := CampaignState.new()
	state.path = TEST_PATH
	state.set_run(LEVEL_ID, run)
	_check(state.write_save(), label + ": save writes to disk")
	var loaded := CampaignState.new()
	loaded.path = TEST_PATH
	_check(loaded.read_save([LEVEL_ID]), label + ": save reads from disk")
	return loaded.runs.get(LEVEL_ID, {}).duplicate(true)


func _contact(level: ResumeFixture) -> void:
	level.player_graph.refresh()
	var target: NativeStateActor = level.state_actors[TARGET_ID]
	target.graph_colliders.refresh()
	_check(not level.player_graph.active_boxes.is_empty() and not target.graph_colliders.active_boxes.is_empty(),
		"attack and target have actual active graph boxes")
	if level.player_graph.active_boxes.is_empty() or target.graph_colliders.active_boxes.is_empty():
		return
	# Align source boxes, rather than relying on a guessed attack reach or yaw.
	target.visual.global_position += level.player_graph.active_boxes[0].center - target.graph_colliders.active_boxes[0].center
	target.graph_colliders.refresh()
	NativeGraphColliders._test_pair(level.player_graph, target.graph_colliders)


func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
