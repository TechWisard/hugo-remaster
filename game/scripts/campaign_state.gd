class_name CampaignState
extends RefCounted
## User progress is separate from game data. A bad write retains the previous save.

const SCHEMA: int = 2
const DEFAULT_PATH: String = "user://campaign_v2.json"
const MAX_BYTES: int = 4 * 1024 * 1024
const GraphicsScript = preload("res://scripts/native_graphics_settings.gd")
const Localizer = preload("res://scripts/native_localization.gd")

var path: String = DEFAULT_PATH
var level_id: String = ""
var completed_levels: Dictionary = {}
var runs: Dictionary = {}
var settings: Dictionary = {"music_volume": 0.65, "effects_volume": 0.85, "fullscreen": false,
	"new_game_difficulty": 1, "graphics": GraphicsScript.defaults(),
	"text_locale": "ru", "voice_locale": "ru"}
var difficulty: int = 1
var total_lives: int = 4
var qualified_levels: Dictionary = {}
var last_error: String = ""
var last_error_key: String = ""
var last_error_arguments: Dictionary = {}
var recovered_backup: bool = false


func read_save(known_level_ids: Array[String]) -> bool:
	last_error = ""
	last_error_key = ""
	last_error_arguments = {}
	recovered_backup = false
	var payload: Dictionary = _read_document(path)
	if payload.is_empty():
		payload = _read_document(path + ".bak")
		recovered_backup = not payload.is_empty()
	if payload.is_empty():
		return false
	var id_value: Variant = payload.get("level_id", "")
	level_id = str(id_value) if str(id_value) in known_level_ids else ""
	completed_levels.clear()
	for key: String in payload.get("completed_levels", {}):
		if key in known_level_ids and payload.completed_levels[key] == true:
			completed_levels[key] = true
	runs.clear()
	for key: String in payload.get("runs", {}):
		if key in known_level_ids and payload.runs[key] is Dictionary:
			runs[key] = _clean_run(payload.runs[key])
	var options: Dictionary = payload.get("settings", {})
	for key: String in ["music_volume", "effects_volume"]:
		var value: Variant = options.get(key, settings[key])
		if (value is float or value is int) and is_finite(float(value)):
			settings[key] = clampf(float(value), 0.0, 1.0)
	settings["fullscreen"] = options.get("fullscreen", false) == true
	settings["new_game_difficulty"] = _integer(options.get("new_game_difficulty"), 1, 0, 2)
	settings["text_locale"] = Localizer.sanitize_locale(options.get("text_locale", "ru"))
	settings["voice_locale"] = Localizer.sanitize_voice_locale(options.get("voice_locale", "ru"))
	settings["graphics"] = GraphicsScript.sanitize(options.get("graphics", {}))
	var old_graphics: Variant = options.get("graphics", {})
	if not old_graphics is Dictionary or not old_graphics.has("display_mode"):
		settings.graphics.display_mode = "fullscreen" if settings.fullscreen else "windowed"
	settings["fullscreen"] = settings.graphics.display_mode != "windowed"
	var native: Dictionary = payload.get("native", {})
	difficulty = _integer(native.get("difficulty"), 1, 0, 2)
	total_lives = _integer(native.get("total_lives"), 4, 0, 20)
	qualified_levels.clear()
	for id: String in native.get("qualified_levels", {}):
		if id in known_level_ids and native.qualified_levels[id] == true:
			qualified_levels[id] = true
	return true


func write_save() -> bool:
	last_error = ""
	last_error_key = ""
	last_error_arguments = {}
	var payload: Dictionary = {"schema": SCHEMA, "level_id": level_id,
		"completed_levels": completed_levels, "runs": runs, "settings": settings,
		"native": {"difficulty": difficulty, "total_lives": total_lives, "qualified_levels": qualified_levels}}
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		_set_error("save.open_error", {"error": error_string(FileAccess.get_open_error())})
		return false
	file.store_string(JSON.stringify(payload))
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK or _read_document(path + ".tmp").is_empty():
		_set_error("save.verify_error")
		return false
	var absolute: String = ProjectSettings.globalize_path(path)
	var backup: String = absolute + ".bak"
	var had_save: bool = FileAccess.file_exists(path)
	if had_save:
		# Replace backup only with a valid primary; preserve a recovered backup.
		if not _read_document(path).is_empty():
			if FileAccess.file_exists(backup):
				var remove_error: Error = DirAccess.remove_absolute(backup)
				if remove_error != OK:
					_set_error("save.backup_error")
					return false
			if DirAccess.rename_absolute(absolute, backup) != OK:
				_set_error("save.previous_error")
				return false
		else:
			# The invalid primary is retained for diagnosis without blocking recovery.
			var invalid: String = absolute + ".invalid"
			if FileAccess.file_exists(invalid):
				DirAccess.remove_absolute(invalid)
			if DirAccess.rename_absolute(absolute, invalid) != OK:
				_set_error("save.corrupt_error")
				return false
	var result: Error = DirAccess.rename_absolute(absolute + ".tmp", absolute)
	if result != OK:
		if not FileAccess.file_exists(absolute) and FileAccess.file_exists(backup):
			DirAccess.copy_absolute(backup, absolute)
		_set_error("save.finish_error", {"error": error_string(result)})
		return false
	return true


