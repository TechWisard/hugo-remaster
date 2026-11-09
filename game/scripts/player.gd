class_name HugoPlayer
extends CharacterBody3D
## The node origin is at the character's feet. The default is the authored
## prototype controller; set_native_configuration enables recovered movement
## constants and 300-Hz integration while Godot still resolves world contacts.

signal respawned
signal attack_started
signal hurt_received(amount: int)
signal crouch_changed(crouching: bool)
signal reset_requested(reason: String)
signal death_animation_finished

const VisualScript = preload("res://scripts/player_visual.gd")

@export_group("Movement")
@export_range(0.1, 20.0, 0.1) var walk_speed: float = 4.8
@export_range(0.1, 25.0, 0.1) var sprint_speed: float = 7.6
@export_range(0.1, 100.0, 0.1) var ground_acceleration: float = 32.0
@export_range(0.1, 100.0, 0.1) var ground_braking: float = 42.0
@export_range(0.1, 60.0, 0.1) var air_acceleration: float = 12.0
@export var controls_enabled: bool = true

@export_group("Compatibility actions")
## Contact/damage policy is implemented by the world. These durations are
## compatibility controls; only the recovered visual clips are native data.
@export_range(0.4, 0.9, 0.01) var crouch_height_ratio: float = 0.58
@export_range(0.1, 1.0, 0.05) var crouch_speed_ratio: float = 0.45
@export_range(0.05, 2.0, 0.01) var attack_duration: float = 0.3666667
@export_range(0.0, 2.0, 0.01) var attack_recovery: float = 0.12
@export_range(0.0, 2.0, 0.01) var hurt_duration: float = 0.3333333
@export_range(0.0, 5.0, 0.05) var invulnerability_duration: float = 2.0

@export_group("Jump")
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.65
@export_range(0.1, 1.0, 0.01) var jump_time_to_apex: float = 0.4
@export_range(1.0, 4.0, 0.05) var falling_gravity_multiplier: float = 1.6
@export_range(1.0, 6.0, 0.05) var released_jump_gravity_multiplier: float = 3.0
@export_range(0.01, 0.3, 0.01) var coyote_time: float = 0.12
@export_range(0.01, 0.3, 0.01) var jump_buffer_time: float = 0.14
@export_range(1.0, 100.0, 1.0) var terminal_velocity: float = 45.0

@export_group("Presentation")
@export_node_path("Camera3D") var camera_path: NodePath
@export_file("*.glb", "*.gltf", "*.tscn") var model_path: String = "res://assets/generated/hugo.glb"
@export_range(0.5, 8.0, 0.05) var character_height: float = 1.7
@export_range(-180.0, 180.0, 1.0) var model_yaw_degrees: float = 0.0
@export_range(1.0, 30.0, 0.5) var visual_turn_speed: float = 14.0

@export_group("Recovery")
@export var fall_reset_height: float = -25.0
@export var native_reset_handling: bool = false

## A camera may be assigned directly after adding this player to the tree.
var movement_camera: Camera3D
var visual_root: Node3D
var using_imported_model: bool = false
var using_native_movement: bool = false
var native_configuration: Dictionary = {}
var is_crouching: bool = false
var attack_serial: int = 0
var is_attacking: bool:
	get:
		return _attack_remaining > 0.0
var is_invulnerable: bool:
	get:
		return _invulnerability_remaining > 0.0
var is_hurt: bool:
	get:
		return _hurt_remaining > 0.0

