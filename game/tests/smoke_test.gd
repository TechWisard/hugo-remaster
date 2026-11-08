extends SceneTree
## Integration checks against the real course, physics bodies, Input and pickups.
## Run after the editor has imported the project:
## godot --headless --path game --fixed-fps 60 --script res://tests/smoke_test.gd

const MAIN_SCENE_PATH: String = "res://scenes/main.tscn"
const INPUT_ACTIONS: Array[StringName] = [
	&"move_left", &"move_right", &"move_forward", &"move_back",
	&"jump", &"sprint", &"reset",
]

var _world: Node3D
var _player: CharacterBody3D
var _failures: Array[String] = []
var _checks: int = 0
var _respawn_events: int = 0
var _finishing: bool = false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(40.0).timeout.connect(_on_timeout)
	_release_input()
	var scene: PackedScene = load(MAIN_SCENE_PATH) as PackedScene
	if not _expect(scene != null, "main scene loads as PackedScene"):
		_finish()
		return
	_world = scene.instantiate() as Node3D
	if not _expect(_world != null, "main scene instantiates as Node3D"):
		_finish()
		return
	root.add_child(_world)
	current_scene = _world
	await _frames(3)
	_player = _world.get("player") as CharacterBody3D
	if not _expect(_player != null, "world creates the player physics body"):
		_finish()
		return
	_player.connect("respawned", _on_respawned)
	_expect(_world.get("camera_rig") != null, "world creates its follow camera")
	_expect(_player.get("movement_camera") != null, "movement uses the world camera")
	var pickups: Array = _world.get("diamonds")
	_expect(not pickups.is_empty(), "course contains diamond pickups")
	_expect(int(_world.get("total_diamonds")) == pickups.size(), "HUD total matches course pickups")
	_expect(int(_world.get("collected_count")) == 0, "new run has no collected diamonds")
	_expect(not bool(_world.get("completed")), "new run has not completed")
	for action: StringName in INPUT_ACTIONS:
		_expect(InputMap.has_action(action), "input action exists: %s" % action)
	if pickups.is_empty():
		_finish()
		return

	await _test_floor()
	await _test_pause()
	await _test_pause_accept()
	await _test_jump()
	await _test_movement()
	await _test_pickup_and_respawn(pickups[0] as Area3D)
	await _test_finish_and_restart(pickups)
	_finish()


func _test_floor() -> void:
	var spawn: Vector3 = _world.get("spawn_point")
	_player.global_position = spawn + Vector3.UP * 3.0
	_player.velocity = Vector3.ZERO
	var elevated_y: float = _player.global_position.y
	await _frames(12)
	_expect(_player.global_position.y < elevated_y - 0.1, "gravity moves the airborne player down")
	await _frames(100)
	_expect(_player.is_on_floor(), "player lands on the authored course collision")
	var settled: Vector3 = _player.global_position
	await _frames(24)
	_expect(absf(_player.global_position.y - settled.y) < 0.03, "feet stay stable on the floor")
	_expect(absf(_player.velocity.y) < 0.1, "floor contact stops vertical velocity")


func _test_movement() -> void:
	var start: Vector3 = _player.global_position
	Input.action_press(&"move_right")
	await _frames(30)
	Input.action_release(&"move_right")
	await _frames(12)
	var displacement: Vector3 = _player.global_position - start
	displacement.y = 0.0
	_expect(displacement.length() > 1.0, "directional input moves the player through the course")
	_expect(Vector2(_player.velocity.x, _player.velocity.z).length() < 0.15, "releasing movement brakes the player")
	_player.call("respawn")
	await _frames(45)


