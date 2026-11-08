class_name NativeSpeaker
extends Node3D
## Native ambient speaker and phase-driven loudspeaker sequence.

const SoundScript = preload("res://scripts/native_audio.gd")
var native: Dictionary
var tracks: Dictionary
var sampler: HugoOriginalAnimation
var listener: Node3D
var enabled: bool = true
var _phase: float = 0.0
var _cursor: int = 0
var _pending: bool = true
var _continuous: NativeSound
var _voices: Array[NativeSound] = []
var _track: Dictionary = {}


func _ready() -> void:
	var config: Dictionary = native.get("speaker", {})
	enabled = bool(config.get("initial_enabled", true))
	_phase = float(config.get("initial_phase", 0.0))
	_track = tracks.get(str(config.get("transform_track", "")), {})
	_sample_position(_phase)
	if str(config.get("mode", "")) == "continuous":
		_continuous = SoundScript.new()
		_continuous.listener = listener
		add_child(_continuous)


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	var config: Dictionary = native.get("speaker", {})
	if is_instance_valid(_continuous):
		if not _continuous.playing and (_pending or config.get("repeat", false)):
			_continuous.play_source(config.get("sound", {}))
			_pending = false
		return
	if delta > 1.0:
		delta = 0.0
	_phase += delta / maxf(float(config.get("period_seconds", 1.0)), 0.0001)
	var wrapped: bool = _phase > 1.0
	_sample_position(NativeActorMotion.ticker_phase(_phase))
	var cues: Array = config.get("sound_sequence", {}).get("cues", [])
	while _cursor < cues.size() and float(cues[_cursor].get("normalized_phase", 0.0)) <= _phase:
		_play_cue(cues[_cursor].get("sound", {}))
		_cursor += 1
	if wrapped:
		_phase = fposmod(_phase, 1.0)
		_cursor = 0
	for index: int in range(_voices.size() - 1, -1, -1):
		if not is_instance_valid(_voices[index]):
			_voices.remove_at(index)


func receive_native_event(event: Dictionary) -> void:
	if int(event.get("event", 0)) == int(native.get("speaker", {}).get("activation_event", 0)):
		enabled = true
		_pending = true


func reset_native_world() -> void:
	var config: Dictionary = native.get("speaker", {})
	_phase = float(config.get("initial_phase", 0.0))
	_cursor = 0
	_pending = true
	enabled = bool(config.get("initial_enabled", true))
	if is_instance_valid(_continuous):
		_continuous.stop_source()
	for voice: NativeSound in _voices:
		if is_instance_valid(voice):
			voice.stop_source()
			voice.queue_free()
	_voices.clear()
	_sample_position(_phase)


func _sample_position(phase: float) -> void:
	if sampler != null and not _track.is_empty():
		transform = sampler.to_godot_transform(sampler.sample_native_transform(_track, phase))


func _play_cue(info: Dictionary) -> void:
	var voice: NativeSound = SoundScript.new()
	voice.listener = listener
	add_child(voice)
	voice.finished.connect(voice.queue_free)
	if voice.play_source(info):
		_voices.append(voice)
	else:
		voice.queue_free()
