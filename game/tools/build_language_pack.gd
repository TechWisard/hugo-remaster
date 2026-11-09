extends SceneTree
## Package only verified localization payloads. No scripts or core overrides.
## --script res://tools/build_language_pack.gd -- --language-pack-output=/path/Hugo_Languages.pck

const ROOT: String = "res://assets/localization/"
var output_path: String = ""


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--language-pack-output="):
			output_path = arg.trim_prefix("--language-pack-output=")
	_run.call_deferred()


func _run() -> void:
	if output_path.is_empty():
		_fail("Specify --language-pack-output")
		return
	var manifest_path: String = ROOT + "localization_manifest.json"
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or int(manifest.get("schema_version", 0)) != 1:
		_fail("Import verified languages first")
		return
	var files: Dictionary = {"localization_manifest.json": FileAccess.get_sha256(manifest_path)}
	for voice: Dictionary in manifest.get("voices", {}).values():
		for movie: Dictionary in voice.get("movies", {}).values():
			if not _add_payload(files, movie, "ogv"):
				return
	for entry: Dictionary in manifest.get("native_texts", {}).values():
		if not _add_payload(files, entry, "json"):
			return
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var temporary: String = output_path + ".tmp"
	var pack := PCKPacker.new()
	if pack.pck_start(temporary) != OK:
		_fail("Cannot create language pack")
		return
	var names: Array = files.keys()
	names.sort()
	for relative: String in names:
		if pack.add_file(ROOT + relative, ROOT + relative) != OK:
			_fail("Cannot pack " + relative)
			return
	if pack.flush() != OK:
		_fail("Cannot finish language pack")
		return
	pack = null
	if DirAccess.rename_absolute(temporary, output_path) != OK:
		_fail("Cannot publish language pack")
		return
	var file: FileAccess = FileAccess.open(output_path, FileAccess.READ)
	print("LANGUAGE_PACK ", JSON.stringify({"files": files.size(), "voices": manifest.voices.size(),
		"text_locales": manifest.native_texts.size(), "bytes": file.get_length(), "sha256": FileAccess.get_sha256(output_path)}))
	quit(0)


func _add_payload(files: Dictionary, entry: Dictionary, extension: String) -> bool:
	var relative: String = str(entry.get("path", ""))
	if relative.is_empty() or relative.is_absolute_path() or ":" in relative or ".." in relative.split("/") \
		or relative.get_extension() != extension or not FileAccess.file_exists(ROOT + relative):
		_fail("Invalid localization payload path")
		return false
	var hash: String = str(entry.get("sha256", ""))
	if hash.length() != 64 or FileAccess.get_sha256(ROOT + relative) != hash:
		_fail("Localization payload failed SHA256: " + relative)
		return false
	if files.has(relative) and files[relative] != hash:
		_fail("Conflicting localization payload")
		return false
	files[relative] = hash
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
