extends SceneTree
## Imported Beach integration: real input, original whip PCM, authored bank contact.
## No player pose/velocity writes, generic support planes or disabled actors.

const LevelScript = preload("res://scripts/original_level.gd")
const SoundScript = preload("res://scripts/native_audio.gd")
var failures: Array[String] = []
var checks: int = 0
var cues: Array[Dictionary] = []
var level: OriginalLevel
var capture: AudioEffectCapture
var whip_peak: float = 0.0
var whip_samples: int = 0
var respawns: int = 0
var report_path: String = "user://native_player_feedback_test.json"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--feedback-report="):
			report_path = arg.trim_prefix("--feedback-report=")
	if not ResourceLoader.exists("res://assets/generated/levels/g006.glb", "PackedScene"):
		print("NATIVE_PLAYER_FEEDBACK SKIP: original imported Beach is unavailable")
		quit()
		return
	var campaign: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/campaign.json"))
	var gameplay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/gameplay_manifest.json"))
	SoundScript.configure_catalog(gameplay.get("audio", {}))
	for bus: String in ["Music", "Effects", "FeedbackWhip"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("FeedbackWhip"), capture)
	var entry: Dictionary = {}
	for candidate: Dictionary in campaign.levels:
		if str(candidate.id) == "g006":
			entry = candidate
	level = LevelScript.new()
	level.entry = entry
	level.data = JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/levels/g006.json"))
	level.gameplay = gameplay.levels.g006
	level.native_rules = gameplay.native_rules
	root.add_child(level)
	_expect(level._ready_ok, "original Beach loads")
	level.player.respawned.connect(func() -> void: respawns += 1)
	level.player_audio.connect("cue_started", _cue_started)
	await _ticks(30)
	var start: Vector3 = level.player.position
	for attack: int in range(3):
		Input.action_press("attack")
		await _ticks(1)
		Input.action_release("attack")
		await _ticks(35)
	var attack_cues: Array[Dictionary] = []
	for cue: Dictionary in cues:
		if int(cue.action) == 2:
			attack_cues.append(cue)
	_expect(level.player.attack_serial == 3 and attack_cues.size() == 3,
		"three accepted normal-input attacks play exactly three source whip cues")
	for cue: Dictionary in attack_cues:
		_expect(float(cue.phase) >= 2.0 / 3.0 and float(cue.phase) < 0.73,
			"whip cue fires on the first 60Hz sample crossing native phase 6/9")
		_expect(str(cue.path) == "audio/g006_r0045.wav", "whip uses its decoded source sample")
	# Let the actual audio mixer flush its final buffers even under fast fixed-FPS QA.
	OS.delay_msec(80)
	_drain_audio()
	_expect(whip_samples > 0 and whip_peak > 0.0001,
		"isolated whip bus contains actual nonzero mixed PCM")
	Input.action_press("move_right")
	await _ticks(90)
	Input.action_release("move_right")
	await _ticks(30)
	var bank: Vector3 = level.player.position
	_expect(bank.z > start.z + 5.0, "normal input reaches the formerly unsupported visible sand bank")
	_expect(level.player.is_on_floor() and bank.y > start.y - 1.0,
		"authored opaque bank geometry supports the player instead of falling through")
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	var apex: float = level.player.position.y
	for frame: int in range(65):
		await _ticks(1)
		apex = maxf(apex, level.player.position.y)
	_expect(apex > bank.y + 2.7 and level.player.is_on_floor(),
		"a real jump leaves and lands on the same bank")
	_expect(respawns == 0, "no reset or teleport masks the repaired contact")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures,
		"cues": cues, "whip_mixed_peak": whip_peak, "whip_mixed_frames": whip_samples,
		"start": str(start), "bank": str(bank), "apex": apex, "respawns": respawns,
		"normal_input_only": true, "player_pose_writes": 0, "generic_floors": 0}, "\t"))
	print("NATIVE_PLAYER_FEEDBACK checks=", checks, " failures=", JSON.stringify(failures),
		" mixed_whip_peak=", whip_peak, " report=", report_path)
	quit(0 if failures.is_empty() else 1)


func _cue_started(action: int, index: int, path: String) -> void:
	cues.append({"action": action, "cue": index, "path": path,
		"phase": level.player.get_native_visual_phase()})
	if action == 2:
		# Only test routing changes; use the actual NativeSound stream/gain/playback.
		for node: Node in level.player.get_children():
			if node is NativeSound and node.playing and str(node.settings.get("path", "")) == path:
				node.bus = "FeedbackWhip"


func _drain_audio() -> void:
	var available: int = capture.get_frames_available()
	if available <= 0:
		return
	var buffer: PackedVector2Array = capture.get_buffer(available)
	whip_samples += buffer.size()
	for sample: Vector2 in buffer:
		whip_peak = maxf(whip_peak, maxf(absf(sample.x), absf(sample.y)))


func _ticks(count: int) -> void:
	for frame: int in range(count):
		await physics_frame
		await process_frame
		_drain_audio()


func _expect(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)
