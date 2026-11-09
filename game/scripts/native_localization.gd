class_name NativeLocalization
extends RefCounted
## UI text is cached once, native text once per selected locale. No frame polling.
## Extracted original text remains optional private data, separate from authored UI.

signal language_changed(locale: String)

const VoiceScript = preload("res://scripts/native_voice_library.gd")
const CATALOG_PATH: String = "res://localization/ui_catalog.json"
const DATA_ROOT: String = "res://assets/localization/"
const DEFAULT_LOCALE: String = "ru"
const LOCALES: Array[String] = ["ru", "en", "da", "sv", "no", "fi", "fr", "es", "it", "pt-PT", "nl", "de", "cs", "hu", "sk", "pl"]
const NATIVE_NAMES: Dictionary = {"ru": "Русский", "en": "English", "da": "Dansk", "sv": "Svenska", "no": "Norsk", "fi": "Suomi", "fr": "Français", "es": "Español", "it": "Italiano", "pt-PT": "Português", "nl": "Nederlands", "de": "Deutsch", "cs": "Čeština", "hu": "Magyar", "sk": "Slovenčina", "pl": "Polski"}
const NATIVE_KEYS: Dictionary = {"brand.name": 23, "brand.subtitle": 27,
	"chapter.6": 51, "chapter.17": 55, "chapter.27": 56, "chapter.36": 57,
	"chapter.46": 58, "chapter.55": 59, "chapter.59": 60, "chapter.69": 61}

static var _events: NativeLocalization
static var _locale: String = DEFAULT_LOCALE
static var _catalog: Dictionary = {}
static var _loaded: bool = false
static var _native_cache: Dictionary = {}
static var _catalog_reads: int = 0
static var _native_reads: int = 0
static var _ui_font: Font


static func events() -> NativeLocalization:
	if _events == null:
		_events = NativeLocalization.new()
	return _events


static func sanitize_locale(value: Variant, fallback: String = DEFAULT_LOCALE) -> String:
	if not value is String:
		return fallback
	var code: String = value.strip_edges().replace("_", "-").to_lower()
	if code in ["pt", "pt-pt"]:
		return "pt-PT"
	if code in ["nb", "nb-no", "no-no"]:
		return "no"
	# An unverified regional voice (notably pt-BR) is not relabelled as another.
	if code in LOCALES:
		return code
	for prefix: String in ["en", "ru", "da", "sv", "fi", "fr", "es", "it", "nl", "de", "cs", "hu", "sk", "pl"]:
		if code.begins_with(prefix + "-"):
			return prefix
	return fallback


static func sanitize_voice_locale(value: Variant, fallback: String = DEFAULT_LOCALE) -> String:
	if not value is String:
		return fallback
	var code: String = value.strip_edges().replace("_", "-")
	if code.length() > 63:
		return fallback
	var parts: PackedStringArray = code.split("-")
	if parts.is_empty() or parts[0].length() < 2 or parts[0].length() > 3:
		return fallback
	for index: int in range(parts.size()):
		var part: String = parts[index]
		if part.is_empty() or part.length() > 8:
			return fallback
		for offset: int in range(part.length()):
			var character: int = part.unicode_at(offset)
			var letter: bool = (character >= 65 and character <= 90) or (character >= 97 and character <= 122)
			if not letter and not (index > 0 and character >= 48 and character <= 57):
				return fallback
	# A valid unavailable voice stays a request. Only verified installed voices
	# appear in the picker; the voice resolver reports its actual cue fallback.
	return VoiceScript.normalize_locale(code)


static func set_text_locale(value: String) -> void:
	_initialize()
	var code: String = sanitize_locale(value)
	_load_native(code)
	if code == _locale:
		return
	_locale = code
	events().language_changed.emit(code)


static func get_text_locale() -> String:
	return _locale


static func available_text_locales() -> Array[String]:
	_initialize()
	var result: Array[String] = []
	for code: String in LOCALES:
		if _catalog.has(code):
			result.append(code)
	return result