func _test_pause() -> void:
	_expect(InputMap.has_action(&"pause"), "pause input action exists")
	await _tap_escape()
	_expect(paused, "Escape pauses the running scene through the input event path")
	var position_before: Vector3 = _player.global_position
	var elapsed_before: float = float(_world.get("elapsed_seconds"))
	Input.action_press(&"move_right")
	for _step: int in range(6):
		await process_frame
	Input.action_release(&"move_right")
	_expect(_player.global_position.distance_to(position_before) < 0.001, "pause stops player movement despite input")
	_expect(is_equal_approx(float(_world.get("elapsed_seconds")), elapsed_before), "pause stops the run timer")
	await _tap_escape()
	_expect(not paused, "Escape reaches the paused HUD and resumes the scene")
	# Keep later checks runnable if the pause regression ever returns.
	paused = false


func _tap_escape() -> void:
	_send_key(KEY_ESCAPE, true)
	await process_frame
	_send_key(KEY_ESCAPE, false)
	await process_frame


func _test_pause_accept() -> void:
	var hud: CanvasLayer = _world.get("hud") as CanvasLayer
	var continue_button: Button = hud.get("continue_button") as Button
	for same_frame: bool in [false, true]:
		var mode: String = "same-frame Space tap" if same_frame else "Space press and release"
		var floor_y: float = _player.global_position.y
		await _tap_escape()
		_expect(paused, "%s regression starts with the scene paused" % mode)
		_expect(root.gui_get_focus_owner() == continue_button, "pause focuses the Continue button")
		_send_key(KEY_SPACE, true)
		if not same_frame:
			await process_frame
		_send_key(KEY_SPACE, false)
		await _frames(5)
		_expect(not paused, "%s activates Continue through the real button" % mode)
		_expect(
			_player.is_on_floor() and absf(_player.velocity.y) < 0.001
			and absf(_player.global_position.y - floor_y) < 0.025,
			"%s does not also trigger a gameplay jump" % mode
		)
		if paused:
			hud.call("toggle_pause")


func _send_key(code: Key, pressed: bool) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


func _test_jump() -> void:
	_expect(_player.is_on_floor(), "jump starts with real floor contact")
	var floor_y: float = _player.global_position.y
	var highest_y: float = floor_y
	_send_key(KEY_SPACE, true)
	for step: int in range(90):
		if step == 12:
			_send_key(KEY_SPACE, false)
		await physics_frame
		highest_y = maxf(highest_y, _player.global_position.y)
	_send_key(KEY_SPACE, false)
	_expect(highest_y - floor_y > 0.7, "a fresh Space press still jumps after resuming")
	_expect(_player.is_on_floor(), "player lands after releasing jump")
	_expect(absf(_player.global_position.y - floor_y) < 0.05, "jump returns to the same floor height")


func _test_pickup_and_respawn(pickup: Area3D) -> void:
	var before: int = int(_world.get("collected_count"))
	_expect(bool(pickup.get("active")), "first diamond starts active")
	# Place the player's capsule inside the actual Area3D; physics must emit
	# body_entered and the world must consume the pickup's collected signal.
	_player.global_position = pickup.global_position - Vector3.UP * 0.8
	_player.velocity = Vector3.ZERO
	await _frames(8)
	_expect(not bool(pickup.get("active")), "body entering the diamond area collects it")
	_expect(int(_world.get("collected_count")) == before + 1, "pickup signal updates world progress once")
	_expect(not bool(pickup.call("collect")), "collect rejects an already collected diamond")
	_expect(int(_world.get("collected_count")) == before + 1, "duplicate collection does not increase progress")

	var collected: int = int(_world.get("collected_count"))
	var spawn: Vector3 = _world.get("spawn_point")
	var previous_respawns: int = _respawn_events
	Input.action_press(&"reset")
	await _frames(3)
	Input.action_release(&"reset")
	_expect(_respawn_events == previous_respawns + 1, "reset input emits exactly one respawn")
	_expect(_horizontal_distance(_player.global_position, spawn) < 0.05, "reset returns to the course checkpoint")
	_expect(int(_world.get("collected_count")) == collected, "manual respawn preserves collected diamonds")

	previous_respawns = _respawn_events
	var fall_height: float = float(_player.get("fall_reset_height"))
	_player.global_position = Vector3(spawn.x, fall_height - 3.0, spawn.z)
	_player.velocity = Vector3(0.0, -10.0, 0.0)
	await _frames(4)
	_expect(_respawn_events == previous_respawns + 1, "falling below the course triggers one respawn")
	_expect(_player.global_position.y > fall_height, "fall recovery restores the player above the kill plane")
	_expect(_horizontal_distance(_player.global_position, spawn) < 0.05, "fall recovery returns to the checkpoint")
	_expect(int(_world.get("collected_count")) == collected, "fall recovery preserves collected diamonds")


