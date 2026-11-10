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
## Camera presentation guard for free backtracking past a source rail endpoint.
## The original tracks, tracker phase and world geometry are never rewritten.
var backtracking_clearance_enabled: bool = true
var backtracking_clearance_active: bool = false
## Permanent visible map completions must not sit between the rail camera and
## Hugo. Preserve the rail's horizontal side while bringing the camera inside.
var boundary_occlusion_enabled: bool = true
var boundary_occlusion_active: bool = false
var boundary_occluder: String = ""
var _boundary_orbit_sign: float = 1.0

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
		camera.remove_meta("hugo_native_movement_forward")
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
	camera.remove_meta("hugo_native_movement_forward")
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
	backtracking_clearance_active = false
	if backtracking_clearance_enabled and not _path_loop \
			and (native_phase <= 0.000001 or native_phase >= 0.999999):
		# At an endpoint the rail cannot move farther, but modern free movement
		# can bring Hugo beneath and behind its camera. A camera aimed at Hugo
		# then reverses its horizontal axis every time S crosses the camera:
		# the player spins in place and falls outside the smoothed view. Keep
		# the camera on its authored side, at a usable framing distance, only
		# while that endpoint clearance would otherwise be lost.
		var rail_back := Vector3(source_camera_offset.x, 0.0, source_camera_offset.z)
		if rail_back.length_squared() > 0.000001:
			rail_back = rail_back.normalized()
			var clearance: float = (desired_position - focus).dot(rail_back)
			var required_clearance: float = maxf(minimum_distance, target_height * 4.0)
			if clearance < required_clearance:
				desired_position += rail_back * (required_clearance - clearance)
				backtracking_clearance_active = true
	boundary_occlusion_active = false
	boundary_occluder = ""
	var control_direction: Vector3 = _anticipated_direction(focus - desired_position)
	if boundary_occlusion_enabled:
		var body_focus: Vector3 = focus + Vector3.UP * target_height
		desired_position = _clear_boundary_sightline(body_focus, desired_position)
		if boundary_occlusion_active:
			# The original slow pitch interpolation can look past Hugo while the
			# obstacle contracts the horizontal distance. Aim at his body now;
			# player movement, source tracks and tracker phase remain untouched.
			focus = body_focus
	if boundary_occlusion_active:
		# Collision avoidance changes the view, never the rail-relative controls.
		# In particular, holding S must not steer Hugo around with this camera.
		camera.set_meta("hugo_native_movement_forward", Vector3(control_direction.x, 0.0, control_direction.z).normalized())
	else:
		camera.remove_meta("hugo_native_movement_forward")
	global_position = desired_position
	global_rotation = Vector3.ZERO
	_spring_arm.spring_length = 0.0
	_spring_arm.transform = Transform3D.IDENTITY
	camera.position = Vector3.ZERO
	var direction: Vector3 = focus - desired_position
	if direction.length_squared() < 0.000001:
		return
	direction = direction.normalized() if boundary_occlusion_active else _anticipated_direction(direction)
	var desired_pitch: float = asin(clampf(direction.y, -1.0, 1.0))
	if snap or not _native_snapped or boundary_occlusion_active:
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


func _anticipated_direction(offset: Vector3) -> Vector3:
	var direction: Vector3 = offset.normalized()
	# 0x40AB38..0x40AC18: recovered rail-tangent anticipation.
	var source_tangent: Vector3 = _native_sampler.sample_native_path_tangent(_camera_track, native_phase)
	var tangent: Vector3 = (HugoOriginalAnimation.SOURCE_AXES * source_tangent).normalized()
	var flat_direction: Vector3 = Vector3(direction.x, 0.0, direction.z).normalized()
	var alignment: float = flat_direction.dot(tangent)
	if alignment > 0.0:
		direction = direction.lerp(Vector3(tangent.x, direction.y, tangent.z), 0.5 * alignment * alignment).normalized()
	return direction


func _boundary_silhouette_points(focus: Vector3, back: Vector3) -> PackedVector3Array:
	var right: Vector3 = Vector3.UP.cross(back).normalized()
	var feet: Vector3 = focus - Vector3.UP * (target_height - maxf(0.08, camera.near * 0.5))
	# Width samples catch a sloping crown before it covers a leg or shoulder.
	return PackedVector3Array([feet, feet - right * target_height * 0.35,
		feet + right * target_height * 0.35, focus - right * target_height * 0.55,
		focus + right * target_height * 0.55, focus + Vector3.UP * target_height])


