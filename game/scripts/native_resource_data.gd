class_name NativeResourceData
extends RefCounted
## Optional build-time binary data. Source JSON remains authoritative.
## Hash both the JSON and compressed payload; stale/damaged caches fall back.
## No dictionary cache is retained between levels, and objects are never decoded.

const SOURCE_ROOT: String = "res://assets/generated/"
const CACHE_ROOT: String = "res://assets/runtime_cache/"
const MAGIC: String = "HUGODAT1"
const HEADER_BYTES: int = 80
const MAX_DECODED_BYTES: int = 268435456
const MAX_CACHE_BYTES: int = 67108864
static var cache_hits: int = 0
static var json_reads: int = 0
static var rejected_caches: int = 0


static func read(path: String, cache_override: String = "") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var source: PackedByteArray = FileAccess.get_file_as_bytes(path)
	var cache_path: String = cache_override
	if cache_path.is_empty() and path.begins_with(SOURCE_ROOT) and not ".." in path.split("/"):
		cache_path = CACHE_ROOT + path.trim_prefix(SOURCE_ROOT) + ".hdata"
	if not cache_path.is_empty() and FileAccess.file_exists(cache_path):
		var cached: Variant = _decode_cache(cache_path, source)
		if cached is Dictionary:
			cache_hits += 1
			return cached as Dictionary
		rejected_caches += 1
	json_reads += 1
	var parsed: Variant = JSON.parse_string(source.get_string_from_utf8())
	return parsed as Dictionary if parsed is Dictionary else {}


static func encode(data: Dictionary, source: PackedByteArray) -> PackedByteArray:
	var raw: PackedByteArray = var_to_bytes(data)
	var payload: PackedByteArray = raw.compress(FileAccess.COMPRESSION_ZSTD)
	var header: PackedByteArray = MAGIC.to_ascii_buffer()
	header.append_array(_sha256(source))
	header.append_array(_sha256(payload))
	header.resize(HEADER_BYTES)
	header.encode_u64(72, raw.size())
	header.append_array(payload)
	return header


static func _decode_cache(path: String, source: PackedByteArray) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < HEADER_BYTES or file.get_length() > MAX_CACHE_BYTES:
		return null
	var header: PackedByteArray = file.get_buffer(HEADER_BYTES)
	if header.slice(0, 8).get_string_from_ascii() != MAGIC or header.slice(8, 40) != _sha256(source):
		return null
	var size: int = header.decode_u64(72)
	if size < 8 or size > MAX_DECODED_BYTES:
		return null
	var payload: PackedByteArray = file.get_buffer(file.get_length() - HEADER_BYTES)
	if _sha256(payload) != header.slice(40, 72):
		return null
	var decoded: PackedByteArray = payload.decompress(size, FileAccess.COMPRESSION_ZSTD)
	if decoded.size() != size:
		return null
	return bytes_to_var(decoded)


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()
