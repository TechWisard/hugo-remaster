class_name HugoTexturePack
extends RefCounted
## Optional local replacements, matched by decoded RGBA instead of GLB slot.
## Coverage is reported separately from image dimensions: filtering or a large
## file alone never establishes that a texture was redrawn or visually reviewed.

const MANIFEST: String = "res://assets/hd/texture_pack.json"
class AnimationFrames extends RefCounted:
	var sources: Dictionary = {}
	var resolved: Dictionary = {}
	var revision: int = -1
	func clear() -> void:
		sources.clear()
		resolved.clear()
		revision = -1

static var _manifest_path: String = MANIFEST
static var _animation_revision: int = 0
static var _animation_caches: Dictionary = {}
static var _replacement_load_counts: Dictionary = {}
static var _loaded: bool = false
static var _enabled: bool = true
static var _max_texture_dimension: int = 0
static var _entries: Dictionary = {}
static var _source_sizes: Dictionary = {}
static var _source_keys: Dictionary = {}
static var _runtime_aliases: Dictionary = {}
static var _replacements: Dictionary = {}
static var _replacement_info: Dictionary = {}
static var _bindings: Dictionary = {}
static var _quality_shaders: Dictionary = {}
static var _declared_entries: Dictionary = {}
static var _manifest_errors: Dictionary = {}
static var _load_failures: Dictionary = {}
static var _cleanup_pending: bool = false
const CLEANUP_INTERVAL_SECONDS: float = 2.0


static func is_available() -> bool:
	_load()
	return not _entries.is_empty()


static func load_manifest(path: String = MANIFEST) -> bool:
	_manifest_path = path
	_loaded = false
	for table: Dictionary in [_entries,_declared_entries,_source_sizes,_source_keys,_runtime_aliases,
		_replacements,_replacement_info,_manifest_errors,_load_failures]:
		table.clear()
	invalidate_animation_frames()
	set_enabled(_enabled)
	return not _entries.is_empty()


static func invalidate_animation_frames() -> void:
	_animation_revision += 1
	for reference: WeakRef in _animation_caches.values():
		var frames: AnimationFrames = reference.get_ref() as AnimationFrames
		if frames != null:
			frames.clear()


static func animation_revision() -> int:
	return _animation_revision


static func create_animation_cache() -> AnimationFrames:
	var frames := AnimationFrames.new()
	frames.revision = _animation_revision
	_animation_caches[frames.get_instance_id()] = weakref(frames)
	_schedule_cleanup()
	return frames


static func retain_animation_frame(frames: AnimationFrames, source: Texture2D) -> void:
	if frames != null and source != null:
		frames.resolved[source.get_instance_id()] = resolve(source)
		frames.revision = _animation_revision


static func is_enabled() -> bool:
	# The user's quality choice also controls analytical effects and samplers,
	# even on a clean checkout without the optional local texture pack.
	return _enabled


static func set_max_texture_dimension(value: int) -> void:
	## A memory tier uses the SAME authored replacement, never the low-resolution
	## source. Zero keeps the full imported resolution. 512/1024 suit smaller GPUs.
	var limit: int = 0 if value <= 0 else maxi(256, value)
	if limit == _max_texture_dimension:
		return
	_max_texture_dimension = limit
	invalidate_animation_frames()
	_load_failures.clear()
	set_enabled(_enabled)


static func set_enabled(value: bool) -> void:
	_load()
	if _enabled != value:
		invalidate_animation_frames()
	_enabled = value
	_prune_unused()
	for id: int in _bindings.keys():
		var binding: Dictionary = _bindings[id]
		var material: Material = (binding.material as WeakRef).get_ref() as Material
		if material == null:
			_bindings.erase(id)
			continue
		_apply(material, binding)
	for binding: Dictionary in _quality_shaders.values():
		var material: ShaderMaterial = (binding.material as WeakRef).get_ref() as ShaderMaterial
		if material != null:
			material.shader = binding.enhanced if _enabled else binding.original