func _clear_boundary_sightline(focus: Vector3, desired: Vector3) -> Vector3:
	var flat: Vector3 = Vector3(desired.x - focus.x, 0.0, desired.z - focus.z)
	if flat.length_squared() < 0.000001:
		return desired
	var back: Vector3 = flat.normalized()
	var points: PackedVector3Array = _boundary_silhouette_points(focus, back)
	var clearance: float = flat.length()
	var margin: float = maxf(0.5, camera.near * 2.0)
	for point: Vector3 in points:
		# The horizontal query reacts before the camera crosses the rock crown,
		# even while one central diagonal ray still passes just above it.
		var hit: Dictionary = _boundary_hit(point, Vector3(desired.x, point.y, desired.z))
		if not hit.is_empty():
			boundary_occlusion_active = true
			boundary_occluder = str((hit.collider as Node).get_path())
			clearance = minf(clearance, (Vector3(hit.position) - focus).dot(back) - margin)
		elif not boundary_occlusion_active:
			hit = _boundary_hit(point, desired)
			if not hit.is_empty():
				boundary_occlusion_active = true
				boundary_occluder = str((hit.collider as Node).get_path())
				clearance = minf(clearance, (Vector3(hit.position) - focus).dot(back) - margin)
	if not boundary_occlusion_active:
		return desired
	var framing_distance: float = maxf(minimum_distance, target_height * 3.5)
	var height: float = focus.y + clampf(desired.y - focus.y, target_height * 1.8, framing_distance * 0.85)
	var direct: Vector3 = focus + back * maxf(clearance, 0.05)
	direct.y = height
	if clearance >= framing_distance and _boundary_view_clear(points, direct):
		return direct
	# Contracting to a few centimetres produces a top-down view of only Hugo's
	# head. Move along an arc inside the wall instead, retaining enough distance
	# and a readable elevation. Keep the chosen shoulder while the guard is on.
	var angle: float = acos(clampf(clearance / framing_distance, -1.0, 1.0)) + deg_to_rad(5.0)
	angle = minf(angle, PI)
	for sign_value: float in [_boundary_orbit_sign, -_boundary_orbit_sign]:
		for attempt: int in range(7):
			var orbit_angle: float = minf(PI, angle + deg_to_rad(15.0 * attempt))
			var candidate: Vector3 = focus + back.rotated(Vector3.UP, orbit_angle * sign_value) * framing_distance
			candidate.y = height
			if _boundary_view_clear(points, candidate):
				_boundary_orbit_sign = sign_value
				return candidate
			if orbit_angle >= PI:
				break
	# A narrow native enclosure may reject both shoulders. Stay on its interior
	# side; this fallback never moves Hugo or disables an obstacle.
	var interior: Vector3 = focus - back * framing_distance
	interior.y = height
	return interior


func _boundary_view_clear(points: PackedVector3Array, candidate: Vector3) -> bool:
	var excluded: Array[RID] = []
	if _target is CollisionObject3D:
		excluded.append((_target as CollisionObject3D).get_rid())
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	for point: Vector3 in points:
		var query := PhysicsRayQueryParameters3D.create(point, candidate, camera_collision_mask, excluded)
		query.hit_back_faces = true
		if not space.intersect_ray(query).is_empty():
			return false
	return true


func _boundary_hit(from: Vector3, to: Vector3) -> Dictionary:
	if from.distance_squared_to(to) <= 0.000001 or not is_inside_tree():
		return {}
	var excluded: Array[RID] = []
	if _target is CollisionObject3D:
		excluded.append((_target as CollisionObject3D).get_rid())
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	# Only the explicit permanent visible repairs opt into this source-camera
	# adaptation. Other native colliders retain the recovered camera behavior.
	for attempt: int in range(12):
		var query := PhysicsRayQueryParameters3D.create(from, to, camera_collision_mask, excluded)
		query.hit_back_faces = true
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return {}
		var body: Object = hit.collider
		if body is Node and bool((body as Node).get_meta("hugo_boundary_closure", false)):
			return hit
		excluded.append(hit.rid)
	return {}


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
