class_name NativeSound
extends AudioStreamPlayer3D
## Decoded CSound gain, distance curve, looping and exclusive-group suppression.
## Spatial panning is provided by Godot; it is not a DirectSound emulation.

const VoiceLibrary = preload("res://scripts/native_voice_library.gd")

var settings: Dictionary = {}
var listener: Node3D
static var _active_groups: Dictionary = {}
static var _source_catalog: Dictionary = {}
static var _source_by_path: Dictionary = {}
static var _canonical_by_hash: Dictionary = {}
static var _stream_cache: Dictionary = {}
static var _cache_hits: int = 0
static var _cache_misses: int = 0
var _exclusive_group: int = -1


static func configure_catalog(catalog: Dictionary) -> void:
	# The verified import catalog preserves every native ID. Only immutable sample
	# bytes are shared; each active player retains its own loop/pitch/gain state.
	_source_catalog = catalog
	_source_by_path.clear()
	_canonical_by_hash.clear()
	clear_stream_cache()
	var keys: Array = catalog.keys()
	keys.sort()
	for key: String in keys:
		if not catalog[key] is Dictionary:
			continue
		var info: Dictionary = catalog[key]
		var path: String = VoiceLibrary.generated_path(str(info.get("path", "")))
		if path.is_empty():
			continue
		_source_by_path[path] = info
		var digest: String = str(info.get("sha256", "")).to_lower()
		if VoiceLibrary.valid_sha256(digest) and not _canonical_by_hash.has(digest):
			_canonical_by_hash[digest] = path


static func clear_stream_cache() -> void:
	_stream_cache.clear()
	_cache_hits = 0
	_cache_misses = 0


static func cache_stats() -> Dictionary:
	return {"source_ids": _source_catalog.size(), "unique_source_hashes": _canonical_by_hash.size(),
		"resident_streams": _stream_cache.size(), "hits": _cache_hits, "loads": _cache_misses}


static func cached_stream(info: Dictionary) -> AudioStream:
	# The returned resource is immutable shared data; playback duplicates the
	# resource wrapper so concurrent native looping and one-shot cues stay separate.
	return _resolved_stream(VoiceLibrary.resolve_audio(info))


static func _resolved_stream(resolved: Dictionary) -> AudioStream:
	if not bool(resolved.get("available", false)):
		return null
	var path: String = str(resolved.get("path", ""))
	var source: Dictionary = _source_by_path.get(path, {})
	var digest: String = str(source.get("sha256", "")).to_lower()
	if str(resolved.get("asset_source", "")) == "voice_pack":
		digest = str(resolved.get("sha256", "")).to_lower()
	var key: String = "path:" + path
	if VoiceLibrary.valid_sha256(digest):
		key = "sha256:" + digest
	if _stream_cache.has(key):
		_cache_hits += 1
		return _stream_cache[key] as AudioStream
	var canonical: String = str(_canonical_by_hash.get(digest, path))
	if not ResourceLoader.exists(canonical, "AudioStream"):
		canonical = path
	var resource: AudioStream = load(canonical) as AudioStream
	if resource == null:
		return null
	_cache_misses += 1
	_stream_cache[key] = resource
	return resource


func _ready() -> void:
	bus = "Effects" if AudioServer.get_bus_index("Effects") >= 0 else "Master"
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	max_distance = 0.0
	max_db = 24.0
	finished.connect(_unregister)


func play_source(info: Dictionary, pitch: float = 1.0) -> bool:
	var resolved: Dictionary = VoiceLibrary.resolve_audio(info)
	if not bool(resolved.get("available", false)):
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
	var shared: AudioStream = _resolved_stream(resolved)
	if shared == null:
		return false
	stop_source()
	settings = info
	stream = shared.duplicate() as AudioStream
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
