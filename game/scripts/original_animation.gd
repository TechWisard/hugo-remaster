class_name HugoOriginalAnimation
extends Node3D
## Plays recovered local-source morph/transform tracks. No invented skeleton.
## The native 300-Hz timer is separate from each mesh's Q12 timeline slots.

signal action_finished(action: String)

const SOURCE_AXES: Basis = Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3.UP)
const NATIVE_TAU: float = 6.2831854820251465
const NativeMaterialsScript = preload("res://scripts/native_materials.gd")

var current_action: String = ""
var current_clip: String = ""
var native_phase: float = 0.0
var native_timer_ticks: float = 0.0
var distance_scale: float = 1.0
var playback_speed: float = 1.0
var loaded: bool = false
var manifest: Dictionary = {}

var _base_path: String = ""
var _instances: Dictionary = {}
var _bindings: Dictionary = {}
var _material_fix: Callable
var _finished: bool = false


func load_manifest(path: String, material_fix: Callable = Callable()) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return false
	manifest = parsed as Dictionary
	if int(manifest.get("schema_version", 0)) != 1 or not manifest.get("clips", {}) is Dictionary:
		return false
	_base_path = path.get_base_dir()
	_material_fix = material_fix
	loaded = _load_clip("action_00")
	if loaded:
		set_action("idle")
	return loaded


func has_action(action: String) -> bool:
	var actions: Dictionary = manifest.get("bindings", {}) as Dictionary
	return loaded and actions.has(action)


func sample_native_transform(track: Dictionary, phase: float) -> Transform3D:
	## Generic actor/platform sampler. Return SOURCE coordinates, before .01/axis conversion.
	return _sample_transform(track, phase)


func to_godot_transform(source: Transform3D, source_scale: float = 0.01) -> Transform3D:
	return Transform3D(SOURCE_AXES * source.basis * SOURCE_AXES.transposed(), SOURCE_AXES * source.origin * source_scale)


func sample_native_path_tangent(track: Dictionary, phase: float) -> Vector3:
	## 0x40CA10/0x40CC30: derivative of the clamped four-point cubic.
	## Camera anticipation uses this helper, distinct from the position sampler.
	var keys: Array = track.get("translation_keys", []) as Array
	if keys.size() < 2:
		return Vector3.ZERO
	var loop: bool = bool(track.get("translation_loop", false))
	var position: Vector3 = _indices(keys.size(), loop, phase)
	var current: int = int(position.x)
	var next: int = int(position.y)
	var before: int = posmod(current - 1, keys.size()) if loop else maxi(current - 1, 0)
	var after: int = (next + 1) % keys.size() if loop else mini(next + 1, keys.size() - 1)
	var p0: Vector3 = _vector(keys[before])
	var p1: Vector3 = _vector(keys[current])
	var p2: Vector3 = _vector(keys[next])
	var p3: Vector3 = _vector(keys[after])
	var a: Vector3 = (-p0 + 3.0*p1 - 3.0*p2 + p3) * 0.5
	var b: Vector3 = (2.0*p0 - 5.0*p1 + 4.0*p2 - p3) * 0.5
	var c: Vector3 = (-p0 + p2) * 0.5
	return 3.0*a*position.z*position.z + 2.0*b*position.z + c


func apply_native_morph(node: MeshInstance3D, data: Dictionary, phase: float) -> void:
	## data: stored_samples, timeline_words, timeline_loop. Works for any recovered mesh.
	_apply_morph(node, data, phase)


func set_action(action: String, restart: bool = false) -> void:
	if not has_action(action):
		return
	var actions: Dictionary = manifest["bindings"] as Dictionary
	var binding: Dictionary = actions[action] as Dictionary
	var clip_id: String = str(binding.get("clip", ""))
	if clip_id == current_clip and not restart:
		current_action = action
		return
	if not _load_clip(clip_id):
		return
	for key: Variant in _instances:
		var instance: Node3D = _instances[key] as Node3D
		instance.visible = str(key) == clip_id
	current_action = action
	current_clip = clip_id
	native_phase = 0.0
	native_timer_ticks = 0.0
	_finished = false
	_apply_pose()


func seek_phase(phase: float) -> void:
	if not loaded or current_clip.is_empty() or not is_finite(phase):
		return
	var clip: Dictionary = _clip()
	native_phase = fposmod(phase, 1.0) if bool(clip.get("loop", false)) else clampf(phase, 0.0, 1.0)
	native_timer_ticks = native_phase * float(clip.get("authored_duration_timer_ticks", 0.0))
	_finished = false
	_apply_pose()


func seek_native_tick(tick: float) -> void:
	var duration: float = float(_clip().get("authored_duration_timer_ticks", 0.0))
	if duration > 0.0:
		seek_phase(tick / duration)


