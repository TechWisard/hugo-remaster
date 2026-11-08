class_name NativeSound
extends AudioStreamPlayer3D
## Decoded CSound gain, distance curve, looping and exclusive-group suppression.
## Spatial panning is provided by Godot; it is not a DirectSound emulation.

var settings: Dictionary = {}
var listener: Node3D
static var _active_groups: Dictionary = {}
var _exclusive_group: int = -1


func _ready() -> void:
	bus = "Effects" if AudioServer.get_bus_index("Effects") >= 0 else "Master"
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	max_distance = 0.0
	max_db = 24.0
	finished.connect(_unregister)


func play_source(info: Dictionary, pitch: float = 1.0) -> bool:
	var path: String = "res://assets/generated/" + str(info.get("path", ""))
	if not ResourceLoader.exists(path):
		return false
	# 0x418BEC compares the low word (record+0x24), not the adjacent mix
	# gain index. Only sounds carrying flag 0x20 participate in suppression.
	var group: int = int(info.get("exclusive_group", 0))
	var active: Array = _active_groups.get(group, [])
	for index: int in range(active.size() - 1, -1, -1):
		var other: NativeSound = (active[index] as WeakRef).get_ref() as NativeSound
		if other == null or not other.playing:
			active.remove_at(index)
	if info.get("suppress_same_group", false):
		for reference: WeakRef in active:
			var other: NativeSound = reference.get_ref() as NativeSound
			if other != self and bool(other.settings.get("suppress_same_group", false)):
				return false
	stop_source()
	settings = info
	stream = (load(path) as AudioStream).duplicate() as AudioStream
	if stream is AudioStreamWAV:
		var wave: AudioStreamWAV = stream as AudioStreamWAV
		wave.loop_mode = AudioStreamWAV.LOOP_FORWARD if info.get("native_loop", false) else AudioStreamWAV.LOOP_DISABLED
		if wave.loop_mode != AudioStreamWAV.LOOP_DISABLED:
			wave.loop_begin = 0
			wave.loop_end = roundi(wave.get_length() * wave.mix_rate)
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = bool(info.get("native_loop", false))
	pitch_scale = maxf(pitch, 0.01)
	panning_strength = 1.0 if info.get("spatial", false) else 0.0
	_exclusive_group = group
	if not _active_groups.has(group):
		_active_groups[group] = []
	(_active_groups[group] as Array).append(weakref(self))
	_update_gain()
	play()
	return true


func stop_source() -> void:
	stop()
	_unregister()


func _physics_process(_delta: float) -> void:
	if playing:
		_update_gain()


func _update_gain() -> void:
	var distance: float = 0.0
	var ear: Node3D = listener
	if not is_instance_valid(ear):
		ear = get_viewport().get_camera_3d()
	if is_instance_valid(ear):
		distance = global_position.distance_to(ear.global_position)
	volume_db = native_volume_db(native_volume_scalar(settings, distance))


func _exit_tree() -> void:
	_unregister()


func _unregister() -> void:
	if _active_groups.has(_exclusive_group):
		var active: Array = _active_groups[_exclusive_group]
		for index: int in range(active.size() - 1, -1, -1):
			var other: Object = (active[index] as WeakRef).get_ref()
			if other == null or other == self:
				active.remove_at(index)
		if active.is_empty():
			_active_groups.erase(_exclusive_group)
	_exclusive_group = -1


static func native_volume_scalar(info: Dictionary, distance: float) -> float:
	var volume: float = float(info.get("volume", 1.0))
	var flags: int = int(info.get("flags", 0))
	if (flags & 4) == 0:
		return maxf(volume, 0.0)
	# Scale the distance before squaring, as the source vector helper does.
	# Reordering can change the zero-range branch at a squared-offset boundary.
	var scaled_distance: float = distance * 0.01
	var d2: float = scaled_distance * scaled_distance
	if (flags & 0x40) != 0:
		d2 -= float(info.get("source_distance_squared_offset", 0.0))
	if d2 <= 0.0:
		return maxf(volume, 0.0)
	var coefficient: float = 0.1 * (float(info.get("range_coefficient", 1.0)) if (flags & 8) != 0 else 1.0)
	if d2 > 10.0 * coefficient:
		return 0.0
	return maxf(volume * coefficient / (coefficient + d2), 0.0)


static func native_volume_db(scalar: float) -> float:
	return -100.0 if scalar <= 0.0 else float(int((scalar - 1.0) * 2500.0)) / 100.0
