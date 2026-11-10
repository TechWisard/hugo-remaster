class_name NativePlayerAudio
extends Node
## CHugo's source action-sound table (+0xCC, fourteen 20-byte sequences).
## The current visual phase schedules cues, including the whip at phase 2/3.

signal cue_started(action_index: int, cue_index: int, source_path: String)

var player: HugoPlayer
var level: Node3D
var sequences: Dictionary = {}
var played_cues: int = 0
var _clip: String = ""
var _phase: float = 0.0
var _attack_serial: int = -1
var _played: Dictionary = {}
var _primed: bool = false


func _ready() -> void:
	# The player has already selected and advanced the current action this tick.
	process_physics_priority = 20


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(player) or not is_instance_valid(level) \
			or not is_instance_valid(player._visual) \
			or not is_instance_valid(player._visual.original_animation):
		return
	var animation: HugoOriginalAnimation = player._visual.original_animation
	var clip: String = animation.current_clip
	var phase: float = animation.native_phase
	var action: int = player.get_native_visual_action()
	if not _primed:
		# Restoring an in-progress action must not replay its elapsed sound cues.
		_primed = true
		_clip = clip
		_phase = phase
		_attack_serial = player.attack_serial
		return
	var restarted: bool = clip != _clip or phase < _phase \
		or (action == 2 and player.attack_serial != _attack_serial)
	if restarted:
		_played.clear()
		_phase = -1.0
	_clip = clip
	_attack_serial = player.attack_serial
	# Surface/contact replacements have their own owner-specific sound sequence.
	if not clip.begins_with("action_"):
		_phase = phase
		return
	var sequence: Dictionary = sequences.get(str(action), {})
	var cues: Array = sequence.get("cues", [])
	for index: int in range(cues.size()):
		var cue: Dictionary = cues[index]
		var cue_phase: float = float(cue.get("normalized_phase", 0.0))
		if _played.has(index) or cue_phase > phase or cue_phase <= _phase:
			continue
		_played[index] = true
		var sound: Dictionary = cue.get("sound", {}) if cue.get("sound") is Dictionary else {}
		var voice: NativeSound = level.call("play_native_sound", sound, player.global_position, player) as NativeSound
		if is_instance_valid(voice):
			played_cues += 1
			cue_started.emit(action, index, str(sound.get("path", "")))
	_phase = phase