func advance(delta: float, traveled_distance: float = 0.0) -> void:
	if not loaded or current_clip.is_empty() or delta <= 0.0:
		return
	var clip: Dictionary = _clip()
	var increment: float = 0.0
	if str(clip.get("phase_domain", "seconds")) == "distance":
		var cycle: float = float(clip.get("cycle_distance", 0.0)) * distance_scale
		if cycle > 0.000001:
			increment = absf(traveled_distance) / cycle
	else:
		var duration: float = float(clip.get("authored_duration_seconds", 0.0))
		if duration > 0.000001:
			increment = delta / duration
	native_timer_ticks += delta * 300.0 * playback_speed
	native_phase += increment * playback_speed
	if bool(clip.get("loop", false)):
		native_phase = fposmod(native_phase, 1.0)
	else:
		native_phase = minf(native_phase, 1.0)
	_apply_pose()
	if native_phase >= 1.0 and not bool(clip.get("loop", false)) and not _finished:
		_finished = true
		action_finished.emit(current_action)


func _clip() -> Dictionary:
	var clips: Dictionary = manifest.get("clips", {}) as Dictionary
	return clips.get(current_clip, {}) as Dictionary


func _load_clip(clip_id: String) -> bool:
	if _instances.has(clip_id):
		return true
	var clips: Dictionary = manifest.get("clips", {}) as Dictionary
	if not clips.has(clip_id):
		return false
	var data: Dictionary = clips[clip_id] as Dictionary
	var relative: String = str(data.get("path", ""))
	if relative.is_empty() or relative.is_absolute_path() or relative.contains(".."):
		return false
	var path: String = _base_path.path_join(relative)
	if not ResourceLoader.exists(path, "PackedScene"):
		return false
	var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		return false
	var raw: Node = packed.instantiate()
	var instance: Node3D = raw as Node3D
	if instance == null:
		raw.free()
		return false
	instance.name = clip_id
	instance.visible = false
	add_child(instance)
	if _material_fix.is_valid():
		_material_fix.call(instance)
	var mesh_bindings: Array[Dictionary] = []
	var rows: Array = data.get("nodes", []) as Array
	for value: Variant in rows:
		var row: Dictionary = value as Dictionary
		var mesh_node: MeshInstance3D = instance.find_child(str(row.get("node", "")), true, false) as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			remove_child(instance)
			instance.free()
			return false
		mesh_bindings.append({"instance": mesh_node, "data": row})
	_instances[clip_id] = instance
	_bindings[clip_id] = mesh_bindings
	return true


func _apply_pose() -> void:
	if not _bindings.has(current_clip):
		return
	var rows: Array = _bindings[current_clip] as Array
	var tracks: Dictionary = manifest.get("tracks", {}) as Dictionary
	var sampled: Dictionary = {}
	for value: Variant in rows:
		var binding: Dictionary = value as Dictionary
		var node: MeshInstance3D = binding["instance"] as MeshInstance3D
		var data: Dictionary = binding["data"] as Dictionary
		var transform_value: Transform3D = Transform3D.IDENTITY
		var chain: Array = data.get("transform_chain", []) as Array
		for track_value: Variant in chain:
			var track_id: String = str(track_value)
			if not sampled.has(track_id):
				sampled[track_id] = _sample_transform(tracks[track_id] as Dictionary, native_phase)
			var local: Transform3D = sampled[track_id]
			transform_value = transform_value * local
		node.transform = Transform3D(SOURCE_AXES * transform_value.basis * SOURCE_AXES.transposed(),
			SOURCE_AXES * transform_value.origin * float(manifest.get("source_scale", 0.01)))
		_apply_morph(node, data, native_phase)
		NativeMaterialsScript.apply_phase(node, native_phase)


func _indices(count: int, loop: bool, phase: float) -> Vector3:
	if count <= 1:
		return Vector3.ZERO
	var normalized: float = fposmod(phase, 1.0) if loop else clampf(phase, 0.0, 1.0)
	var coordinate: float = normalized * float(count if loop else count - 1)
	var first: int = mini(int(coordinate), count - 1)
	var second: int = (first + 1) % count if loop else mini(first + 1, count - 1)
	return Vector3(float(first), float(second), coordinate - floorf(coordinate))


func _apply_morph(node: MeshInstance3D, data: Dictionary, phase: float) -> void:
	var count: int = int(data.get("stored_samples", 1))
	if count <= 1:
		return
	var words: Array = data.get("timeline_words", []) as Array
	if words.is_empty():
		return
	var position: Vector3 = _indices(words.size(), bool(data.get("timeline_loop", false)), phase)
	var word0: int = int(words[int(position.x)])
	var word1: int = int(words[int(position.y)])
	var sample0: int = word0 >> 16
	var sample1: int = (sample0 + 1) % count
	var fraction0: float = float(word0 & 4095) / 4096.0
	var difference: float = float(word1 >> 16) + float(word1 & 4095) / 4096.0 - float(sample0) - fraction0
	if difference < 0.0:
		difference += float(count)
	var alpha: float = fraction0 + position.z * difference
	for shape: int in range(node.mesh.get_blend_shape_count()):
		var sample: int = shape + 1
		var weight: float = 0.0
		if sample == sample0:
			weight += 1.0 - alpha
		if sample == sample1:
			weight += alpha
		node.set_blend_shape_value(shape, weight)


