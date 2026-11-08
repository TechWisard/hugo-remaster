class_name HugoPlayer
extends CharacterBody3D
## Test-scene controller. The node origin is at the character's feet.
## This movement is newly authored; it does not reproduce the original game's physics.

signal respawned

const VisualScript = preload("res://scripts/player_visual.gd")

@export_group("Movement")
@export_range(0.1, 20.0, 0.1) var walk_speed: float = 4.8
@export_range(0.1, 25.0, 0.1) var sprint_speed: float = 7.6
@export_range(0.1, 100.0, 0.1) var ground_acceleration: float = 32.0
@export_range(0.1, 100.0, 0.1) var ground_braking: float = 42.0
@export_range(0.1, 60.0, 0.1) var air_acceleration: float = 12.0
@export var controls_enabled: bool = true

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
@export_range(1.0, 3.0, 0.05) var character_height: float = 1.7
@export_range(-180.0, 180.0, 1.0) var model_yaw_degrees: float = 0.0
@export_range(1.0, 30.0, 0.5) var visual_turn_speed: float = 14.0

@export_group("Recovery")
@export var fall_reset_height: float = -25.0

## A camera may be assigned directly after adding this player to the tree.
var movement_camera: Camera3D
var visual_root: Node3D
var using_imported_model: bool = false

var _visual: HugoPlayerVisual
var _checkpoint_position: Vector3 = Vector3.ZERO
var _checkpoint_facing: float = 0.0
var _checkpoint_is_set: bool = false
var _coyote_remaining: float = 0.0
var _jump_buffer_remaining: float = 0.0
var _jump_in_progress: bool = false
var _fresh_respawn: bool = false
var _suppress_jump_until_release: bool = false


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.24
	floor_stop_on_slope = true
	floor_constant_speed = true
	safe_margin = 0.015
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
	if global_position.y < fall_reset_height:
		respawn()
		return
	if controls_enabled and Input.is_action_just_pressed("reset"):
		respawn()
		return

	# Floor flags describe the previous move_and_slide() call. Ignore a stale
	# floor flag after teleporting, or after a buffered jump set upward velocity.
	var grounded: bool = is_on_floor() and not _fresh_respawn and velocity.y <= 0.0
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
		jump_held = Input.is_action_pressed("jump")
		var jump_pressed: bool = Input.is_action_just_pressed("jump")
		if _suppress_jump_until_release:
			if not jump_held and not jump_pressed:
				_suppress_jump_until_release = false
		elif jump_pressed:
			_jump_buffer_remaining = jump_buffer_time
		if Input.is_action_pressed("sprint"):
			speed = sprint_speed
	else:
		_jump_buffer_remaining = 0.0

	var move_direction: Vector3 = _camera_relative_direction(input_vector)
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
	_fresh_respawn = false

	# Consume a buffered press on the very step that reaches the floor. The
	# upward displacement starts next physics tick, without another input press.
	if is_on_floor() and velocity.y <= 0.0:
		_jump_in_progress = false
		if controls_enabled and _jump_buffer_remaining > 0.0:
			_start_jump()
	if is_on_ceiling():
		_jump_in_progress = false

	if global_position.y < fall_reset_height:
		respawn()
		return
	_update_visual(move_direction, delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_jump_buffer_remaining = 0.0
	elif what == NOTIFICATION_UNPAUSED:
		# Space / gamepad A can activate Continue. Input polling still sees that
		# same event after the UI consumes it, so require a fresh jump press.
		_suppress_jump_until_release = true


func set_checkpoint(world_position: Vector3) -> void:
	if not world_position.is_finite():
		return
	_checkpoint_position = world_position
	_checkpoint_is_set = true
	if is_instance_valid(visual_root):
		_checkpoint_facing = visual_root.global_rotation.y


func respawn() -> void:
	if not _checkpoint_is_set:
		set_checkpoint(global_position)
	global_position = _checkpoint_position
	velocity = Vector3.ZERO
	_coyote_remaining = 0.0
	_jump_buffer_remaining = 0.0
	_jump_in_progress = false
	_fresh_respawn = true
	_suppress_jump_until_release = true
	if is_instance_valid(visual_root):
		visual_root.global_rotation = Vector3(0.0, _checkpoint_facing, 0.0)
	if is_instance_valid(_visual):
		_visual.reset_pose()
	reset_physics_interpolation()
	respawned.emit()


func _start_jump() -> void:
	velocity.y = 2.0 * jump_height / jump_time_to_apex
	_jump_buffer_remaining = 0.0
	_coyote_remaining = 0.0
	_jump_in_progress = true


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
	_visual.update_motion(local_velocity, is_on_floor() and not _jump_in_progress, delta)


func _ensure_collision_shape() -> void:
	# Respect a collision shape supplied by a hand-authored scene.
	for child: Node in get_children():
		var existing_shape: CollisionShape3D = child as CollisionShape3D
		if existing_shape != null and existing_shape.shape != null and not existing_shape.disabled:
			return
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.31
	capsule.height = character_height
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = capsule
	collider.position.y = character_height * 0.5
	add_child(collider)