static func get_status() -> Dictionary:
	_load()
	_prune_unused()
	var active: int = 0
	var bound: int = 0
	var missing: int = 0
	var reasons: Dictionary = {}
	for binding: Dictionary in _bindings.values():
		if (binding.material as WeakRef).get_ref() == null:
			continue
		bound += 1
		if bool(binding.get("replaced", false)):
			active += 1
		elif _enabled:
			missing += 1
			var reason: String = str(binding.get("fallback_reason", "unmatched_source"))
			reasons[reason] = int(reasons.get(reason, 0)) + 1
	var live_bytes: int = 0
	var resident: Dictionary = {}
	for path: String in _replacements:
		var texture: Texture2D = _cached_replacement(path)
		if texture != null and not resident.has(texture.get_instance_id()):
			resident[texture.get_instance_id()] = true
			live_bytes += int(_replacement_info.get(path, {}).get("storage_bytes", 0))
	return {"available": not _entries.is_empty(), "enabled": _enabled,
		"source_textures": _entries.size(), "declared_textures": _declared_entries.size(),
		"bound_materials": bound, "active_materials": active, "missing_materials": missing,
		"bound_coverage_complete": _enabled and bound > 0 and missing == 0,
		"fallback_reasons": reasons, "manifest_errors": _manifest_errors.duplicate(),
		"resident_textures": resident.size(), "resident_image_bytes": live_bytes,
		"max_texture_dimension": _max_texture_dimension,
		"untextured_quality_materials": _quality_shaders.size(),
		"live_animation_frame_caches": _animation_caches.size(),
		"replacement_resource_loads": _replacement_load_counts.values().reduce(func(total: int,value: Variant)->int:return total+int(value),0),
		"memory_note": "Resident texture image data, including mipmaps; not total driver VRAM."}


static func bind_material(material: Material, source: Texture2D,
		texture_parameter: StringName = &"albedo_texture", enhanced_shader: Shader = null,
		original_shader: Shader = null) -> void:
	if material == null or source == null:
		return
	_load()
	# Rebinding an animated material updates the original frame too, so changing
	# quality never freezes its sequence or restores a previously selected frame.
	var id: int = material.get_instance_id()
	if _quality_shaders.has(id) and (_quality_shaders[id].material as WeakRef).get_ref() == material:
		# Some native sequences begin on a vertex-colour-only surface. Once its
		# first bitmap arrives, transfer both quality shaders to the real texture
		# binding; subsequent phases must not resurrect the Enhanced shader in
		# Original mode merely because that was active when registration happened.
		if enhanced_shader == null:
			enhanced_shader = _quality_shaders[id].enhanced as Shader
		if original_shader == null:
			original_shader = _quality_shaders[id].original as Shader
		_quality_shaders.erase(id)
	var binding: Dictionary = _bindings.get(id, {}) as Dictionary
	if binding.is_empty() or (binding.material as WeakRef).get_ref() != material:
		binding = {"material": weakref(material), "source": source,
			"filter": (material as BaseMaterial3D).texture_filter if material is BaseMaterial3D else -1,
			"base_color": (material as BaseMaterial3D).albedo_color if material is BaseMaterial3D else Color.WHITE,
			"texture_parameter": texture_parameter,
			"original_shader": original_shader if original_shader != null else \
				((material as ShaderMaterial).shader if material is ShaderMaterial else null),
			"enhanced_shader": enhanced_shader}
	else:
		binding.source = source
	_bindings[id] = binding
	_apply(material, binding)
	_schedule_cleanup()


static func get_bound_source(material: Material) -> Texture2D:
	if material != null and _bindings.has(material.get_instance_id()):
		var binding: Dictionary = _bindings[material.get_instance_id()]
		if (binding.material as WeakRef).get_ref() == material:
			return binding.source as Texture2D
	return null


static func bind_quality_shader(material: ShaderMaterial, enhanced: Shader, original: Shader) -> void:
	## Vertex-coloured faces (including eye whites) have no bitmap to bind, but
	## their normal-based light response still follows the same quality toggle.
	if material == null:
		return
	_quality_shaders[material.get_instance_id()] = {"material": weakref(material),
		"enhanced": enhanced, "original": original}
	material.shader = enhanced if _enabled else original
	_schedule_cleanup()


static func get_source_key(source: Texture2D) -> String:
	## Explicit audit requests include noncandidate dimensions. Normal rendering
	## only hashes a source once, and only if the pack contains that size.
	_load()
	return _source_key(source, true) if source != null else ""


static func get_runtime_source_key(source: Texture2D) -> String:
	get_source_key(source)
	return str(_source_keys.get(source.get_instance_id(), {}).get("runtime_key", "")) if source != null else ""


static func get_manifest_entries() -> Dictionary:
	_load()
	return _declared_entries.duplicate(true)


