class_name NativeVoiceLibrary
extends RefCounted
## Local voice packs resolve one complete audiovisual cue at a time. Metadata
## is shared with the text service; no movie or audio stream is preloaded here.

const MANIFEST_PATH: String = "res://assets/localization/localization_manifest.json"
const GENERATED_ROOT: String = "res://assets/generated/"
const MAX_MANIFEST_BYTES: int = 4 * 1024 * 1024
static var _locale: String = "ru"
static var _manifest: Dictionary = {}
static var _loaded: bool = false
static var _manifest_path: String = MANIFEST_PATH
static var _asset_checks: Dictionary = {}
static var _manifest_reads: int = 0
static var _hash_reads: int = 0
static var _optional_pack_path: String = ""
static var _optional_pack_attempts: int = 0


static func set_locale(code: String) -> void:
	_locale = normalize_locale(code)


static func get_locale() -> String:
	return _locale


static func normalize_locale(code: String) -> String:
	var value: String = code.strip_edges().replace("_", "-").to_lower()
	if value.is_empty():
		return "ru"
	if value in ["pt", "pt-pt"]:
		return "pt-PT"
	if value in ["nb", "nb-no", "no-no"]:
		return "no"
	var parts: PackedStringArray = value.split("-", false)
	for index: int in range(1, parts.size()):
		if parts[index].length() == 2:
			parts[index] = parts[index].to_upper()
		elif parts[index].length() == 4:
			parts[index] = parts[index].capitalize()
	return "-".join(parts)


static func configure_manifest(path: String = MANIFEST_PATH) -> void:
	# Used when a local pack is replaced, and by isolated runtime fixtures.
	_manifest_path = path
	_manifest = {}
	_loaded = false
	_asset_checks.clear()
	_manifest_reads = 0
	_hash_reads = 0
	_optional_pack_path = ""
	_optional_pack_attempts = 0


static func get_manifest() -> Dictionary:
	if not _loaded:
		_loaded = true
		if _manifest_path == MANIFEST_PATH and not FileAccess.file_exists(_manifest_path):
			_mount_optional_pack()
		if FileAccess.file_exists(_manifest_path):
			var file := FileAccess.open(_manifest_path, FileAccess.READ)
			if file != null and file.get_length() <= MAX_MANIFEST_BYTES:
				_manifest_reads += 1
				var parsed: Variant = JSON.parse_string(file.get_as_text())
				if parsed is Dictionary and parsed.get("schema_version") == 1 and parsed.get("voices") is Dictionary:
					_manifest = parsed
	return _manifest


static func available_locales() -> Array[String]:
	var result: Array[String] = []
	var voices: Dictionary = _dictionary(get_manifest().get("voices"))
	for code: String in voices:
		if voices[code] is Dictionary:
			result.append(code)
	result.sort()
	return result


static func native_text_metadata(locale: String) -> Dictionary:
	var catalog: Dictionary = _dictionary(get_manifest().get("native_texts"))
	return _dictionary(catalog.get(_locale_key(catalog, normalize_locale(locale)))).duplicate(true)


static func cache_stats() -> Dictionary:
	return {"manifest_reads": _manifest_reads, "asset_checks": _asset_checks.size(), "hash_reads": _hash_reads,
		"optional_pack_path": _optional_pack_path, "optional_pack_attempts": _optional_pack_attempts}


static func resolve_movie(key: String, fallback_info: Dictionary) -> Dictionary:
	var manifest: Dictionary = get_manifest()
	var voices: Dictionary = _dictionary(manifest.get("voices"))
	var default_locale: String = normalize_locale(str(manifest.get("default_voice_locale", "ru")))
	var requested_failure: String = "missing_localized_cue"
	var candidates: Array[String] = [_locale]
	if default_locale != _locale:
		candidates.append(default_locale)
	for code: String in candidates:
		var actual: String = _locale_key(voices, code)
		var voice: Dictionary = _dictionary(voices.get(actual))
		var descriptor: Dictionary = _dictionary(_dictionary(voice.get("movies")).get(key))
		var checked: Dictionary = _pack_asset(descriptor, "VideoStream")
		if bool(checked.get("available", false)):
			var result: Dictionary = descriptor.duplicate(true)
			result.path = checked.path
			result.available = true
			result.requested_locale = _locale
			result.effective_locale = actual
			result.is_fallback = normalize_locale(actual) != _locale
			result.fallback_reason = requested_failure if result.is_fallback else ""
			result.movie_key = key
			return result
		if code == _locale:
			requested_failure = str(checked.get("reason", "missing_localized_cue"))
	# The imported base cue is also a complete movie, never an audio-only patch.
	var result: Dictionary = fallback_info.duplicate(true)
	result.path = generated_path(str(fallback_info.get("path", "")))
	result.available = not str(result.path).is_empty() and ResourceLoader.exists(str(result.path), "VideoStream")
	result.requested_locale = _locale
	# A generic user import has no reliable language tag. Only identify its voice
	# when the source SHA matches a verified localized descriptor for this cue.
	result.effective_locale = _base_movie_locale(key, fallback_info, voices)
	result.is_fallback = str(result.effective_locale) != _locale
	result.fallback_reason = requested_failure if result.is_fallback else ""
	result.movie_key = key
	if not result.available:
		result.fallback_reason = "no_available_cue"
	return result