static func language_name(code: String) -> String:
	var normalized: String = sanitize_locale(code, "")
	if NATIVE_NAMES.has(normalized):
		return str(NATIVE_NAMES[normalized])
	var voices: Dictionary = VoiceScript.get_manifest().get("voices", {})
	return str(voices.get(code, {}).get("native_name", code))


static func text(key: String, arguments: Dictionary = {}) -> String:
	_initialize()
	var messages: Dictionary = _catalog.get(_locale, {}).get("messages", {})
	var fallback: Dictionary = _catalog.get("en", {}).get("messages", {})
	var value: String = str(messages.get(key, fallback.get(key, key)))
	if NATIVE_KEYS.has(key):
		value = native_text(int(NATIVE_KEYS[key]), value)
	return value if arguments.is_empty() else value.format(arguments)


static func native_text(id: int, fallback: String = "", locale: String = "") -> String:
	var code: String = _locale if locale.is_empty() else sanitize_locale(locale)
	_load_native(code)
	var strings: Array = _native_cache.get(code, [])
	if id >= 0 and id < strings.size() and not str(strings[id]).is_empty():
		return str(strings[id])
	return fallback


static func chapter_title(group: int, fallback: String = "") -> String:
	var key: String = "chapter.%d" % group
	if NATIVE_KEYS.has(key):
		return text(key)
	return fallback if not fallback.is_empty() else text("chapter.fallback")


static func has_key(key: String) -> bool:
	_initialize()
	return _catalog.get("en", {}).get("messages", {}).has(key)


static func catalog_snapshot() -> Dictionary:
	_initialize()
	return _catalog.duplicate(true)


static func cache_stats() -> Dictionary:
	return {"catalog_reads": _catalog_reads, "native_reads": _native_reads,
		"native_locales_cached": _native_cache.size()}


static func validate_native_strings(payload: Variant, locale: String) -> Array:
	if not payload is Dictionary or payload.get("schema_version") != 1 or payload.get("locale") != locale:
		return []
	var strings: Variant = payload.get("strings")
	if not strings is Array or strings.size() != 205:
		return []
	for value: Variant in strings:
		if not value is String or value.length() > 8192:
			return []
	return strings


static func decode_native_bytes(data: PackedByteArray, locale: String, metadata: Dictionary = {}) -> Array:
	if metadata.has("sha256"):
		var expected: Variant = metadata.sha256
		if not expected is String or expected.length() != 64:
			return []
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK or digest.update(data) != OK:
			return []
		if digest.finish().hex_encode() != expected.to_lower():
			return []
	return validate_native_strings(JSON.parse_string(data.get_string_from_utf8()), locale)


static func _initialize() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(CATALOG_PATH):
		_catalog_reads += 1
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
		if parsed is Dictionary and parsed.get("schema_version") == 1 and parsed.get("locales") is Dictionary:
			_catalog = parsed.locales
	# Keep the engine's bundled Cyrillic/Latin font. Symbol fallback is cached by
	# Godot and uses installed platform fonts; no font is opened by frame updates.
	var font := FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	var symbols := SystemFont.new()
	symbols.font_names = PackedStringArray(["Segoe UI Symbol", "Noto Sans Symbols 2", "DejaVu Sans", "Symbola"])
	font.fallbacks = [symbols]
	_ui_font = font
	ThemeDB.fallback_font = _ui_font


static func _load_native(code: String) -> void:
	if _native_cache.has(code):
		return
	_native_cache[code] = []
	var metadata: Dictionary = VoiceScript.native_text_metadata(code)
	var relative: Variant = metadata.get("path", "")
	if not relative is String or relative.is_empty() or relative.is_absolute_path() or "\\" in relative or ":" in relative:
		return
	for component: String in relative.split("/"):
		if component in ["", ".", ".."]:
			return
	var path: String = DATA_ROOT + relative
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 4 * 1024 * 1024:
		return
	_native_reads += 1
	var data: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	_native_cache[code] = decode_native_bytes(data, code, metadata)
