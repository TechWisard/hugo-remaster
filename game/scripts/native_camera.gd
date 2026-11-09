class_name HugoNativeCamera
extends HugoFollowCamera
## Recovered camera/target paths and horizontal projection; RMB enters the
## optional orbit view, camera_toggle returns to the source path.
## Source tangent-plane tracking, path anticipation, pitch smoothing and the
## vertical transform effect (event 0x22000009) are recovered from static code.

const NativeSamplerScript = preload("res://scripts/original_animation.gd")
const PRESENTATION_BASE_ASPECT: float = 16.0 / 9.0

var manual_orbit: bool = false
var native_phase: float = 0.0
var source_camera_offset: Vector3 = Vector3.ZERO
var source_ready: bool = false
var effect_active: bool = false

var _native_sampler: HugoOriginalAnimation = NativeSamplerScript.new() as HugoOriginalAnimation
var _camera_track: Dictionary = {}
var _target_track: Dictionary = {}
var _source_projection: Dictionary = {}
var _path_positions: PackedVector3Array = PackedVector3Array()
var _path_tangents: PackedVector3Array = PackedVector3Array()
var _path_loop: bool = false
var _native_pitch: float = 0.0
var _native_snapped: bool = false
var _all_tracks: Dictionary = {}
var _effect_track: Dictionary = {}
var _effect_elapsed: float = 0.0
var _effect_duration: float = 1.0
var _projection_viewport: Viewport


func _init() -> void:
	_native_sampler.name = "NativeTrackSampler"
	add_child(_native_sampler)


func configure(source_camera: Dictionary, native_transform_tracks: Dictionary) -> bool:
	## May be called before add_child(). Same public target/camera API as orbit rig.
	_all_tracks = native_transform_tracks
	_camera_track = _resolve_track(source_camera.get("transform", {}) as Dictionary, native_transform_tracks)
	_target_track = _resolve_track(source_camera.get("alternate_path", {}) as Dictionary, native_transform_tracks)
	_source_projection = source_camera.get("projection", {}) as Dictionary
	source_ready = not _camera_track.is_empty() and not _target_track.is_empty()
	if not source_ready:
		return false
	_path_positions.clear()
	_path_tangents.clear()
	var keys: Array = (_target_track.get("translation_keys", []) as Array).duplicate()
	if keys.is_empty():
		keys.append(_target_track.get("initial_translation", [0, 0, 0]))
	for value: Variant in keys:
		_path_positions.append(HugoOriginalAnimation.SOURCE_AXES * _array_vector(value) * 0.01)
	_path_loop = bool(_target_track.get("translation_loop", false))
	for index: int in range(_path_positions.size()):
		var before: int = posmod(index - 1, _path_positions.size()) if _path_loop else maxi(index - 1, 0)
		var after: int = (index + 1) % _path_positions.size() if _path_loop else mini(index + 1, _path_positions.size() - 1)
		_path_tangents.append((_path_positions[after] - _path_positions[before]).normalized())
	if is_instance_valid(camera):
		_apply_projection()
		snap_to_target()
	return true


func _ready() -> void:
	super._ready()
	_projection_viewport = get_viewport()
	_projection_viewport.size_changed.connect(_apply_projection, CONNECT_DEFERRED)
	_apply_projection()
	if source_ready:
		snap_to_target()


func _physics_process(delta: float) -> void:
	if effect_active:
		_effect_elapsed += delta
		if _effect_elapsed >= _effect_duration:
			effect_active = false
			_effect_track = {}
	if not source_ready:
		super._physics_process(delta)
		return
	if manual_orbit:
		# The source rail also controls actor activation ranges. Keep its
		# tracker advancing when the player chooses a different camera view.
		if is_instance_valid(_target):
			native_phase = nearest_path_phase(_target.global_position, native_phase)
		super._physics_process(delta)
		return
	_update_native(delta, false)


func receive_native_event(event: Dictionary) -> bool:
	if int(event.get("event", 0)) != 0x22000009:
		return false
	var reference: String = str(event.get("param1_reference", ""))
	var fields: PackedStringArray = reference.split("_")
	if fields.size() != 3 or not fields[0].begins_with("g") or not fields[1].begins_with("o"):
		return false
	var key: String = fields[0] + "_r" + fields[1].substr(1)
	if not _all_tracks.has(key):
		return false
	var raw: PackedByteArray = PackedByteArray()
	raw.resize(4)
	raw.encode_u32(0, int(event.get("param2", 0)))
	return start_effect(_all_tracks[key] as Dictionary, raw.decode_float(0))


func start_effect(track: Dictionary, duration_seconds: float) -> bool:
	# Native CTargetCam ignores a second event while its first effect is active.
	if effect_active or track.is_empty() or not is_finite(duration_seconds) or duration_seconds <= 0.0:
		return false
	_effect_track = track
	_effect_elapsed = 0.0
	_effect_duration = duration_seconds
	effect_active = true
	return true