func _sample_transform(track: Dictionary, phase: float) -> Transform3D:
	var translation: Vector3 = _vector(track.get("initial_translation", []))
	var basis: Basis = _basis_rows(track.get("initial_basis", []))
	var positions: Array = track.get("translation_keys", []) as Array
	if not positions.is_empty():
		translation = _translation(positions, bool(track.get("translation_loop", false)), phase)
	var rotations: Array = track.get("rotation_keys", []) as Array
	if not rotations.is_empty():
		basis = _rotation(rotations, bool(track.get("rotation_loop", false)), phase)
	return Transform3D(basis, translation)


func _translation(keys: Array, loop: bool, phase: float) -> Vector3:
	var position: Vector3 = _indices(keys.size(), loop, phase)
	var a: int = int(position.x)
	var b: int = int(position.y)
	var t: float = position.z
	var t2: float = t * t
	var t3: float = t2 * t
	if a == b:
		return _vector(keys[a])
	return ((2.0 * t3 - 3.0 * t2 + 1.0) * _vector(keys[a])
		+ (t3 - 2.0 * t2 + t) * _tangent(keys, a, loop)
		+ (-2.0 * t3 + 3.0 * t2) * _vector(keys[b])
		+ (t3 - t2) * _tangent(keys, b, loop))


func _tangent(keys: Array, index: int, loop: bool) -> Vector3:
	if loop:
		return (_vector(keys[(index + 1) % keys.size()]) - _vector(keys[posmod(index - 1, keys.size())])) * 0.5
	if index == 0:
		return _vector(keys[1]) - _vector(keys[0])
	if index == keys.size() - 1:
		return _vector(keys[-1]) - _vector(keys[-2])
	return (_vector(keys[index + 1]) - _vector(keys[index - 1])) * 0.5


func _rotation(keys: Array, loop: bool, phase: float) -> Basis:
	var position: Vector3 = _indices(keys.size(), loop, phase)
	var first: Dictionary = keys[int(position.x)] as Dictionary
	var second: Dictionary = keys[int(position.y)] as Dictionary
	var q0: Vector4 = _quaternion(first.get("quaternion", []))
	var q1: Vector4 = _quaternion(second.get("quaternion", []))
	if int(position.x) == int(position.y):
		return _quaternion_basis(q0)
	var cosine: float = float(first.get("cosine", 0.0))
	if cosine < 0.0:
		q1 = -q1
		cosine = -cosine
	var reciprocal: float = float(first.get("reciprocal_sine", 0.0))
	var q: Vector4
	if reciprocal == 0.0:
		q = q0 * (1.0 - position.z) + q1 * position.z
	else:
		var angle: float = position.z * float(first.get("angle_turns", 0.0)) * NATIVE_TAU
		var weight1: float = sin(angle) * reciprocal
		var weight0: float = cos(angle) - cosine * weight1
		q = q0 * weight0 + q1 * weight1
	return _quaternion_basis(q)


func _quaternion_basis(q: Vector4) -> Basis:
	# Preserve native byte quantization; Quaternion.normalized() changes the pose.
	return Basis(
		Vector3(1.0 - 2.0*q.y*q.y - 2.0*q.z*q.z, 2.0*q.x*q.y + 2.0*q.z*q.w, 2.0*q.x*q.z - 2.0*q.y*q.w),
		Vector3(2.0*q.x*q.y - 2.0*q.z*q.w, 1.0 - 2.0*q.x*q.x - 2.0*q.z*q.z, 2.0*q.y*q.z + 2.0*q.x*q.w),
		Vector3(2.0*q.x*q.z + 2.0*q.y*q.w, 2.0*q.y*q.z - 2.0*q.x*q.w, 1.0 - 2.0*q.x*q.x - 2.0*q.y*q.y))


func _vector(value: Variant) -> Vector3:
	if value is Array:
		var items: Array = value as Array
		if items.size() >= 3:
			return Vector3(float(items[0]), float(items[1]), float(items[2]))
	return Vector3.ZERO


func _quaternion(value: Variant) -> Vector4:
	if value is Array:
		var items: Array = value as Array
		if items.size() >= 4:
			return Vector4(float(items[0]), float(items[1]), float(items[2]), float(items[3]))
	return Vector4(0.0, 0.0, 0.0, 1.0)


func _basis_rows(value: Variant) -> Basis:
	if value is Array:
		var rows: Array = value as Array
		if rows.size() == 3:
			return Basis(_vector(rows[0]), _vector(rows[1]), _vector(rows[2])).transposed()
	return Basis.IDENTITY