static func resolve(source: Texture2D) -> Texture2D:
	_load()
	if source == null or not _enabled or _entries.is_empty():
		return source
	var key: String = _source_key(source)
	if not _entries.has(key):
		return source
	var path: String = _manifest_path.get_base_dir().path_join(_replacement_path(_entries[key]))
	var cache_key: String = "%s@%d" % [path, _max_texture_dimension]
	# Several source keys can intentionally share one authored texture. Cache by
	# actual resource path, and never keep a strong GPU owner after scene unload.
	var cached: Texture2D = _cached_replacement(cache_key)
	if cached != null:
		return cached
	if _load_failures.has(key):
		return source
	_replacement_load_counts[cache_key] = int(_replacement_load_counts.get(cache_key,0))+1
	var replacement: Texture2D = ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if replacement == null:
		_load_failures[key] = "replacement_load_failed"
		return source
	# Standalone PNGs are often imported as 2D art without mipmaps. Build them
	# once for this 3D texture, so anisotropic filtering does not shimmer at a
	# distance. This keeps user copies and imported original resources intact.
	var image: Image = replacement.get_image()
	if image == null or image.is_empty():
		_load_failures[key] = "replacement_image_unreadable"
		return source
	var must_resize: bool = _max_texture_dimension > 0 and maxi(image.get_width(), image.get_height()) > _max_texture_dimension
	if must_resize:
		image = image.duplicate() as Image
		if image.is_compressed() and image.decompress() != OK:
			_load_failures[key] = "replacement_resolution_tier_unavailable"
			return source
		var ratio: float = float(_max_texture_dimension) / maxi(image.get_width(), image.get_height())
		image.clear_mipmaps()
		image.resize(maxi(1, roundi(image.get_width() * ratio)), maxi(1, roundi(image.get_height() * ratio)), Image.INTERPOLATE_LANCZOS)
	if not image.has_mipmaps():
		image = image.duplicate() as Image
		if image.is_compressed() and image.decompress() != OK:
			_load_failures[key] = "replacement_mipmaps_unavailable"
			return source
		if image.generate_mipmaps() != OK:
			_load_failures[key] = "replacement_mipmap_generation_failed"
			return source
		replacement = ImageTexture.create_from_image(image)
	_replacements[cache_key] = weakref(replacement)
	_replacement_info[cache_key] = {"width": image.get_width(), "height": image.get_height(),
		"storage_bytes": image.get_data_size(), "mipmaps": image.has_mipmaps(),
		"opaque": not image.is_compressed() and image.detect_alpha() == Image.ALPHA_NONE}
	_schedule_cleanup()
	return replacement


static func _replacement_path(entry: Dictionary) -> String:
	var relative: String = str(entry.path)
	var selected: int = 0
	# Optional offline tiers avoid the one-time runtime resize/upload. They are
	# deliberately explicit in the manifest so exports can include every file.
	if _max_texture_dimension > 0:
		for dimension: String in entry.get("tiers", {}):
			var size: int = int(dimension)
			if size > selected and size <= _max_texture_dimension:
				var candidate: String = str(entry.tiers[dimension])
				if _valid_relative_path(candidate) and ResourceLoader.exists(MANIFEST.get_base_dir().path_join(candidate), "Texture2D"):
					selected = size
					relative = candidate
	return relative


static func _cached_replacement(key: String) -> Texture2D:
	var reference: WeakRef = _replacements.get(key) as WeakRef
	return reference.get_ref() as Texture2D if reference != null else null


