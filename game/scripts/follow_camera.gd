class_name HugoFollowCamera
extends Node3D
## Orbit rig with collision protection. Add as a world-space sibling of the player.
## Right mouse drag or the right gamepad stick rotates; the wheel changes distance.

@export_node_path("Node3D") var target_path: NodePath
@export_range(0.0, 3.0, 0.05) var target_height: float = 1.05
@export_range(1.0, 15.0, 0.1) var orbit_distance: float = 5.8
@export_range(1.0, 15.0, 0.1) var minimum_distance: float = 2.4
@export_range(1.0, 20.0, 0.1) var maximum_distance: float = 9.0
@export_range(-180.0, 180.0, 1.0) var initial_yaw_degrees: float = 0.0
@export_range(-80.0, 30.0, 1.0) var initial_pitch_degrees: float = -20.0
@export_range(-89.0, 0.0, 1.0) var minimum_pitch_degrees: float = -60.0
@export_range(0.0, 80.0, 1.0) var maximum_pitch_degrees: float = 12.0
@export_range(1.0, 40.0, 0.5) var follow_sharpness: float = 14.0
@export_range(1.0, 40.0, 0.5) var orbit_sharpness: float = 20.0
@export_range(0.001, 0.02, 0.0001) var mouse_sensitivity: float = 0.0035
@export_range(0.1, 6.0, 0.1) var gamepad_sensitivity: float = 2.4
@export_range(0.05, 0.5, 0.01) var gamepad_deadzone: float = 0.18
@export var gamepad_enabled: bool = true
@export var capture_mouse_on_drag: bool = true
@export var controls_enabled: bool = true:
	set(value):
		controls_enabled = value
		if not value:
			_release_drag()
@export_flags_3d_physics var camera_collision_mask: int = 1
@export_range(35.0, 100.0, 1.0) var field_of_view: float = 65.0
@export var make_current: bool = true

## Available after _ready(). Assign this to HugoPlayer.movement_camera.
var camera: Camera3D
var target: Node3D:
	get:
		return _target
	set(value):
		set_target(value)

var _target: Node3D
var _spring_arm: SpringArm3D
var _yaw: float = 0.0
var _pitch: float = 0.0
var _dragging: bool = false
var _changed_mouse_mode: bool = false
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	_yaw = deg_to_rad(initial_yaw_degrees)
	_pitch = clampf(deg_to_rad(initial_pitch_degrees), deg_to_rad(minimum_pitch_degrees), deg_to_rad(maximum_pitch_degrees))
	orbit_distance = clampf(orbit_distance, minimum_distance, maximum_distance)
	rotation = Vector3(_pitch, _yaw, 0.0)

	_spring_arm = SpringArm3D.new()
	_spring_arm.name = "SpringArm3D"
	_spring_arm.spring_length = orbit_distance
	_spring_arm.collision_mask = camera_collision_mask
	_spring_arm.margin = 0.12
	var camera_shape: SphereShape3D = SphereShape3D.new()
	camera_shape.radius = 0.18
	_spring_arm.shape = camera_shape
	add_child(_spring_arm)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = field_of_view
	camera.near = 0.1
	camera.far = 300.0
	camera.current = make_current
	_spring_arm.add_child(camera)

	get_window().focus_exited.connect(_release_drag)
	if not target_path.is_empty():
		set_target(get_node_or_null(target_path) as Node3D)
	else:
		set_target(_target)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	if controls_enabled and gamepad_enabled:
		_update_gamepad_look(delta)
	var desired_position: Vector3 = _target.global_position + Vector3.UP * target_height
	if global_position.distance_squared_to(desired_position) > 144.0:
		snap_to_target()
	else:
		global_position = global_position.lerp(desired_position, 1.0 - exp(-follow_sharpness * delta))
	var orbit_weight: float = 1.0 - exp(-orbit_sharpness * delta)
	global_rotation = Vector3(
		lerpf(global_rotation.x, _pitch, orbit_weight),
		lerp_angle(global_rotation.y, _yaw, orbit_weight),
		0.0
	)
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, orbit_distance, orbit_weight)


func _input(event: InputEvent) -> void:
	# Observe releases even if a Control consumes the event above the viewport.
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_RIGHT and not button.pressed:
		_release_drag()


func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled or get_tree().paused:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = true
			_previous_mouse_mode = Input.mouse_mode
			_changed_mouse_mode = capture_mouse_on_drag and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
			if _changed_mouse_mode:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_distance = maxf(minimum_distance, orbit_distance - 0.6)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = minf(maximum_distance, orbit_distance + 0.6)
			get_viewport().set_input_as_handled()
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging:
		_rotate_orbit(motion.screen_relative * mouse_sensitivity)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_release_drag()


func _exit_tree() -> void:
	_release_drag()


func set_target(new_target: Node3D) -> void:
	var snap_callback: Callable = Callable(self, "snap_to_target")
	if is_instance_valid(_target) and _target.has_signal("respawned"):
		if _target.is_connected("respawned", snap_callback):
			_target.disconnect("respawned", snap_callback)
	_target = new_target
	if is_instance_valid(_spring_arm):
		_spring_arm.clear_excluded_objects()
		var physics_target: PhysicsBody3D = _target as PhysicsBody3D
		if physics_target != null:
			_spring_arm.add_excluded_object(physics_target.get_rid())
	if is_instance_valid(_target) and _target.has_signal("respawned"):
		if not _target.is_connected("respawned", snap_callback):
			_target.connect("respawned", snap_callback)
	if is_inside_tree() and is_instance_valid(_target) and _target.is_inside_tree():
		snap_to_target()


func snap_to_target() -> void:
	if not is_instance_valid(_target) or not is_inside_tree():
		return
	global_position = _target.global_position + Vector3.UP * target_height
	global_rotation = Vector3(_pitch, _yaw, 0.0)
	reset_physics_interpolation()


func _rotate_orbit(amount: Vector2) -> void:
	_yaw = wrapf(_yaw - amount.x, -PI, PI)
	_pitch = clampf(_pitch - amount.y, deg_to_rad(minimum_pitch_degrees), deg_to_rad(maximum_pitch_degrees))


func _update_gamepad_look(delta: float) -> void:
	var devices: Array[int] = Input.get_connected_joypads()
	if devices.is_empty():
		return
	var device: int = devices[0]
	var stick: Vector2 = Vector2(Input.get_joy_axis(device, JOY_AXIS_RIGHT_X), Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
	var strength: float = minf(stick.length(), 1.0)
	if strength <= gamepad_deadzone:
		return
	stick = stick.normalized() * ((strength - gamepad_deadzone) / (1.0 - gamepad_deadzone))
	_rotate_orbit(stick * gamepad_sensitivity * delta)


func _release_drag() -> void:
	_dragging = false
	if _changed_mouse_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = _previous_mouse_mode
	_changed_mouse_mode = false