func _set_error(key: String, arguments: Dictionary = {}) -> void:
	last_error_key = key
	last_error_arguments = arguments.duplicate()
	last_error = Localizer.text(key, arguments)


func set_run(id: String, state: Dictionary) -> void:
	level_id = id
	runs[id] = _clean_run(state)
	if state.has("lives"):
		total_lives = _integer(state.lives, total_lives, 0, 20)


func clear_campaign(first_level: String) -> void:
	level_id = first_level
	completed_levels.clear()
	runs.clear()
	qualified_levels.clear()
	difficulty = int(settings.get("new_game_difficulty", 1))
	total_lives = 4


func _read_document(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES:
		return {}
	var parser := JSON.new()
	var parse_result: Error = parser.parse(file.get_as_text())
	file.close()
	if parse_result != OK:
		return {}
	var parsed: Variant = parser.data
	if not parsed is Dictionary or parsed.get("schema") != SCHEMA:
		return {}
	for key: String in ["completed_levels", "runs", "settings", "native"]:
		if not parsed.get(key, {}) is Dictionary:
			return {}
	if not parsed.get("native", {}).get("qualified_levels", {}) is Dictionary:
		return {}
	return parsed


func _clean_run(raw: Dictionary) -> Dictionary:
	var result: Dictionary = _clean_world(raw)
	if raw.get("checkpoint_state") is Dictionary:
		result["checkpoint_state"] = _clean_world(raw.checkpoint_state)
	return result


func _clean_world(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {"collected": [], "defeated": [], "activated": [], "checkpoint_id": "", "elapsed": 0.0}
	for key: String in ["completed", "finish_rewards_applied", "death_pending"]:
		result[key] = raw.get(key, false) == true
	for key: String in ["collected", "defeated", "activated", "removed_actors", "scope_removed_actors"]:
		var values: Variant = raw.get(key, [])
		if values is Array:
			var unique: Dictionary = {}
			for value: Variant in values.slice(0, 10000):
				if value is String and value.length() < 128:
					unique[value] = true
			result[key] = unique.keys()
	var checkpoint: Variant = raw.get("checkpoint_id", "")
	if checkpoint is String and checkpoint.length() < 128:
		result["checkpoint_id"] = checkpoint
	var elapsed: Variant = raw.get("elapsed", 0)
	if (elapsed is int or elapsed is float) and is_finite(float(elapsed)):
		result["elapsed"] = clampf(float(elapsed), 0.0, 86400000.0)
	for key: String in ["health", "lives", "diamonds"]:
		if raw.has(key):
			result[key] = _integer(raw[key], 0, 0, 100000)
	if raw.has("attack_serial"):
		result["attack_serial"] = _integer(raw.attack_serial, 0, 0, 2147483647)
	if raw.get("player_runtime") is Dictionary:
		var runtime: Dictionary = _player_runtime(raw.player_runtime)
		if not runtime.is_empty():
			result["player_runtime"] = runtime
			result["damage_remaining"] = _number(raw.get("damage_remaining"), 0.0, 0.0, 1.0)
	for key: String in ["checkpoint_position", "player_position"]:
		var position: Array = _coordinates(raw.get(key), 3)
		if not position.is_empty():
			result[key] = position
	for key: String in ["checkpoint_facing", "player_facing"]:
		if raw.has(key):
			result[key] = _number(raw[key], 0.0, -TAU, TAU)
	var actors: Dictionary = {}
	var raw_actors: Variant = raw.get("actors", {})
	if raw_actors is Dictionary:
		for id: Variant in raw_actors:
			if not id is String or id.length() >= 128 or not raw_actors[id] is Dictionary:
				continue
			var actor: Dictionary = raw_actors[id]
			var clean: Dictionary = {"state": _integer(actor.get("state"), 0, 0, 4095),
				"previous_state": _integer(actor.get("previous_state"), 0, 0, 4095),
				"health": _integer(actor.get("health"), 0, -100000, 100000),
				"removed": actor.get("removed", false) == true,
				"persistent_activation": actor.get("persistent_activation", false) == true,
				"remember_removed_on_unload": actor.get("remember_removed_on_unload", false) == true,
				"visual_loops": _integer(actor.get("visual_loops"), 0, 0, 10000000),
				"path_loops": _integer(actor.get("path_loops"), 0, 0, 10000000),
				"last_damage_id": _integer(actor.get("last_damage_id"), -1, -1, 2147483647)}
			for key: String in ["elapsed", "visual_phase", "path_phase"]:
				clean[key] = _number(actor.get(key), 0.0, 0.0, 86400000.0)
			var transform: Array = _coordinates(actor.get("transform"), 12)
			if not transform.is_empty():
				clean["transform"] = transform
			var cues: Array[String] = []
			if actor.get("played_sound_cues") is Array:
				for value: Variant in actor.played_sound_cues.slice(0, 128):
					if value is String and value.length() < 128:
						cues.append(value)
			clean["played_sound_cues"] = cues
			actors[id] = clean
			if actors.size() >= 10000:
				break
	result["actors"] = actors
	var native_actors: Dictionary = {}
	if raw.get("native_actors") is Dictionary:
		for id: Variant in raw.native_actors:
			if id is String and id.length() < 128 and raw.native_actors[id] is Dictionary:
				native_actors[id] = {"persistent_activation": raw.native_actors[id].get("persistent_activation", false) == true}
			if native_actors.size() >= 10000:
				break
	result["native_actors"] = native_actors
	if raw.get("scopes") is Dictionary:
		result["scopes"] = {"resident_groups": _groups(raw.scopes.get("resident_groups", []))}
	if raw.has("resident_groups"):
		result["resident_groups"] = _groups(raw.resident_groups)
	if raw.get("camera") is Dictionary:
		var camera: Dictionary = _camera(raw.camera)
		if not camera.is_empty():
			result["camera"] = camera
	var moved: Dictionary = {}
	var raw_moved: Variant = raw.get("moved", {})
	if raw_moved is Dictionary:
		for id: Variant in raw_moved:
			if not id is String or id.length() >= 128:
				continue
			var position: Array = _coordinates(raw_moved[id], 3)
			if not position.is_empty():
				moved[id] = position
			if moved.size() >= 10000:
				break
	result["moved"] = moved
	return result


func _camera(raw: Dictionary) -> Dictionary:
	var phase: Variant = raw.get("native_phase")
	if not (phase is int or phase is float) or not is_finite(float(phase)) or float(phase) < 0.0 or float(phase) > 1.0:
		return {}
	var position: Array = _coordinates(raw.get("camera_position"), 3)
	var raw_basis: Variant = raw.get("camera_basis")
	if position.is_empty() or not raw_basis is Array or raw_basis.size() != 3:
		return {}
	var basis: Array = []
	for column: Variant in raw_basis:
		var coordinates: Array = _coordinates(column, 3)
		if coordinates.is_empty():
			return {}
		basis.append(coordinates)
	return {"native_phase": float(phase), "camera_position": position, "camera_basis": basis}


func _player_runtime(raw: Dictionary) -> Dictionary:
	if raw.get("schema_version") != 1:
		return {}
	var velocity: Array = _coordinates(raw.get("velocity"), 3)
	if velocity.is_empty():
		return {}
	for component: float in velocity:
		if absf(component) > 1000.0:
			return {}
	var result: Dictionary = {"schema_version": 1, "velocity": velocity,
		"grounded": raw.get("grounded", false) == true,
		"jumping": raw.get("jumping", false) == true,
		"crouching": raw.get("crouching", false) == true,
		"jump_origin_y": _number(raw.get("jump_origin_y"), 0.0, -10000000.0, 10000000.0),
		"jump_action": "jump_moving" if raw.get("jump_action") == "jump_moving" else "jump",
		"tick_fraction": _number(raw.get("tick_fraction"), 0.0, 0.0, 0.999999),
		"landing_remaining": _number(raw.get("landing_remaining"), 0.0, 0.0, 0.4),
		"attack_remaining": _number(raw.get("attack_remaining"), 0.0, 0.0, 2.0),
		"attack_recovery_remaining": _number(raw.get("attack_recovery_remaining"), 0.0, 0.0, 4.0),
		"hurt_remaining": _number(raw.get("hurt_remaining"), 0.0, 0.0, 2.0),
		"invulnerability_remaining": _number(raw.get("invulnerability_remaining"), 0.0, 0.0, 5.0)}
	var action: Variant = raw.get("visual_action")
	if action is String and action in ["idle", "walk", "run", "crouch", "crawl", "jump", "jump_moving", "fall", "attack", "hurt", "land"]:
		result["visual_action"] = action
		result["visual_phase"] = _number(raw.get("visual_phase"), 0.0, 0.0, 1.0)
	return result


func _coordinates(value: Variant, count: int) -> Array:
	if not value is Array or value.size() != count:
		return []
	var result: Array = []
	for coordinate: Variant in value:
		if not (coordinate is float or coordinate is int) or not is_finite(float(coordinate)) or absf(float(coordinate)) > 10000000.0:
			return []
		result.append(float(coordinate))
	return result


func _groups(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array:
		for item: Variant in value:
			if (item is int or item is float) and is_finite(float(item)) and float(item) == floorf(float(item)):
				var group: int = int(item)
				if group >= 0 and group <= 65535 and not group in result:
					result.append(group)
			if result.size() >= 2:
				break
	return result


func _number(value: Variant, fallback: float, low: float, high: float) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return clampf(float(value), low, high)
	return fallback


func _integer(value: Variant, fallback: int, low: int, high: int) -> int:
	return int(_number(value, float(fallback), float(low), float(high)))
