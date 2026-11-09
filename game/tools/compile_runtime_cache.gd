extends SceneTree
## Run after the importer: godot --headless --path game --script res://tools/compile_runtime_cache.gd
## Generated cache is optional, private and reproducible from the exact JSON bytes.

const Data = preload("res://scripts/native_resource_data.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var paths: Array[String] = ["campaign.json", "gameplay_manifest.json", "animation_manifest.json", "material_animation_manifest.json"]
	var catalog: Dictionary = Data.read(Data.SOURCE_ROOT + "campaign.json")
	for level: Dictionary in catalog.get("levels", []):
		paths.append(str(level.manifest_path))
	var results: Array[Dictionary] = []
	for relative: String in paths:
		var path: String = Data.SOURCE_ROOT + relative
		if not FileAccess.file_exists(path):
			continue
		var source: PackedByteArray = FileAccess.get_file_as_bytes(path)
		var parsed: Variant = JSON.parse_string(source.get_string_from_utf8())
		if not parsed is Dictionary:
			push_error("Invalid source JSON: " + relative)
			quit(1)
			return
		var packed: PackedByteArray = Data.encode(parsed as Dictionary, source)
		var target: String = Data.CACHE_ROOT + relative + ".hdata"
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var output: FileAccess = FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			push_error("Cannot create runtime cache: " + relative)
			quit(1)
			return
		output.store_buffer(packed)
		output.close()
		var hits: int = Data.cache_hits
		if Data.read(path) != parsed or Data.cache_hits != hits + 1:
			push_error("Binary cache round trip failed: " + relative)
			quit(1)
			return
		results.append({"source": relative, "source_bytes": source.size(), "cache_bytes": packed.size(),
			"source_sha256": FileAccess.get_sha256(path), "cache_sha256": FileAccess.get_sha256(target)})
		print("RUNTIME_CACHE_FILE ", JSON.stringify(results[-1]))
	var file: FileAccess = FileAccess.open(Data.CACHE_ROOT + "manifest.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema_version": 1, "files": results}, "\t"))
	file.close()
	print("RUNTIME_CACHE ", JSON.stringify({"files": results.size(), "verified": true}))
	quit(0)
