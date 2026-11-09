extends SceneTree
## Production hit/state/physics/save paths on a real floor; original Escape
## contact graph and audio are additionally checked when local assets exist.

const TEST_PATH: String = "user://native_fatal_test.json"
const LEVEL_ID: String = "fatal_fixture"

class Fixture extends OriginalLevel:
	var platform_height: float = 0.0
	var upper_floor: StaticBody3D

	func _ready() -> void:
		RemasterInput.configure()
		entry = {"id": LEVEL_ID}
		data = {"main_group": 1}
		gameplay = {"native_player": {"id": "player", "movement": _profile()},
			"health_bar": {"id": "health"}, "owners": {}}
		owners = {"player": {"id": "player", "type": 10000}}
		_restore_flags()
		spawn_point = Vector3(0.0, platform_height + 0.04, 0.0)
		scene_bounds = AABB(Vector3(-1000, -1000, -1000), Vector3(2000, 2000, 2000))
		_restore_health_and_lives()
		_floor(0.0)
		if platform_height > 0.0:
			upper_floor = _floor(platform_height)
		_create_player()
		hud = RemasterHUD.new()
		add_child(hud)
		_restore_checkpoint()
		if restored_run.get("checkpoint_state") is Dictionary:
			_checkpoint_state = restored_run.checkpoint_state.duplicate(true)
		else:
			save_native_world()
		_restore_death_after_load()
		_ready_ok = true

	func _floor(height: float) -> StaticBody3D:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(1000, 1, 1000)
		collision.shape = shape
		body.position.y = height - 0.5
		body.add_child(collision)
		add_child(body)
		return body

	func add_hazard(amount: int, response: float = 1.0, constraint: int = 0) -> void:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(PackedVector3Array([Vector3(-20, 0, -20), Vector3(20, 0, 20), Vector3(20, 0, -20),
			Vector3(-20, 0, -20), Vector3(-20, 0, 20), Vector3(20, 0, 20)]))
		shape.backface_collision = true
		collision.shape = shape
		body.add_child(collision)
		body.position.y = 0.005
		body.set_meta("native_owner", "hazard")
		body.set_meta("native_surfaces", [7, 7])
		gameplay.owners["hazard"] = {"source": {"group": 1, "record": 7},
			"surface_data": [{"surface_type": 7, "ground_damage": amount,
				"movement_response_coefficient": response, "movement_constraint_raw": constraint}]}
		add_child(body)

	static func _profile() -> Dictionary:
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
var source_contact_checked: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	RemasterInput.configure()
	_release()
	await _surviving_damage()
	await _immediate_fatal_branches()
	await _pending_without_timer()
	await _pending_save(false)
	await _pending_save(true)
	await _legacy_death_save()
	await _surface_invulnerability()
	await _surface_without_contact_timer()
	await _source_contact_death()
	_save_validation()
	_release()
	_cleanup()
	print("NATIVE_FATAL checks=", checks, " source_contact=", source_contact_checked, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _surviving_damage() -> void:
	var level := Fixture.new()
	root.add_child(level)
	await _ticks(8)
	var start: Vector3 = level.player.global_position
	_check(level.player.is_on_floor(), "fixture starts on an actual physics floor")
	_check(level.damage_player(1, start - Vector3.RIGHT, 0.5), "ordinary horizontal contact is accepted")
	_check(level.health == 8 and level.lives == 4 and level.player.in_native_damage,
		"surviving hit deducts difficulty-adjusted health and enters native state5")
	_check(level.player.velocity.is_equal_approx(Vector3(4.5, 12.0, 0.0)) \
		and absf(level.player.global_position.y - start.y - 0.01) < 0.0001,
		"source payload creates the 9x horizontal /12 vertical kick and0.01 position lift")
	Input.action_press("move_left")
	Input.action_press("crouch")
	Input.action_press("jump")
	_check(not level.player.start_attack(), "damage state cannot start an attack")
	await _ticks(10)
	_release()
	_check(absf(level.player.global_position.x - start.x - 0.75) < 0.003 \
		and absf(level.player.global_position.y - start.y - 1.03) < 0.003,
		"50 source ticks follow the independently calculated no-drag ballistic displacement")
	_check(absf(level.player.velocity.x - 4.5) < 0.001 and not level.player.is_crouching and level.player.in_native_damage,
		"held movement/crouch/jump input does not replace the native damage trajectory")
	await _ticks(16)
	_check(level.player.is_on_floor() and not level.player.is_hurt and level.health == 8 and level.lives == 4,
		"nonfatal damage returns to normal movement after its descending floor contact")
	level.restore_native_world()
	await _ticks(5)
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	var airborne_velocity: Vector3 = level.player.velocity
	_check(level.damage_player(1, level.player.global_position, 0.0), "zero-horizontal damage still deducts health")
	_check(not level.player.in_native_damage and level.player._jump_in_progress and level.player.velocity == airborne_velocity,
		"surviving zero-horizontal hit preserves the current jump instead of inventing Hurt")
	level.restore_native_world()
	await _ticks(5)
	Input.action_press("crouch")
	await _ticks(1)
	_check(level.player.is_crouching and level.damage_player(1, level.player.global_position - Vector3.RIGHT),
		"crawling player accepts ordinary damage")
	_check(level.player.is_crouching and not level.player.in_native_damage and level.player.velocity.y == 0.0,
		"surviving crawl hit does not enter the knockback state")
	_release()
	level.free()
	await _ticks(2)


func _immediate_fatal_branches() -> void:
	for crouching: bool in [false, true]:
		var level := Fixture.new()
		root.add_child(level)
		await _ticks(8)
		if crouching:
			Input.action_press("crouch")
			await _ticks(1)
		level.health = 2
		var origin: Vector3 = level.player.global_position - Vector3.RIGHT if crouching else level.player.global_position
		_check(level.damage_player(1, origin), "fatal crawl/zero-horizontal hit is accepted")
		_check(level.health == 0 and level.lives == 3 and level._death_in_progress \
			and not level.player.pending_fatal and not level.player.in_native_damage,
			"fatal crawl/zero-horizontal branch enters state6 immediately and commits one life")
		_check(not level.damage_player(1000, origin) and level.lives == 3,
			"state6 rejects another force hit before animation completion")
		_release()
		level.free()
		await _ticks(2)


func _pending_without_timer() -> void:
	var level := Fixture.new()
	level.platform_height = 200.0
	root.add_child(level)
	await _ticks(8)
	var delayed_pickup: Dictionary = {"pickup": {"health": true, "healing_by_difficulty": [20, 10, 5],
		"collection_delay_seconds": 0.1, "diamonds": 2}}
	_check(level.collect_pickup("delayed_health", delayed_pickup), "health pickup begins before the lethal collision")
	level.health = 2
	_check(level.damage_player(1, level.player.global_position - Vector3.RIGHT), "lethal horizontal hit is accepted")
	_check(level.health == 0 and level.lives == 3 and level.player.pending_fatal and not level._death_in_progress,
		"HealthBar commits a single life immediately while state5 remains airborne")
	level.upper_floor.queue_free()
	await _ticks(6)
	var presentation: NativePlayerPresentation = level.player._visual.native_presentation
	_check(presentation != null and (presentation.remaining_ticks & 0x20) != 0 \
		and not presentation.hidden_by_blink and level.player._visual._pose_root.visible,
		"pending fatal keeps the body visible inside a real invulnerability blink window")
	level.queue_native_event({"target": "health", "event": 0x22000006})
	level.queue_native_event({"target": "health", "event": 0x22000005, "param1": 3})
	await _ticks(116)
	_check(level.health == 0 and level.diamonds == 5 and level.collected.has("delayed_health"),
		"delayed pickup/health event cannot heal a dead HealthBar; independent diamond events still execute")
	_check(level.player.pending_fatal and level.player.in_native_damage and not level._death_in_progress \
		and not level.player.is_invulnerable and not level.player.is_on_floor(),
		"pending fatal outlives both the hurt clip and600-tick invulnerability without a made-up timeout")
	var velocity: Vector3 = level.player.velocity
	_check(not level.damage_player(1, level.player.global_position + Vector3.RIGHT) and level.player.velocity == velocity,
		"ordinary hits are rejected by pending even after invulnerability expires")
	_check(level.damage_player(1000, level.player.global_position) and level.lives == 3 \
		and level._death_in_progress and not level.player.in_native_damage,
		"force death interrupts pending without charging a second life")
	_check(not level.player.is_invulnerable, "force death does not create a new600-tick timer")
	level.free()
	await _ticks(2)
	# A nonfatal state5 can last beyond the cooldown too. A new accepted hit
	# changes its turning impulse but must not restart its physical velocity.
	level = Fixture.new()
	level.platform_height = 200.0
	root.add_child(level)
	await _ticks(8)
	level.damage_player(1, level.player.global_position - Vector3.RIGHT)
	level.upper_floor.queue_free()
	await _ticks(122)
	velocity = level.player.velocity
	var position: Vector3 = level.player.global_position
	_check(level.player.in_native_damage and level.damage_player(1, position + Vector3.FORWARD),
		"a later nonfatal contact is accepted while the original damage flight continues")
	_check(level.player.velocity == velocity and level.player.global_position == position and level.health == 6,
		"already-state5 contact updates health without resetting the kick or position lift")
	level.free()
	await _ticks(2)


func _pending_save(last_life: bool) -> void:
	var level := Fixture.new()
	root.add_child(level)
	await _ticks(8)
	level.health = 2
	if last_life:
		level.lives = 1
	var profile: Dictionary = {"kind": "contact", "group": 69, "record": 192, "offset": 0x4f0}
	level.damage_player(1, level.player.global_position - Vector3.RIGHT, 0.5, 0x22000003, profile)
	await _ticks(5)
	var velocity: Vector3 = level.player.velocity
	var position: Vector3 = level.player.global_position
	var life_count: int = level.lives
	var saved: Dictionary = _save_and_read(level.run_state())
	_check(saved.health == 0 and saved.lives == life_count and saved.death_pending \
		and saved.player_runtime.pending_fatal and saved.player_runtime.native_damage,
		"modern v2 snapshot retains a pending flight with its already committed life count")
	level.free()
	await _ticks(2)
	level = Fixture.new()
	level.restored_run = saved
	root.add_child(level)
	_check(level.health == 0 and level.lives == life_count and level.player.pending_fatal \
		and not level._death_in_progress and not level.hud.modal.visible,
		"Continue resumes pending state5, including zero remaining lives, before game-over presentation")
	_check(level.player.global_position.is_equal_approx(position) and level.player.velocity.is_equal_approx(velocity) \
		and level._death_surface == profile,
		"Continue preserves actual knockback momentum, position and the retained death-graph identity")
	var transition_on_floor: bool = false
	for tick: int in range(90):
		await _ticks(1)
		if level._death_in_progress:
			transition_on_floor = level.player.is_on_floor()
			break
	_check(transition_on_floor and not level.player.in_native_damage and level.lives == life_count,
		"pending state5 enters death only on the resolved floor and does not spend another life")
	var action: String = "contact_death_g069_r0192_o000004f0"
	if level.player._visual.using_original_animation and level.player._visual.original_animation.has_action(action):
		_check(level.player._visual.original_animation.current_action == action \
			and not level.player._visual.native_presentation.shadow.visible,
			"retained contact death graph replaces the body after landing and hides the ordinary shadow")
	for tick: int in range(180):
		await _ticks(1)
		if not level._death_in_progress:
			break
	if last_life:
		_check(level.lives == 0 and level.health == 0 and level.hud.modal.visible and not level.player.controls_enabled,
			"last pending life reaches game over after the death animation")
		_check(not level.damage_player(1000, level.player.global_position) and not level.player.apply_damage(1000),
			"finished state6 still rejects force damage until native reset")
	else:
		_check(level.health == level.max_health and level.lives == 3 and not level.player.pending_fatal \
			and not level.player.in_native_damage and level._death_surface.is_empty(),
			"native checkpoint reset clears pending, retained graph and damage state without another life loss")
	level.free()
	await _ticks(2)


func _legacy_death_save() -> void:
	var level := Fixture.new()
	level.restored_run = {"health": 0, "lives": 3, "death_pending": true}
	root.add_child(level)
	await _ticks(5)
	_check(level.health == level.max_health and level.lives == 3 and not level.player.pending_fatal,
		"legacy v2 death saves without the optional state5 fields keep checkpoint recovery")
	level.free()
	await _ticks(2)


func _surface_invulnerability() -> void:
	var level := Fixture.new()
	root.add_child(level)
	await _ticks(8)
	level.damage_player(1, level.player.global_position, 0.0)
	level.add_hazard(1000, 0.25, 1)
	await _ticks(8)
	_check(level.health == 8 and level.lives == 4 and not level._death_in_progress,
		"actual lethal ground surface respects invulnerability instead of using the direct force-hit bypass")
	_check(is_equal_approx(level.player._native_surface_response, 0.25) and level.player._native_surface_prevents_standing,
		"damage protection does not discard the actual floor movement response and standing constraint")
	for tick: int in range(135):
		await _ticks(1)
		if level._death_in_progress:
			break
	_check(level._death_in_progress and level.lives == 3,
		"the same actual ground surface becomes lethal after its gate expires")
	level.free()
	await _ticks(2)


func _surface_without_contact_timer() -> void:
	var level := Fixture.new()
	root.add_child(level)
	Input.action_press("crouch")
	await _ticks(8)
	_check(level.player.is_crouching, "nonfatal surface fixture begins in a real input-driven crawl")
	level.add_hazard(1)
	for tick: int in range(10):
		await _ticks(1)
		if level.health < level.max_health:
			break
	_release()
	_check(level.health == 8 and level.lives == 4 and level.player._jump_in_progress \
		and level.player.velocity.y > 0.0 and not level.player.is_crouching and not level.player.in_native_damage \
		and not level.player.is_invulnerable and is_zero_approx(level._damage_remaining),
		"actual nonfatal ground damage sends crawl to Jump without contact hurt or either damage timer")
	var landing_ticks: int = 0
	for tick: int in range(90):
		await _ticks(1)
		landing_ticks += 1
		if level.health < 8:
			break
	_check(level.health == 6 and level.lives == 4 and level.player._jump_in_progress \
		and landing_ticks < 90 and not level.player.is_invulnerable,
		"next actual landing receives difficulty-adjusted ground damage before a contact timer could expire")
	_check(level.damage_player(1, level.player.global_position, 0.0) and level.health == 4 \
		and level.player.is_invulnerable and level._damage_remaining > 0.0,
		"a contact hit immediately after ground damage is accepted and starts its own protection")
	for tick: int in range(90):
		await _ticks(1)
		if level.player.is_on_floor() and not level.player._jump_in_progress:
			break
	await _ticks(3)
	_check(level.player.is_on_floor() and level.player.is_invulnerable and level.health == 4 and level.lives == 4,
		"actual ground damage respects the protection created by the subsequent contact hit")
	level.free()
	await _ticks(2)


func _source_contact_death() -> void:
	var path: String = "res://assets/generated/gameplay_manifest.json"
	if not FileAccess.file_exists(path):
		return
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var ordinary: Dictionary = source.get("levels", {}).get("g006", {}).get("owners", {}).get("g008_o0146_t10300", {})
	if not ordinary.is_empty():
		var ordinary_level := Fixture.new()
		root.add_child(ordinary_level)
		await _ticks(8)
		var ordinary_actor := NativeStateActor.new()
		ordinary_actor.source_id = "g008_o0146_t10300"
		ordinary_actor.native = ordinary
		ordinary_actor.level = ordinary_level
		ordinary_actor.visual = Node3D.new()
		ordinary_level.add_child(ordinary_actor.visual)
		ordinary_actor.visual.position.x = -1.0
		ordinary_level.add_child(ordinary_actor)
		ordinary_actor.set_physics_process(false)
		var ordinary_graph := NativeGraphColliders.new()
		ordinary_graph.player = ordinary_level.player
		_check(ordinary.state_machine.get("contact_death_visual", {}) == null,
			"ordinary source actor explicitly declares a null optional death graph")
		ordinary_actor.receive_logic_collision({"category": 8}, {}, ordinary_graph)
		ordinary_graph.free()
		_check(ordinary_level.health == 7 and ordinary_level.lives == 4 and ordinary_level.player.in_native_damage,
			"ordinary source actor with a null graph still delivers contact damage and knockback")
		ordinary_level.free()
		await _ticks(2)
	var native: Dictionary = source.get("levels", {}).get("g069", {}).get("owners", {}).get("g069_o0192_t10300", {})
	var machine: Dictionary = native.get("state_machine", {})
	if machine.get("contact_death_visual", {}).is_empty():
		return
	source_contact_checked = true
	var level := Fixture.new()
	root.add_child(level)
	await _ticks(8)
	var actor := NativeStateActor.new()
	actor.source_id = "g069_o0192_t10300"
	actor.native = native
	actor.level = level
	actor.visual = Node3D.new()
	level.add_child(actor.visual)
	actor.visual.position.x = -1.0
	level.add_child(actor)
	actor.set_physics_process(false)
	actor.receive_event(0x22000001)
	var graph := NativeGraphColliders.new()
	graph.player = level.player
	var at: Vector3 = level.player.global_position
	actor.receive_logic_collision({"category": 8}, {}, graph)
	graph.free()
	var action: String = "contact_death_g069_r0192_o000004f0"
	_check(level._death_in_progress and level.lives == 3 and not level.player.pending_fatal,
		"actual Escape state actor transmits its native1000 damage through the production contact handler")
	_check(level.player._visual.original_animation.current_action == action \
		and absf(level.player._death_remaining - 2.0) < 0.0001,
		"actual Escape contact graph plays its source two-second action")
	var voices: Array[NativeSound] = []
	for child: Node in level.get_children():
		if child is NativeSound:
			voices.append(child)
	_check(voices.size() == 1 and voices[0].settings.get("resource_id") == 29 \
		and voices[0].playing and voices[0].global_position.is_equal_approx(at),
		"force-death phase0 plays the original Escape WAV29 once at the hit position")
	await _ticks(8)
	_check(level._death_sound_cues_played.size() == 1 and not level.player._visual.native_presentation.shadow.visible,
		"advancing the replacement death does not replay its cue or draw the ordinary shadow")
	level.free()
	await _ticks(2)


func _save_and_read(run: Dictionary) -> Dictionary:
	var state := CampaignState.new()
	state.path = TEST_PATH
	state.set_run(LEVEL_ID, run)
	_check(state.write_save(), "pending flight writes through the real v2 save pipeline")
	var read := CampaignState.new()
	read.path = TEST_PATH
	_check(read.read_save([LEVEL_ID]), "pending flight reads through the real v2 validator")
	return read.runs.get(LEVEL_ID, {})


func _save_validation() -> void:
	var state := CampaignState.new()
	state.set_run(LEVEL_ID, {"health": 7, "death_pending": false,
		"player_runtime": {"schema_version": 1, "velocity": [0, 0, 0], "native_damage": true,
			"pending_fatal": true, "damage_impulse": [NAN, 0, 0]},
		"death_visual": {"kind": "../../outside", "group": 69, "record": 192, "offset": 1264}})
	var saved: Dictionary = state.runs[LEVEL_ID]
	_check(not saved.player_runtime.pending_fatal and saved.player_runtime.damage_impulse == [0.0, 0.0, 0.0],
		"malformed or contradictory pending state cannot create permanent damage immunity")
	_check(not saved.has("death_visual") and CampaignState.clean_death_visual({"kind": "contact", "group": INF, "record": 192, "offset": 1264}).is_empty(),
		"death graph saves accept only finite source identities, never resource paths")


func _ticks(count: int) -> void:
	for index: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _release() -> void:
	for action: String in ["move_left", "move_right", "move_forward", "move_back", "jump", "crouch", "attack"]:
		Input.action_release(action)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
