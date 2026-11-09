class_name HugoTexturePack
extends RefCounted
## Optional local, artist-reviewed replacements. Matching decoded source pixels
## keeps the same material/UVs across reused GLBs without modifying the originals.

const MANIFEST: String = "res://assets/hd/texture_pack.json"
static var _loaded: bool = false
static var _enabled: bool = true
static var _entries: Dictionary = {}
static var _source_sizes: Dictionary = {}
static var _source_keys: Dictionary = {}
static var _replacements: Dictionary = {}
static var _bindings: Dictionary = {}
static var _cleanup_pending: bool = false
const CLEANUP_INTERVAL_SECONDS: float = 2.0


static func is_available() -> bool:
	_load()
	return not _entries.is_empty()


static func set_enabled(value: bool) -> void:
	_load()
	_enabled = value
	_prune_unused()
	for id: int in _bindings.keys():
		var binding: Dictionary = _bindings[id]
		var material: Material = (binding.material as WeakRef).get_ref() as Material
		if material == null:
			_bindings.erase(id)
			continue
		_apply(material, binding)
	if not _enabled:
		# Original/performance mode must also release unused HD GPU allocations.
		# Weak entries still reuse a texture if another live owner holds it.
		for key: String in _replacements:
			var texture: Texture2D = _cached_replacement(key)
			if texture != null:
				_replacements[key] = weakref(texture)


static func get_status() -> Dictionary:
	_load()
	var active: int = 0
	for binding: Dictionary in _bindings.values():
		if (binding.material as WeakRef).get_ref() != null and bool(binding.get("replaced", false)):
			active += 1
	return {"available": not _entries.is_empty(), "enabled": _enabled and not _entries.is_empty(),
		"source_textures": _entries.size(), "active_materials": active}


static func bind_material(material: Material, source: Texture2D) -> void:
	if material == null or source == null:
		return
	_load()
	# Rebinding an animated material updates the original frame too, so changing
	# quality never freezes its sequence or restores a previously selected frame.
	var id: int = material.get_instance_id()
	var binding: Dictionary = _bindings.get(id, {}) as Dictionary
	if binding.is_empty() or (binding.material as WeakRef).get_ref() != material:
		binding = {"material": weakref(material), "source": source,
			"filter": (material as BaseMaterial3D).texture_filter if material is BaseMaterial3D else -1}
	else:
		binding.source = source
	_bindings[id] = binding
	_apply(material, binding)
	_schedule_cleanup()


static func resolve(source: Texture2D) -> Texture2D:
	_load()
	if source == null or not _enabled or _entries.is_empty():
		return source
	var key: String = _source_key(source)
	if not _entries.has(key):
		return source
	if _replacements.has(key):
		var cached: Texture2D = _cached_replacement(key)
		if cached != null:
			_replacements[key] = cached
			return cached
	var path: String = MANIFEST.get_base_dir().path_join(str(_entries[key].path))
	var replacement: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
	if replacement == null:
		return source
	# Standalone PNGs are often imported as 2D art without mipmaps. Build them
	# once for this 3D texture, so anisotropic filtering does not shimmer at a
	# distance. This keeps user copies and imported original resources intact.
	var image: Image = replacement.get_image()
	if image != null and not image.is_empty() and not image.has_mipmaps():
		image = image.duplicate() as Image
		if not image.is_compressed() or image.decompress() == OK:
			image.generate_mipmaps()
			replacement = ImageTexture.create_from_image(image)
	_replacements[key] = replacement
	return replacement


static func _cached_replacement(key: String) -> Texture2D:
	var value: Variant = _replacements.get(key)
	if value is WeakRef:
		return (value as WeakRef).get_ref() as Texture2D
	return value as Texture2D


static func _apply(material: Material, binding: Dictionary) -> void:
	var original: Texture2D = binding.source as Texture2D
	var texture: Texture2D = resolve(original)
	binding["replaced"] = texture != original
	if material is BaseMaterial3D:
		var standard: BaseMaterial3D = material as BaseMaterial3D
		standard.albedo_texture = texture
		standard.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC \
			if texture != original else int(binding.filter) as BaseMaterial3D.TextureFilter
	elif material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter("albedo_texture", texture)


static func _source_key(source: Texture2D) -> String:
	# Dimensions are part of the verified pixel key. A noncandidate texture
	# never needs a GPU readback, decompression or pixel hash.
	var dimensions: String = "%dx%d" % [source.get_width(), source.get_height()]
	if not _source_sizes.has(dimensions):
		return ""
	var id: int = source.get_instance_id()
	if _source_keys.has(id):
		var cached: Dictionary = _source_keys[id]
		if (cached.source as WeakRef).get_ref() == source:
			return str(cached.key)
	var image: Image = source.get_image()
	if image == null or image.is_empty():
		return ""
	image = image.duplicate() as Image
	if image.is_compressed() and image.decompress() != OK:
		return ""
	image.clear_mipmaps()
	image.convert(Image.FORMAT_RGBA8)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(image.get_data())
	var key: String = "%dx%d:%s" % [image.get_width(), image.get_height(), hash.finish().hex_encode()]
	_source_keys[id] = {"source": weakref(source), "key": key}
	_schedule_cleanup()
	return key


static func _schedule_cleanup() -> void:
	if _cleanup_pending or (_bindings.is_empty() and _source_keys.is_empty()):
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_cleanup_pending = true
	# Keep originals alive while their materials need the live quality toggle,
	# then release them after a level/actor unload without requiring that toggle.
	# Wall-clock time also works while the menu is paused or time_scale is zero.
	tree.create_timer(CLEANUP_INTERVAL_SECONDS, true, false, true).timeout.connect(_cleanup, CONNECT_ONE_SHOT)


static func _cleanup() -> void:
	_cleanup_pending = false
	_prune_unused()
	_schedule_cleanup()


static func _prune_unused() -> void:
	for id: int in _bindings.keys():
		if (_bindings[id].material as WeakRef).get_ref() == null:
			_bindings.erase(id)
	for id: int in _source_keys.keys():
		if (_source_keys[id].source as WeakRef).get_ref() == null:
			_source_keys.erase(id)


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(MANIFEST):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		return
	var textures: Variant = parsed.get("textures", {})
	if not textures is Dictionary:
		return
	for key: String in textures:
		var entry: Variant = textures[key]
		if not entry is Dictionary:
			continue
		var path: String = str(entry.get("path", ""))
		if path.is_empty() or path.is_absolute_path() or ".." in path.split("/") or ":" in path:
			continue
		if ResourceLoader.exists(MANIFEST.get_base_dir().path_join(path), "Texture2D"):
			_entries[key] = entry.duplicate(true)
			_source_sizes[key.get_slice(":", 0)] = true