func _test_finish_and_restart(pickups: Array) -> void:
	for pickup: Area3D in pickups:
		pickup.call("collect")
	await _frames(2)
	_expect(int(_world.get("collected_count")) == int(_world.get("total_diamonds")), "all diamond signals complete the collection count")
	_expect(not bool(_world.get("completed")), "collecting every diamond still requires reaching the exit")
	_player.global_position = _world.get("exit_position")
	_player.velocity = Vector3.ZERO
	await _frames(8)
	_expect(bool(_world.get("completed")), "entering the finish area completes a fully collected run")
	var hud: CanvasLayer = _world.get("hud") as CanvasLayer
	var restart_button: Button = hud.get("restart_button") as Button
	_expect(root.gui_get_focus_owner() == restart_button, "completion menu focuses the Restart button")
	_send_key(KEY_SPACE, true)
	await process_frame
	_send_key(KEY_SPACE, false)
	await _frames(20)
	_expect(_player.is_on_floor() and absf(_player.velocity.y) < 0.001, "Space restart does not also trigger a gameplay jump")
	var modal: Control = hud.get("modal") as Control
	_expect(not modal.visible, "keyboard restart closes the completion menu")
	_expect(int(_world.get("collected_count")) == 0, "restart clears collected progress")
	_expect(not bool(_world.get("completed")), "restart clears completed state")
	var active_count: int = 0
	for pickup: Area3D in pickups:
		if bool(pickup.get("active")):
			active_count += 1
	_expect(active_count == int(_world.get("total_diamonds")), "restart reactivates every diamond")
	_expect(bool(_player.get("controls_enabled")), "restart leaves player controls enabled")
	var spawn: Vector3 = _world.get("spawn_point")
	_expect(_horizontal_distance(_player.global_position, spawn) < 0.05, "restart returns the player to the start")
	_expect(bool((pickups[0] as Area3D).call("collect")), "a restarted diamond can be collected again")
	_expect(int(_world.get("collected_count")) == 1, "restarted collection updates world progress")


func _frames(count: int) -> void:
	for _step: int in range(count):
		await physics_frame


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _release_input() -> void:
	for action: StringName in INPUT_ACTIONS:
		if InputMap.has_action(action):
			Input.action_release(action)


func _expect(condition: bool, description: String) -> bool:
	_checks += 1
	if condition:
		print("SMOKE PASS: ", description)
	else:
		_failures.append(description)
		push_error("SMOKE FAIL: " + description)
	return condition


func _on_respawned() -> void:
	_respawn_events += 1


func _on_timeout() -> void:
	_failures.append("test did not complete within 40 simulated seconds")
	_finish()


func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	_release_input()
	print("SMOKE RESULT: ", _checks - _failures.size(), "/", _checks, " checks passed")
	for failure: String in _failures:
		printerr("  - ", failure)
	if is_instance_valid(_world):
		current_scene = null
		_world.free()
		_world = null
		_player = null
	call_deferred("_quit_after_cleanup")


func _quit_after_cleanup() -> void:
	await process_frame
	# --fixed-fps advances physics faster than the real audio mixer thread.
	# Let that thread release the short pickup voices after freeing the scene.
	OS.delay_msec(100)
	quit(0 if _failures.is_empty() else 1)
