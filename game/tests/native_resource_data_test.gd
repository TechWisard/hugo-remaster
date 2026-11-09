extends SceneTree

const Data = preload("res://scripts/native_resource_data.gd")
var failures: Array[String] = []
var checks: int = 0
var source_path: String = "user://data_cache_fixture.json"
var cache_path: String = "user://data_cache_fixture.hdata"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var original: Dictionary = {"text": "Кузя — Příběh — Łódź", "value": -1.125,
		"keys": [{"time": 0.0, "position": [1.0, 2.0, -0.00001]}], "null": null, "flag": true}
	var json_bytes: PackedByteArray = JSON.stringify(original).to_utf8_buffer()
	_write(source_path, json_bytes)
	if FileAccess.file_exists(cache_path):
		DirAccess.remove_absolute(cache_path)
	_check(Data.read(source_path, cache_path) == original, "JSON fallback without cache")
	var encoded: PackedByteArray = Data.encode(original, json_bytes)
	_write(cache_path, encoded)
	_check(Data.read(source_path, cache_path) == original and Data.cache_hits == 1, "binary dictionary round trip")
	var updated: Dictionary = original.duplicate(true)
	updated.text = "changed source"
	_write(source_path, JSON.stringify(updated).to_utf8_buffer())
	_check(Data.read(source_path, cache_path) == updated, "stale source hash rejects old cache")
	_write(source_path, json_bytes)
	var corrupt: PackedByteArray = encoded.duplicate()
	corrupt[-1] ^= 1
	_write(cache_path, corrupt)
	_check(Data.read(source_path, cache_path) == original, "damaged compressed payload falls back")
	_write(cache_path, encoded.slice(0, 20))
	_check(Data.read(source_path, cache_path) == original, "truncated header falls back")
	corrupt = encoded.duplicate()
	corrupt.encode_u64(72, Data.MAX_DECODED_BYTES + 1)
	_write(cache_path, corrupt)
	_check(Data.read(source_path, cache_path) == original, "oversized decoded length rejected")
	_check(Data.read("user://missing_source.json", cache_path).is_empty(), "cache cannot replace a missing source")
	_check(Data.rejected_caches == 4, "all four rejected caches recorded")
	DirAccess.remove_absolute(source_path)
	DirAccess.remove_absolute(cache_path)
	print("NATIVE_RESOURCE_DATA ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _write(path: String, bytes: PackedByteArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)