var _visual: HugoPlayerVisual
var _checkpoint_position: Vector3 = Vector3.ZERO
var _checkpoint_facing: float = 0.0
var _checkpoint_is_set: bool = false
var _coyote_remaining: float = 0.0
var _jump_buffer_remaining: float = 0.0
var _jump_in_progress: bool = false
var _fresh_respawn: bool = false
var _resume_grounded: bool = false
var _suppress_jump_until_release: bool = false
var _suppress_attack_until_release: bool = false
var _attack_remaining: float = 0.0
var _attack_recovery_remaining: float = 0.0
var _hurt_remaining: float = 0.0
var _invulnerability_remaining: float = 0.0
var _collider: CollisionShape3D
var _standing_capsule: CapsuleShape3D
var _crouching_capsule: CapsuleShape3D
var _standing_collider_position: Vector3 = Vector3.ZERO
var _jump_visual_action: String = "jump"
var _reset_pending: bool = false
var _death_playing: bool = false
var _death_remaining: float = 0.0
var _death_action: String = "death"
var _controls_before_death: bool = true
var _restore_death_controls: bool = false
var _native_standing_box: BoxShape3D
var _native_crouching_box: BoxShape3D
var _native_tick_fraction: float = 0.0
var _native_jump_origin_y: float = 0.0
var _native_input_magnitude: float = 0.0
var _native_landing_remaining: float = 0.0
var _native_surface_response: float = 1.0
var _native_surface_prevents_standing: bool = false


func set_native_configuration(configuration: Dictionary) -> bool:
	## Call before add_child(). Empty/missing source data keeps prototype mode.
	if int(configuration.get("schema_version", 0)) != 1:
		return false
	for key: String in ["native_timer_hz", "ground_max_speed", "crawl_speed", "jump_initial_velocity", "jump_gravity", "jump_horizontal_speed", "fall_gravity", "fall_terminal_speed"]:
		var value: float = float(configuration.get(key, 0.0))
		if not is_finite(value) or value <= 0.0:
			return false
	for key: String in ["standing_box_size", "crouching_box_size"]:
		var size: Vector3 = _configuration_vector(configuration.get(key, []))
		if not size.is_finite() or minf(size.x, minf(size.y, size.z)) <= 0.0:
			return false
	native_configuration = configuration.duplicate(true)
	using_native_movement = true
	# .6C is a visual threshold, not an authored walking speed. Digital input
	# uses the full .68 speed; the prototype sprint binding adds no native boost.
	walk_speed = float(configuration["ground_max_speed"])
	sprint_speed = walk_speed
	jump_height = float(configuration.get("jump_height", jump_height))
	jump_time_to_apex = float(configuration.get("jump_half_ticks", 120)) / float(configuration["native_timer_hz"])
	terminal_velocity = float(configuration["fall_terminal_speed"])
	invulnerability_duration = float(configuration.get("invulnerability_seconds", 2.0))
	attack_recovery = 0.0
	coyote_time = 0.0
	jump_buffer_time = 1.0 / float(configuration["native_timer_hz"])
	_native_tick_fraction = 0.0
	if is_node_ready():
		_ensure_native_collision_shape()
	return true


func set_native_surface(response_coefficient: float = 1.0, prevents_standing: bool = false) -> void:
	## The world supplies the source face's +0x10 coefficient and +0x18 flag.
	if is_finite(response_coefficient) and response_coefficient >= 0.0:
		_native_surface_response = response_coefficient
	_native_surface_prevents_standing = prevents_standing


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.24 * character_height / 1.7
	floor_stop_on_slope = true
	floor_constant_speed = true
	safe_margin = 0.015 * character_height / 1.7
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_ADD_UPWARD_VELOCITY
	_ensure_collision_shape()

	_visual = VisualScript.new() as HugoPlayerVisual
	_visual.name = "VisualRoot"
	visual_root = _visual
	add_child(_visual)
	_visual.build(model_path, character_height, model_yaw_degrees)
	using_imported_model = _visual.using_imported_model

	if not camera_path.is_empty():
		movement_camera = get_node_or_null(camera_path) as Camera3D
	if not _checkpoint_is_set:
		set_checkpoint(global_position)