static func _apply(material: Material, binding: Dictionary) -> void:
	var original: Texture2D = binding.source as Texture2D
	var texture: Texture2D = resolve(original)
	binding["replaced"] = texture != original
	binding["fallback_reason"] = _fallback_reason(original) if texture == original else ""
	var alpha_scale: float = 1.0
	var source_alpha_mask: bool = false
	if texture != original:
		var source_info: Dictionary = _source_keys.get(original.get_instance_id(), {})
		var uniform_alpha: int = int(source_info.get("uniform_alpha", -1))
		var positive_alpha: int = int(source_info.get("uniform_positive_alpha", uniform_alpha))
		var entry: Dictionary = _entries.get(str(source_info.get("key", "")), {})
		source_alpha_mask = material is ShaderMaterial and str(entry.get("alpha_policy", "")) == "source_mask"
		if not source_alpha_mask and not entry.is_empty() and (uniform_alpha == 0 or (positive_alpha > 0 and positive_alpha < 255)):
			var cache_key: String = "%s@%d" % [_manifest_path.get_base_dir().path_join(_replacement_path(entry)), _max_texture_dimension]
			var authored_max: int = int(entry.get("replacement_alpha_max", \
				255 if bool(_replacement_info.get(cache_key, {}).get("opaque", false)) else -1))
			if authored_max > 0:
				# A source may encode uniform half opacity with or without a zero
				# cutout background. Keep the new smooth outline, restore its
				# positive-alpha scale, and never halve a PNG already at 128.
				alpha_scale = float(maxi(uniform_alpha, 0) if uniform_alpha == 0 else positive_alpha) / float(authored_max)
	binding["source_alpha_scale"] = alpha_scale
	binding["source_alpha_mask"] = source_alpha_mask
	if material is BaseMaterial3D:
		var standard: BaseMaterial3D = material as BaseMaterial3D
		standard.albedo_texture = texture
		var color: Color = binding.base_color
		color.a *= alpha_scale
		standard.albedo_color = color
		standard.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC \
			if _enabled else int(binding.filter) as BaseMaterial3D.TextureFilter
	elif material is ShaderMaterial:
		var shader_material: ShaderMaterial = material as ShaderMaterial
		var shader: Shader = binding.get("enhanced_shader") as Shader if _enabled else binding.get("original_shader") as Shader
		if shader != null and shader_material.shader != shader:
			shader_material.shader = shader
		shader_material.set_shader_parameter(binding.texture_parameter, texture)
		shader_material.set_shader_parameter("source_alpha_scale", alpha_scale)
		shader_material.set_shader_parameter("use_source_alpha", source_alpha_mask)
		shader_material.set_shader_parameter("source_alpha_texture", original if source_alpha_mask else null)


static func _fallback_reason(source: Texture2D) -> String:
	if not _enabled:
		return "original_mode"
	var key: String = _source_key(source)
	if _load_failures.has(key):
		return str(_load_failures[key])
	if _manifest_errors.has(key):
		return str(_manifest_errors[key])
	return "pack_unavailable" if _entries.is_empty() else "unmatched_source"


static func get_binding_report(material: Material, inspect_image: bool = true) -> Dictionary:
	## Inspect the texture actually assigned to the material, not a manifest count.
	## This deliberately expensive API is for QA, never called per rendered frame.
	if material == null or not _bindings.has(material.get_instance_id()):
		return {"bound": false}
	var binding: Dictionary = _bindings[material.get_instance_id()]
	if (binding.material as WeakRef).get_ref() != material:
		return {"bound": false}
	var source: Texture2D = binding.source as Texture2D
	var texture: Texture2D
	var sampler: String = "unknown"
	if material is BaseMaterial3D:
		texture = (material as BaseMaterial3D).albedo_texture
		sampler = "linear_mipmap_anisotropic" if (material as BaseMaterial3D).texture_filter == \
			BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC else str((material as BaseMaterial3D).texture_filter)
	elif material is ShaderMaterial:
		var shader_material: ShaderMaterial = material as ShaderMaterial
		texture = shader_material.get_shader_parameter(binding.texture_parameter) as Texture2D
		if shader_material.shader != null:
			for line: String in shader_material.shader.code.split("\n"):
				if line.contains("sampler2D " + str(binding.texture_parameter) + " "):
					sampler = "linear_mipmap_anisotropic" if line.contains("filter_linear_mipmap_anisotropic") else line.strip_edges()
	var key: String = get_source_key(source)
	var entry: Dictionary = _declared_entries.get(key, {}) as Dictionary
	var report: Dictionary = {"bound": true, "material": material.resource_name,
		"source_key": key, "runtime_key": get_runtime_source_key(source),
		"source_size": [source.get_width(), source.get_height()],
		"replaced": texture != null and texture != source, "sampler": sampler,
		"source_alpha_scale": float(binding.get("source_alpha_scale", 1.0)),
		"source_alpha_mask": bool(binding.get("source_alpha_mask", false)),
		"source_uniform_alpha": int(_source_keys.get(source.get_instance_id(), {}).get("uniform_alpha", -1)),
		"source_uniform_positive_alpha": int(_source_keys.get(source.get_instance_id(), {}).get("uniform_positive_alpha", -1)),
		"fallback_reason": str(binding.get("fallback_reason", "")),
		"replacement_path": _replacement_path(entry) if entry.has("path") else "",
		"authoring": entry.get("authoring", entry.get("generated_with", "unspecified")),
		"visual_review": entry.get("visual_review", "not_recorded")}
	if texture != null:
		report["bound_size"] = [texture.get_width(), texture.get_height()]
		if inspect_image:
			var image: Image = texture.get_image()
			report["mipmaps"] = image != null and image.has_mipmaps()
	return report