func native_checkpoint_snapshot() -> Dictionary:
	if not is_instance_valid(camera):
		return {}
	# 0x40A735 writes one tracker float and twelve pose floats (52 bytes).
	# Pitch smoothing and the temporary effect timer are not in that record.
	var pose: Transform3D = camera.global_transform
	return {"native_phase": native_phase,
		"camera_position": [pose.origin.x, pose.origin.y, pose.origin.z],
		"camera_basis": [[pose.basis.x.x, pose.basis.x.y, pose.basis.x.z],
			[pose.basis.y.x, pose.basis.y.y, pose.basis.y.z],
			[pose.basis.z.x, pose.basis.z.y, pose.basis.z.z]]}


func restore_native_checkpoint(saved: Dictionary) -> bool:
	if not is_instance_valid(camera) or saved.is_empty():
		return false
	var position_values: Array = saved.get("camera_position", []) as Array
	var basis_values: Array = saved.get("camera_basis", []) as Array
	var phase: float = float(saved.get("native_phase", -1.0))
	if position_values.size() != 3 or basis_values.size() != 3 or not is_finite(phase) or phase < 0.0 or phase > 1.0:
		return false
	for column: Variant in basis_values:
		if not column is Array or (column as Array).size() != 3:
			return false
	var pose := Transform3D(Basis(_array_vector(basis_values[0]), _array_vector(basis_values[1]),
		_array_vector(basis_values[2])), _array_vector(position_values))
	if not pose.is_finite():
		return false
	_release_drag()
	manual_orbit = false
	native_phase = phase
	global_transform = Transform3D(Basis.IDENTITY, pose.origin)
	_spring_arm.spring_length = 0.0
	_spring_arm.transform = Transform3D.IDENTITY
	camera.transform = Transform3D(pose.basis, Vector3.ZERO)
	# Do not snap: that would replace the restored tracker seed and pose.
	reset_physics_interpolation()
	camera.reset_physics_interpolation()
	return true


func snap_to_target() -> void:
	if not source_ready or manual_orbit:
		super.snap_to_target()
		return
	native_phase = 0.0
	_update_native(0.0, true)
	reset_physics_interpolation()


func set_manual_orbit(enabled: bool) -> void:
	if enabled == manual_orbit or not is_instance_valid(camera):
		return
	_release_drag()
	if enabled and is_instance_valid(_target):
		var center: Vector3 = _target.global_position + Vector3.UP * target_height
		var offset: Vector3 = camera.global_position - center
		var distance: float = offset.length()
		if distance > 0.001:
			_yaw = atan2(offset.x, offset.z)
			_pitch = clampf(-asin(clampf(offset.y / distance, -1.0, 1.0)), deg_to_rad(minimum_pitch_degrees), deg_to_rad(maximum_pitch_degrees))
			maximum_distance = maxf(maximum_distance, distance * 1.05)
			orbit_distance = clampf(distance, minimum_distance, maximum_distance)
		global_position = center
		global_rotation = Vector3(_pitch, _yaw, 0.0)
		camera.transform = Transform3D.IDENTITY
		_spring_arm.spring_length = orbit_distance
	manual_orbit = enabled
	if not enabled:
		snap_to_target()


func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled or get_tree().paused:
		return
	if InputMap.has_action("camera_toggle") and event.is_action_pressed("camera_toggle"):
		set_manual_orbit(not manual_orbit)
		get_viewport().set_input_as_handled()
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if source_ready and not manual_orbit and button != null and button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
		set_manual_orbit(true)
	if manual_orbit or not source_ready:
		super._unhandled_input(event)


func _exit_tree() -> void:
	if is_instance_valid(_projection_viewport) and _projection_viewport.size_changed.is_connected(_apply_projection):
		_projection_viewport.size_changed.disconnect(_apply_projection)
	_projection_viewport = null
	super._exit_tree()


func _apply_projection() -> void:
	if not is_instance_valid(camera) or _source_projection.is_empty() or not is_inside_tree():
		return
	# KEEP_WIDTH makes Camera3D.fov horizontal. Native D3D uses horizontal FOV.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	var horizontal_fov: float = clampf(float(_source_projection.get("horizontal_fov_degrees", 50.0)), 1.0, 179.0)
	var size: Vector2 = get_viewport().get_visible_rect().size
	var aspect: float = size.x / size.y if size.y > 0.0 else PRESENTATION_BASE_ASPECT
	if aspect > PRESENTATION_BASE_ASPECT:
		# Presentation only: retain the tested 16:9 vertical coverage on wider
		# displays, so a normal native jump is not cropped above the frame.
		# Recovered source FOV, paths, tracker and poses remain unchanged.
		horizontal_fov = clampf(rad_to_deg(2.0 * atan(tan(deg_to_rad(horizontal_fov) * 0.5)
			* aspect / PRESENTATION_BASE_ASPECT)), 1.0, 179.0)
	camera.fov = horizontal_fov
	camera.near = maxf(0.01, float(_source_projection.get("near", 0.3)))
	camera.far = maxf(camera.near + 1.0, float(_source_projection.get("far", 500.0)))