func _physics_process(delta: float) -> void:
	_attack_remaining = maxf(0.0, _attack_remaining - delta)
	_attack_recovery_remaining = maxf(0.0, _attack_recovery_remaining - delta)
	_hurt_remaining = maxf(0.0, _hurt_remaining - delta)
	_invulnerability_remaining = maxf(0.0, _invulnerability_remaining - delta)
	_native_landing_remaining = maxf(0.0, _native_landing_remaining - delta)
	if _death_playing:
		_death_remaining = maxf(0.0, _death_remaining - delta)
		_visual.update_motion(Vector3.ZERO, false, delta, _death_action)
		if _death_remaining <= 0.0:
			_death_playing = false
			death_animation_finished.emit()
		return
	if global_position.y < fall_reset_height:
		_request_reset("fall")
		return
	if controls_enabled and Input.is_action_just_pressed("reset"):
		_request_reset("manual")
		return

	# Floor flags describe the previous move_and_slide() call. Ignore a stale
	# flag after teleporting or launching a jump, not an upward slope/platform
	# velocity: both still support grounded movement, crouching and new jumps.
	# A resumed grounded body has no floor flags yet. Recheck the restored world
	# before choosing its first movement mode, without trusting a saved contact RID.
	var resumed_floor: bool = false
	if _resume_grounded:
		apply_floor_snap()
		resumed_floor = is_on_floor()
		_resume_grounded = false
	var grounded: bool = is_on_floor() and (not _fresh_respawn or resumed_floor) and not _jump_in_progress
	_jump_buffer_remaining = maxf(0.0, _jump_buffer_remaining - delta)
	if grounded:
		_coyote_remaining = coyote_time
		_jump_in_progress = false
	else:
		_coyote_remaining = maxf(0.0, _coyote_remaining - delta)

	var input_vector: Vector2 = Vector2.ZERO
	var jump_held: bool = false
	var speed: float = walk_speed
	if controls_enabled:
		input_vector = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var crouch_pressed: bool = InputMap.has_action("crouch") and Input.is_action_pressed("crouch") and (not using_native_movement or grounded)
		set_crouching(crouch_pressed)
		if InputMap.has_action("attack"):
			var attack_held: bool = Input.is_action_pressed("attack")
			var attack_pressed: bool = Input.is_action_just_pressed("attack")
			if _suppress_attack_until_release:
				if not attack_held and not attack_pressed:
					_suppress_attack_until_release = false
			elif attack_pressed:
				start_attack()
		jump_held = Input.is_action_pressed("jump")
		var jump_pressed: bool = Input.is_action_just_pressed("jump")
		if _suppress_jump_until_release:
			if not jump_held and not jump_pressed:
				_suppress_jump_until_release = false
		elif jump_pressed and not is_crouching and not is_hurt:
			_jump_buffer_remaining = jump_buffer_time
		if Input.is_action_pressed("sprint"):
			speed = sprint_speed
	else:
		_jump_buffer_remaining = 0.0
	if is_crouching:
		speed = walk_speed * crouch_speed_ratio
		_jump_buffer_remaining = 0.0
	if is_hurt:
		input_vector = Vector2.ZERO
		_jump_buffer_remaining = 0.0

	var move_direction: Vector3 = _camera_relative_direction(input_vector)
	# A teleport does not clear CharacterBody3D's previous platform RID.
	# Ignore that stale contact for the first move, including angular carry
	# evaluated at the new checkpoint position, then restore normal carrying.
	var reset_platform_contact: bool = _fresh_respawn
	var saved_platform_floor_layers: int = platform_floor_layers
	var saved_platform_wall_layers: int = platform_wall_layers
	var saved_platform_leave: CharacterBody3D.PlatformOnLeave = platform_on_leave
	if reset_platform_contact:
		platform_floor_layers = 0
		platform_wall_layers = 0
		platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	if using_native_movement:
		_native_move(move_direction, grounded, delta)
	else:
		var target_velocity: Vector3 = move_direction * speed
		var acceleration: float = air_acceleration
		if grounded:
			acceleration = ground_acceleration if input_vector.length_squared() > 0.0001 else ground_braking
		var horizontal_velocity: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		horizontal_velocity = horizontal_velocity.move_toward(target_velocity, acceleration * delta)
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z
		if grounded:
			velocity.y = 0.0
		else:
			var gravity: float = 2.0 * jump_height / (jump_time_to_apex * jump_time_to_apex)
			if velocity.y < 0.0:
				gravity *= falling_gravity_multiplier
			elif _jump_in_progress and not jump_held:
				gravity *= released_jump_gravity_multiplier
			velocity.y = maxf(velocity.y - gravity * delta, -terminal_velocity)
		if _jump_buffer_remaining > 0.0 and _coyote_remaining > 0.0:
			_start_jump()
		move_and_slide()
	if reset_platform_contact:
		platform_floor_layers = saved_platform_floor_layers
		platform_wall_layers = saved_platform_wall_layers
		platform_on_leave = saved_platform_leave
	_fresh_respawn = false

	# Consume a buffered press on the very step that reaches the floor. The
	# upward displacement starts next physics tick, without another input press.
	if is_on_floor():
		_jump_in_progress = false
		if controls_enabled and _jump_buffer_remaining > 0.0:
			_start_jump()
	if is_on_ceiling():
		_jump_in_progress = false

	if global_position.y < fall_reset_height:
		_request_reset("fall")
		return
	_update_visual(move_direction, delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_jump_buffer_remaining = 0.0
	elif what == NOTIFICATION_UNPAUSED:
		# Space / gamepad A can activate Continue. Input polling still sees that
		# same event after the UI consumes it, so require a fresh jump press.
		_suppress_jump_until_release = true
		_suppress_attack_until_release = true


func set_checkpoint(world_position: Vector3) -> void:
	if not world_position.is_finite():
		return
	_checkpoint_position = world_position
	_checkpoint_is_set = true
	if is_instance_valid(visual_root):
		_checkpoint_facing = visual_root.global_rotation.y


func runtime_snapshot() -> Dictionary:
	## Modern Continue keeps a live action; native checkpoint reset stays cold.
	var result: Dictionary = {"schema_version": 1,
		"velocity": [velocity.x, velocity.y, velocity.z],
		"grounded": is_on_floor() and not _jump_in_progress,
		"jumping": _jump_in_progress, "jump_origin_y": _native_jump_origin_y,
		"jump_action": _jump_visual_action, "tick_fraction": _native_tick_fraction,
		"crouching": is_crouching, "landing_remaining": _native_landing_remaining,
		"attack_remaining": _attack_remaining, "attack_recovery_remaining": _attack_recovery_remaining,
		"hurt_remaining": _hurt_remaining, "invulnerability_remaining": _invulnerability_remaining}
	if _visual != null and _visual.using_original_animation:
		result["visual_action"] = _visual.original_animation.current_action
		result["visual_phase"] = _visual.original_animation.native_phase
	return result


func restore_runtime_state(saved: Dictionary) -> bool:
	## CampaignState validates the optional payload; old saves keep spawn defaults.
	if int(saved.get("schema_version", 0)) != 1 or not saved.get("velocity") is Array or saved.velocity.size() != 3:
		return false
	var resumed_velocity: Vector3 = _configuration_vector(saved.velocity)
	if not resumed_velocity.is_finite():
		return false
	velocity = resumed_velocity
	_jump_in_progress = bool(saved.get("jumping", false))
	_resume_grounded = bool(saved.get("grounded", false)) and not _jump_in_progress
	_native_jump_origin_y = float(saved.get("jump_origin_y", global_position.y))
	_jump_visual_action = str(saved.get("jump_action", "jump"))
	_native_tick_fraction = float(saved.get("tick_fraction", 0.0))
	set_crouching(bool(saved.get("crouching", false)))
	_native_landing_remaining = float(saved.get("landing_remaining", 0.0))
	_attack_remaining = float(saved.get("attack_remaining", 0.0))
	_attack_recovery_remaining = float(saved.get("attack_recovery_remaining", 0.0))
	_hurt_remaining = float(saved.get("hurt_remaining", 0.0))
	_invulnerability_remaining = float(saved.get("invulnerability_remaining", 0.0))
	# UI activation must not become a new jump or attack, and physics contacts
	# belong to the recreated world rather than the saved CharacterBody RID.
	_jump_buffer_remaining = 0.0
	_coyote_remaining = 0.0
	_fresh_respawn = true
	_suppress_jump_until_release = true
	_suppress_attack_until_release = true
	if _visual != null and _visual.using_original_animation:
		var animation: HugoOriginalAnimation = _visual.original_animation
		var action: String = str(saved.get("visual_action", ""))
		if animation.has_action(action):
			animation.set_action(action, true)
			animation.seek_phase(float(saved.get("visual_phase", 0.0)))
	reset_physics_interpolation()
	return true


func respawn() -> void:
	if not _checkpoint_is_set:
		set_checkpoint(global_position)
	global_position = _checkpoint_position
	velocity = Vector3.ZERO
	_coyote_remaining = 0.0
	_jump_buffer_remaining = 0.0
	_jump_in_progress = false
	_resume_grounded = false
	_jump_visual_action = "jump"
	_fresh_respawn = true
	_suppress_jump_until_release = true
	_suppress_attack_until_release = true
	_attack_remaining = 0.0
	_attack_recovery_remaining = 0.0
	_hurt_remaining = 0.0
	_invulnerability_remaining = 0.0
	_reset_pending = false
	_death_playing = false
	_death_remaining = 0.0
	_death_action = "death"
	_native_tick_fraction = 0.0
	_native_landing_remaining = 0.0
	_native_surface_response = 1.0
	_native_surface_prevents_standing = false
	if _restore_death_controls:
		controls_enabled = _controls_before_death
		_restore_death_controls = false
	# Teleporting to a checkpoint must not force a full-height body into a low
	# ceiling. set_crouching(false) performs the same occupancy check as input.
	set_crouching(false)
	if is_instance_valid(visual_root):
		visual_root.global_rotation = Vector3(0.0, _checkpoint_facing, 0.0)
	if is_instance_valid(_visual):
		_visual.reset_pose()
	reset_physics_interpolation()
	respawned.emit()


func start_attack() -> bool:
	if not controls_enabled or is_hurt or is_crouching or (not using_native_movement and not is_on_floor()) or _attack_recovery_remaining > 0.0:
		return false
	_attack_remaining = attack_duration
	_attack_recovery_remaining = attack_duration + attack_recovery
	attack_serial += 1
	if _visual != null and _visual.using_original_animation:
		_visual.original_animation.set_action("attack", true)
	attack_started.emit()
	return true


func apply_damage(amount: int = 1, knockback: Vector3 = Vector3.ZERO) -> bool:
	## The world owns health/lives. A successful call emits one damage event.
	# Native CHugo uses 600 timer ticks (2 s); damage >= 1000 bypasses it.
	if amount <= 0 or (is_invulnerable and amount < 1000):
		return false
	_invulnerability_remaining = invulnerability_duration
	_hurt_remaining = hurt_duration
	_attack_remaining = 0.0
	_jump_buffer_remaining = 0.0
	if knockback.is_finite():
		velocity += knockback
	if _visual != null and _visual.using_original_animation:
		_visual.original_animation.set_action("hurt", true)
	hurt_received.emit(amount)
	return true


func bounce_from_native_surface() -> bool:
	## 0x403054..0x403094: surviving ground damage enters Jump, not Hurt.
	## The world calls this only after an accepted, non-lethal surface hit.
	if not using_native_movement or _death_playing:
		return false
	_hurt_remaining = 0.0
	_attack_remaining = 0.0
	set_crouching(false)
	_start_jump()
	if _visual != null and _visual.using_original_animation:
		_visual.original_animation.set_action(_jump_visual_action, true)
	return true


func _request_reset(reason: String) -> void:
	if not native_reset_handling:
		respawn()
	elif not _reset_pending:
		_reset_pending = true
		reset_requested.emit(reason)


func play_death(action: String = "death") -> float:
	if _death_playing and action == _death_action:
		return _death_remaining
	if not _death_playing:
		_controls_before_death = controls_enabled
		_restore_death_controls = true
	controls_enabled = false
	_reset_pending = true
	_attack_remaining = 0.0
	_hurt_remaining = 0.0
	_jump_buffer_remaining = 0.0
	velocity = Vector3.ZERO
	_death_remaining = 0.3333333
	_death_action = "death"
	if _visual != null and _visual.using_original_animation:
		var animation: HugoOriginalAnimation = _visual.original_animation
		if animation.has_action(action):
			_death_action = action
		animation.set_action(_death_action, true)
		var clips: Dictionary = animation.manifest.get("clips", {}) as Dictionary
		var clip: Dictionary = clips.get(animation.current_clip, {}) as Dictionary
		_death_remaining = maxf(0.01, float(clip.get("authored_duration_seconds", _death_remaining)))
	_death_playing = true
	return _death_remaining


func play_death_for_surface(source_group: int, source_record: int, graph_offset: int) -> float:
	var action: String = "surface_death_g%03d_r%04d_o%08x" % [source_group, source_record, graph_offset]
	return play_death(action)


func get_native_visual_action() -> int:
	if _visual != null and _visual.using_original_animation:
		var clip: String = _visual.original_animation.current_clip
		return int(clip.trim_prefix("action_")) if clip.begins_with("action_") else -1
	return 2 if is_attacking else 0


func get_native_visual_phase() -> float:
	if _visual != null and _visual.using_original_animation:
		return _visual.original_animation.native_phase
	return 0.0


func get_native_visual_transform() -> Transform3D:
	if _visual != null:
		var source: Node3D = _visual.get_node_or_null("Pose/NormalizedModel/SourceOrientation") as Node3D
		if source != null:
			return source.global_transform
	return visual_root.global_transform if is_instance_valid(visual_root) else global_transform


func get_facing_direction() -> Vector3:
	return -visual_root.global_basis.z.normalized() if is_instance_valid(visual_root) else Vector3.FORWARD


func set_crouching(crouching: bool) -> bool:
	if crouching == is_crouching:
		return true
	if _collider == null:
		return false
	if using_native_movement and (_native_standing_box == null or _native_crouching_box == null):
		return false
	if not using_native_movement and (_standing_capsule == null or _crouching_capsule == null):
		return false
	if not crouching and not can_stand():
		return false
	is_crouching = crouching
	if using_native_movement:
		_collider.shape = _native_crouching_box if crouching else _native_standing_box
		_collider.position = Vector3.UP * (_native_crouching_box.size.y if crouching else _native_standing_box.size.y) * 0.5
	else:
		_collider.shape = _crouching_capsule if crouching else _standing_capsule
		_collider.position = _standing_collider_position
		if crouching:
			_collider.position.y -= (_standing_capsule.height - _crouching_capsule.height) * 0.5
	if crouching:
		_attack_remaining = 0.0
	crouch_changed.emit(crouching)
	return true


func can_stand() -> bool:
	if not is_crouching or not is_inside_tree():
		return true
	if using_native_movement and _native_surface_prevents_standing:
		return false
	var standing_shape: Shape3D = _native_standing_box if using_native_movement else _standing_capsule
	if standing_shape == null:
		return true
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = standing_shape
	query.transform = global_transform * Transform3D(Basis.IDENTITY, _standing_collider_position)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _start_jump() -> void:
	_jump_visual_action = "jump_moving" if Vector2(velocity.x, velocity.z).length() >= walk_speed * 0.5 else "jump"
	if using_native_movement:
		_jump_visual_action = "jump_moving" if _native_input_magnitude >= 0.5 else "jump"
		_native_jump_origin_y = global_position.y
		global_position.y += float(native_configuration.get("jump_position_lift", 0.01))
		velocity.y = float(native_configuration["jump_initial_velocity"])
		var horizontal_ratio: float = float(native_configuration["jump_horizontal_speed"]) / float(native_configuration["ground_max_speed"])
		velocity.x *= horizontal_ratio
		velocity.z *= horizontal_ratio
		_native_landing_remaining = 0.0
	else:
		velocity.y = 2.0 * jump_height / jump_time_to_apex
	_jump_buffer_remaining = 0.0
	_coyote_remaining = 0.0
	_jump_in_progress = true


func _native_move(move_direction: Vector3, grounded: bool, delta: float) -> void:
	_native_input_magnitude = minf(move_direction.length(), 1.0)
	if grounded and _native_input_magnitude > 0.0:
		_native_landing_remaining = 0.0
	if grounded and _jump_buffer_remaining > 0.0:
		_start_jump()
		grounded = false
	if _jump_in_progress and global_position.y < _native_jump_origin_y - float(native_configuration.get("jump_drop_to_fall_distance", 3.0)):
		_jump_in_progress = false
	var rate: float = float(native_configuration["native_timer_hz"])
	_native_tick_fraction += delta * rate
	var ticks: int = int(floor(_native_tick_fraction + 0.000001))
	_native_tick_fraction = maxf(0.0, _native_tick_fraction - float(ticks))
	var target_speed: float = float(native_configuration["ground_max_speed"])
	var response: float = float(native_configuration["ground_response_per_tick"])
	var gravity: float = 0.0
	if grounded:
		velocity.y = 0.0
		if is_crouching:
			target_speed = float(native_configuration["crawl_speed"])
			response = minf(float(native_configuration["crawl_response_per_tick"]), _native_surface_response)
		elif _native_input_magnitude <= 0.0:
			response = minf(response, _native_surface_response)
		elif _native_surface_response < 1.0:
			response = minf(response, _native_surface_response)
		else:
			target_speed /= _native_surface_response
	elif _jump_in_progress:
		target_speed = float(native_configuration["jump_horizontal_speed"])
		response = float(native_configuration["jump_response_per_tick"])
		gravity = float(native_configuration["jump_gravity"])
	else:
		target_speed = float(native_configuration["fall_horizontal_speed"])
		response = float(native_configuration["fall_response_per_tick"])
		gravity = float(native_configuration["fall_gravity"])
	var desired: Vector3 = move_direction * target_speed
	var displacement: Vector3 = Vector3.ZERO
	# Native code repeats this recurrence for elapsed 300-Hz ticks and then
	# submits its summed displacement to collision resolution once per update.
	for tick: int in range(ticks):
		velocity.x = lerpf(velocity.x, desired.x, response)
		velocity.z = lerpf(velocity.z, desired.z, response)
		if grounded and not is_crouching and _native_input_magnitude <= 0.0 and Vector2(velocity.x, velocity.z).length_squared() < float(native_configuration.get("stop_speed_squared", 0.9)):
			velocity.x = 0.0
			velocity.z = 0.0
		displacement += velocity / rate
		if not grounded:
			velocity.y -= gravity / rate
			if not _jump_in_progress:
				velocity.y = maxf(velocity.y, -float(native_configuration["fall_terminal_speed"]))
	var final_velocity: Vector3 = velocity
	var commanded_velocity: Vector3 = displacement / delta if delta > 0.0 else Vector3.ZERO
	velocity = commanded_velocity
	move_and_slide()
	# Keep per-tick momentum, plus platform carry returned by Godot, while
	# projecting blocked components off actual contact normals.
	velocity = final_velocity + velocity - commanded_velocity
	for index: int in range(get_slide_collision_count()):
		var normal: Vector3 = get_slide_collision(index).get_normal()
		if velocity.dot(normal) < 0.0:
			velocity = velocity.slide(normal)
	if is_on_floor():
		velocity.y = 0.0
		if not grounded:
			_native_landing_remaining = 0.4
			if _visual != null and _visual.using_original_animation:
				_visual.original_animation.set_action("land", true)


func _camera_relative_direction(input_vector: Vector2) -> Vector3:
	if input_vector.length_squared() < 0.0001:
		return Vector3.ZERO
	if not is_instance_valid(movement_camera):
		movement_camera = get_viewport().get_camera_3d()
	if not is_instance_valid(movement_camera):
		return Vector3(input_vector.x, 0.0, input_vector.y)

	var forward: Vector3 = -movement_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var right: Vector3 = forward.cross(Vector3.UP)
	return right * input_vector.x - forward * input_vector.y


func _update_visual(move_direction: Vector3, delta: float) -> void:
	if not is_instance_valid(visual_root):
		return
	if move_direction.length_squared() > 0.0001:
		var target_yaw: float = atan2(-move_direction.x, -move_direction.z)
		var turn_weight: float = 1.0 - exp(-visual_turn_speed * delta)
		var next_yaw: float = lerp_angle(visual_root.global_rotation.y, target_yaw, turn_weight)
		visual_root.global_rotation = Vector3(0.0, next_yaw, 0.0)
	var local_velocity: Vector3 = visual_root.global_basis.orthonormalized().inverse() * velocity
	var action: String = ""
	if is_hurt:
		action = "hurt"
	elif is_attacking:
		action = "attack"
	elif using_native_movement and _native_landing_remaining > 0.0:
		action = "land"
	elif is_crouching:
		action = "crawl" if Vector2(velocity.x, velocity.z).length() > 0.08 * character_height / 1.7 else "crouch"
	elif not is_on_floor() or _jump_in_progress:
		if velocity.y > 0.0 or (using_native_movement and _jump_in_progress):
			action = _jump_visual_action
		else:
			action = "fall"
	else:
		var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
		if horizontal_speed < 0.08 * character_height / 1.7:
			action = "idle"
		else:
			var run_threshold: float = float(native_configuration["walk_run_animation_threshold"]) if using_native_movement else (walk_speed + sprint_speed) * 0.5
			action = "run" if horizontal_speed > run_threshold else "walk"
	_visual.update_motion(local_velocity, is_on_floor() and not _jump_in_progress, delta, action)


func _ensure_collision_shape() -> void:
	if using_native_movement:
		_ensure_native_collision_shape()
		return
	# Respect a collision shape supplied by a hand-authored scene.
	for child: Node in get_children():
		var existing_shape: CollisionShape3D = child as CollisionShape3D
		if existing_shape != null and existing_shape.shape != null and not existing_shape.disabled:
			_configure_crouch(existing_shape)
			return
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = character_height * (0.31 / 1.7)
	capsule.height = character_height
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = capsule
	collider.position.y = character_height * 0.5
	add_child(collider)
	_configure_crouch(collider)


func _configure_crouch(collider: CollisionShape3D) -> void:
	var capsule: CapsuleShape3D = collider.shape as CapsuleShape3D
	if capsule == null:
		return
	_collider = collider
	_standing_collider_position = collider.position
	_standing_capsule = capsule.duplicate() as CapsuleShape3D
	_crouching_capsule = capsule.duplicate() as CapsuleShape3D
	_crouching_capsule.height = maxf(_standing_capsule.radius * 2.0, _standing_capsule.height * crouch_height_ratio)
	_collider.shape = _standing_capsule


func _ensure_native_collision_shape() -> void:
	if _collider == null:
		_collider = CollisionShape3D.new()
		_collider.name = "CollisionShape3D"
		add_child(_collider)
	_native_standing_box = BoxShape3D.new()
	_native_standing_box.size = _configuration_vector(native_configuration["standing_box_size"])
	_native_crouching_box = BoxShape3D.new()
	_native_crouching_box.size = _configuration_vector(native_configuration["crouching_box_size"])
	_standing_collider_position = Vector3.UP * _native_standing_box.size.y * 0.5
	_collider.shape = _native_standing_box
	_collider.position = _standing_collider_position
	is_crouching = false
	# Small Godot-only floor adhesion; authored jump height must not be eaten
	# by the prototype's much longer snap distance on the descending arc.
	floor_snap_length = 0.03
	safe_margin = 0.01


func _configuration_vector(value: Variant) -> Vector3:
	if value is Array:
		var items: Array = value as Array
		if items.size() == 3:
			return Vector3(float(items[0]), float(items[1]), float(items[2]))
	return Vector3.ZERO