static func resolve_audio(info: Dictionary) -> Dictionary:
	var result: Dictionary = info.duplicate()
	var sample_key: String = "g%03d_r%04d" % [int(info.get("group", 0)), int(info.get("resource_id", 0))]
	result.sample_key = sample_key
	result.asset_source = "generated"
	result.path = generated_path(str(info.get("path", "")))
	result.requested_locale = _locale
	result.effective_locale = ""
	result.is_fallback = false
	result.available = not str(result.path).is_empty() and ResourceLoader.exists(str(result.path), "AudioStream")
	var voices: Dictionary = _dictionary(get_manifest().get("voices"))
	var default_locale: String = normalize_locale(str(get_manifest().get("default_voice_locale", "ru")))
	var candidates: Array[String] = [_locale]
	if default_locale != _locale:
		candidates.append(default_locale)
	for code: String in candidates:
		var actual: String = _locale_key(voices, code)
		var voice: Dictionary = _dictionary(voices.get(actual))
		var descriptor: Dictionary = _dictionary(_dictionary(voice.get("audio_overrides")).get(sample_key))
		if descriptor.is_empty():
			continue
		var checked: Dictionary = _pack_asset(descriptor, "AudioStream")
		if not bool(checked.get("available", false)):
			continue
		# Voice data may replace the sample, not native gain, loop or group rules.
		result.path = checked.path
		result.asset_source = "voice_pack"
		result.sha256 = descriptor.get("sha256", "")
		result.source_sha256 = descriptor.get("source_sha256", "")
		result.effective_locale = actual
		result.is_fallback = normalize_locale(actual) != _locale
		result.available = true
		return result
	return result


static func generated_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	return GENERATED_ROOT.path_join(path)


static func _base_movie_locale(key: String, info: Dictionary, voices: Dictionary) -> String:
	var declared: String = str(info.get("voice_locale", ""))
	if not declared.is_empty():
		return normalize_locale(declared)
	var source_hash: String = str(info.get("source_sha256", ""))
	if source_hash.is_empty():
		return ""
	# Prefer the requested language for a genuinely byte-identical shared cue.
	var codes: Array = voices.keys()
	var requested: String = _locale_key(voices, _locale)
	codes.erase(requested)
	codes.push_front(requested)
	for code: String in codes:
		var descriptor: Dictionary = _dictionary(_dictionary(_dictionary(voices.get(code)).get("movies")).get(key))
		if str(descriptor.get("source_sha256", "")) == source_hash:
			return code
	return ""


static func _pack_asset(descriptor: Dictionary, type_hint: String) -> Dictionary:
	if descriptor.is_empty():
		return {"available": false, "reason": "missing_localized_cue"}
	var relative: Variant = descriptor.get("path", "")
	if not relative is String or relative.is_empty() or relative.is_absolute_path() or ":" in relative or "\\" in relative:
		return {"available": false, "reason": "invalid_asset_path"}
	for component: String in relative.split("/"):
		if component in ["", ".", ".."]:
			return {"available": false, "reason": "invalid_asset_path"}
	var path: String = _manifest_path.get_base_dir().path_join(relative)
	var expected: String = str(descriptor.get("sha256", "")).to_lower()
	var check_key: String = path + "|" + expected + "|" + type_hint
	if _asset_checks.has(check_key):
		return _asset_checks[check_key]
	var result: Dictionary = {"available": false, "path": path, "reason": "missing_asset"}
	if ResourceLoader.exists(path, type_hint):
		result.available = true
		result.reason = ""
		if not expected.is_empty():
			if not valid_sha256(expected):
				result.available = false
				result.reason = "invalid_asset_hash"
			elif FileAccess.file_exists(path):
				_hash_reads += 1
				if FileAccess.get_sha256(path) != expected:
					result.available = false
					result.reason = "asset_hash_mismatch"
	_asset_checks[check_key] = result
	return result


static func valid_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character: String in value:
		if not character in "0123456789abcdef":
			return false
	return true


static func _locale_key(catalog: Dictionary, code: String) -> String:
	if catalog.has(code):
		return code
	for candidate: String in catalog:
		if candidate.to_lower() == code.to_lower():
			return candidate
	return code


static func _dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _mount_optional_pack() -> void:
	# Optional data is considered only at the two documented distribution paths.
	# replace_files=false prevents an auxiliary pack from replacing core scripts.
	var executable_dir: String = OS.get_executable_path().get_base_dir()
	var directories: Array[String] = [executable_dir]
	if executable_dir.get_file().to_lower() == "clean":
		directories.append(executable_dir.get_base_dir())
	for directory: String in directories:
		var path: String = directory.path_join("Hugo_Languages.pck")
		if not FileAccess.file_exists(path):
			continue
		_optional_pack_attempts += 1
		if ProjectSettings.load_resource_pack(path, false) and FileAccess.file_exists(MANIFEST_PATH):
			_optional_pack_path = path
			return