static func _valid_relative_path(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and not ".." in path.split("/") \
		and not ":" in path and not "\\" in path


static func _source_key(source: Texture2D, force: bool = false) -> String:
	# Dimensions are part of the verified pixel key. A noncandidate texture
	# never needs a GPU readback, decompression or pixel hash.
	var dimensions: String = "%dx%d" % [source.get_width(), source.get_height()]
	if not force and not _source_sizes.has(dimensions):
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
	var pixels: PackedByteArray = image.get_data()
	var uniform_alpha: int = 255
	var positive_alpha: int = 255
	if image.detect_alpha() != Image.ALPHA_NONE:
		uniform_alpha = int(pixels[3])
		positive_alpha = uniform_alpha if uniform_alpha > 0 else 0
		for offset: int in range(7, pixels.size(), 4):
			var alpha: int = int(pixels[offset])
			if alpha != uniform_alpha:
				uniform_alpha = -1
			if alpha > 0:
				if positive_alpha == 0:
					positive_alpha = alpha
				elif positive_alpha != alpha:
					positive_alpha = -1
			if uniform_alpha < 0 and positive_alpha < 0:
				break
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(pixels)
	var runtime_key: String = "%dx%d:%s" % [image.get_width(), image.get_height(), hash.finish().hex_encode()]
	var key: String = str(_runtime_aliases.get(runtime_key, runtime_key))
	_source_keys[id] = {"source": weakref(source), "key": key, "runtime_key": runtime_key,
		"uniform_alpha": uniform_alpha, "uniform_positive_alpha": positive_alpha}
	_schedule_cleanup()
	return key


static func _schedule_cleanup() -> void:
	if _cleanup_pending or (_bindings.is_empty() and _quality_shaders.is_empty() and _animation_caches.is_empty() and _source_keys.is_empty() and _replacements.is_empty()):
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
	for id: int in _animation_caches.keys():
		if (_animation_caches[id] as WeakRef).get_ref() == null:
			_animation_caches.erase(id)
	for id: int in _quality_shaders.keys():
		if (_quality_shaders[id].material as WeakRef).get_ref() == null:
			_quality_shaders.erase(id)
	for id: int in _bindings.keys():
		if (_bindings[id].material as WeakRef).get_ref() == null:
			_bindings.erase(id)
	for id: int in _source_keys.keys():
		if (_source_keys[id].source as WeakRef).get_ref() == null:
			_source_keys.erase(id)
	for path: String in _replacements.keys():
		if _cached_replacement(path) == null:
			_replacements.erase(path)
			_replacement_info.erase(path)


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(_manifest_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_manifest_path))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		_manifest_errors["manifest"] = "invalid_schema"
		return
	var textures: Variant = parsed.get("textures", {})
	if not textures is Dictionary:
		_manifest_errors["manifest"] = "invalid_textures_dictionary"
		return
	for key: String in textures:
		var entry: Variant = textures[key]
		if not entry is Dictionary:
			_manifest_errors[key] = "invalid_entry"
			continue
		_declared_entries[key] = entry.duplicate(true)
		var path: String = str(entry.get("path", ""))
		if not _valid_relative_path(path):
			_manifest_errors[key] = "invalid_replacement_path"
			continue
		_source_sizes[key.get_slice(":", 0)] = true
		if ResourceLoader.exists(_manifest_path.get_base_dir().path_join(path), "Texture2D"):
			_entries[key] = entry.duplicate(true)
		else:
			_manifest_errors[key] = "replacement_resource_missing"
	# The PNG importer can dilate RGB in fully transparent pixels. Keep this
	# verified decode identity as an alias instead of weakening the pixel hash
	# or guessing from names/dimensions. The audit tool derives these pairs.
	for key: String in _declared_entries:
		for alias: String in _declared_entries[key].get("runtime_keys", []):
			if alias == key:
				continue
			if _runtime_aliases.has(alias) and _runtime_aliases[alias] != key:
				_manifest_errors[alias] = "conflicting_runtime_alias"
				_runtime_aliases.erase(alias)
				continue
			if _manifest_errors.get(alias) == "conflicting_runtime_alias":
				continue
			_runtime_aliases[alias] = key
			_source_sizes[alias.get_slice(":", 0)] = true