func _update_native(delta: float, snap: bool) -> void:
	if not is_instance_valid(_target) or not is_instance_valid(camera) or not is_inside_tree():
		return
	var focus: Vector3 = _target.global_position
	native_phase = nearest_path_phase(focus, native_phase)
	var source_pose: Transform3D = _native_sampler.sample_native_transform(_camera_track, native_phase)
	var source_target: Transform3D = _native_sampler.sample_native_transform(_target_track, native_phase)
	var desired_position: Vector3 = _native_sampler.to_godot_transform(source_pose).origin
	var path_target_position: Vector3 = _native_sampler.to_godot_transform(source_target).origin
	source_camera_offset = desired_position - path_target_position
	if effect_active:
		var effect: Transform3D = _native_sampler.sample_native_transform(_effect_track, _effect_elapsed / _effect_duration)
		# 0x40AD95..0x40ADEB: source translation.x offsets BOTH camera and
		# target on source Z (Godot Y). It does not switch the camera's path.
		var vertical_offset: Vector3 = Vector3.UP * effect.origin.x * 0.01
		desired_position += vertical_offset
		focus += vertical_offset
	global_position = desired_position
	global_rotation = Vector3.ZERO
	_spring_arm.spring_length = 0.0
	_spring_arm.transform = Transform3D.IDENTITY
	camera.position = Vector3.ZERO
	var direction: Vector3 = focus - desired_position
	if direction.length_squared() < 0.000001:
		return
	direction = direction.normalized()
	# 0x40AB38..0x40AC18: lean the view toward the camera rail's tangent
	# when looking along that tangent; preserve the vertical component first.
	var source_tangent: Vector3 = _native_sampler.sample_native_path_tangent(_camera_track, native_phase)
	var tangent: Vector3 = (HugoOriginalAnimation.SOURCE_AXES * source_tangent).normalized()
	var flat_direction: Vector3 = Vector3(direction.x, 0.0, direction.z).normalized()
	var alignment: float = flat_direction.dot(tangent)
	if alignment > 0.0:
		var anticipated: Vector3 = Vector3(tangent.x, direction.y, tangent.z)
		direction = direction.lerp(anticipated, 0.5 * alignment * alignment).normalized()
	var desired_pitch: float = asin(clampf(direction.y, -1.0, 1.0))
	if snap or not _native_snapped:
		_native_pitch = desired_pitch
		_native_snapped = true
	else:
		# 0x40AC67: pitch += (desired - pitch) * 0.06 * (1/6), once per
		# native timer tick. Equivalent exponential for arbitrary Godot delta.
		_native_pitch = lerpf(_native_pitch, desired_pitch, 1.0 - pow(0.99, 300.0 * delta))
	var horizontal: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if horizontal.length_squared() < 0.000001:
		horizontal = Vector3.FORWARD
	horizontal = horizontal.normalized()
	var aim: Vector3 = horizontal * cos(_native_pitch) + Vector3.UP * sin(_native_pitch)
	camera.basis = Basis.looking_at(aim, Vector3.UP)


func nearest_path_phase(point: Vector3, previous_phase: float = 0.0) -> float:
	## Recovered CSnapTracker search, 0x40CE60; no arbitrary nearest-key snapping.
	var count: int = _path_positions.size()
	if count < 2:
		return 0.0
	var intervals: int = count if _path_loop else count - 1
	var seed: float = fposmod(previous_phase, 1.0) if _path_loop else clampf(previous_phase, 0.0, 1.0)
	var index: int = mini(int(seed * float(intervals)), count - 1)
	var forward: bool = _path_tangents[index].dot(point - _path_positions[index]) > 0.0
	var found: bool = false
	for attempt: int in range(count + 1):
		index += 1 if forward else -1
		if not _path_loop and index >= count:
			return 1.0
		if not _path_loop and index < 0:
			return 0.0
		index = posmod(index, count)
		var signed_distance: float = _path_tangents[index].dot(point - _path_positions[index])
		if (forward and signed_distance <= 0.0) or (not forward and signed_distance > 0.0):
			if forward:
				index = posmod(index - 1, count)
			found = true
			break
	if not found:
		return seed
	var next: int = (index + 1) % count if _path_loop else mini(index + 1, count - 1)
	var fraction: float = 0.5
	var step: float = 0.25
	for refinement: int in range(10):
		var tangent: Vector3 = _path_tangents[index].lerp(_path_tangents[next], fraction)
		var position_value: Vector3 = _path_positions[index].lerp(_path_positions[next], fraction)
		fraction += step if tangent.dot(point - position_value) > 0.0 else -step
		step *= 0.5
	return (float(index) + fraction) / float(intervals)


func _resolve_track(pose: Dictionary, tracks: Dictionary) -> Dictionary:
	var reference: Dictionary = pose.get("reference", {}) as Dictionary
	if reference.is_empty():
		return {}
	var key: String = "g%03d_r%04d" % [int(reference.get("group", -1)), int(reference.get("record", -1))]
	return tracks.get(key, {}) as Dictionary


func _array_vector(value: Variant) -> Vector3:
	if value is Array:
		var items: Array = value as Array
		if items.size() >= 3:
			return Vector3(float(items[0]), float(items[1]), float(items[2]))
	return Vector3.ZERO
