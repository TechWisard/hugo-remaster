extends SceneTree
## Production materials, pixel-key matching, live toggle and mipmap regression.

const TexturePack = preload("res://scripts/hd_texture_pack.gd")
const Materials = preload("res://scripts/native_materials.gd")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var blank := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0.13, 0.27, 0.41, 1.0))
	var unknown: ImageTexture = ImageTexture.create_from_image(blank)
	TexturePack.set_enabled(true)
	_check(TexturePack.resolve(unknown) == unknown, "unmatched original texture is kept intact")
	var fixture := StandardMaterial3D.new()
	fixture.albedo_texture = unknown
	fixture.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var untouched: BaseMaterial3D = Materials.prepare_material(fixture, false) as BaseMaterial3D
	_check(untouched.albedo_texture == unknown, "unmatched real material keeps the source texture")
	_check(untouched.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC,
		"enhanced mode never silently keeps the legacy nearest sampler")
	var fallback: Dictionary = TexturePack.get_binding_report(untouched)
	_check(not fallback.replaced and not str(fallback.fallback_reason).is_empty(),
		"unmatched source is explicitly reported, never counted as a quality replacement")
	_check_shader_filters(unknown)
	TexturePack.set_enabled(false)
	_check(untouched.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST, "original mode preserves the authored texture filter")
	await _check_binding_lifetime()
	if not TexturePack.is_available() or not ResourceLoader.exists("res://assets/generated/levels/g006.glb"):
		_check(not bool(TexturePack.get_status().enabled), "clean checkout has no active HD replacement")
		_finish()
		return
	_check_hd_cache_release()
	_check_alpha_contract()
	var packed: PackedScene = load("res://assets/generated/levels/g006.glb") as PackedScene
	var level: Node = packed.instantiate()
	root.add_child(level)
	var originals: Array[BaseMaterial3D] = []
	_collect_materials(level, originals)
	TexturePack.set_enabled(true)
	var matched: Array[BaseMaterial3D] = []
	var seen: Dictionary = {}
	var entries: Dictionary = TexturePack.get_manifest_entries()
	for original: BaseMaterial3D in originals:
		var texture: Texture2D = original.albedo_texture
		if texture == null:
			continue
		var key: String = TexturePack.get_source_key(texture)
		if not entries.has(key) or seen.has(key):
			continue
		seen[key] = true
		matched.append(original)
	# A campaign pack includes other chapters and every animation frame. Beach
	# is an integration sample; complete coverage is checked by the audit tool.
	_check(not matched.is_empty(), "installed campaign pack matches real original Beach materials")
	for original: BaseMaterial3D in matched:
		var texture: Texture2D = original.albedo_texture
		var material: Material = Materials.prepare_material(original, true)
		_check(material != null and _albedo(material) != texture, "production material uses the matched HD texture")
		if material == null:
			continue
		var enhanced: Texture2D = _albedo(material)
		_check(enhanced.get_width() > texture.get_width() and enhanced.get_height() > texture.get_height(), "replacement contains more pixels in both axes")
		_check(enhanced.get_image().has_mipmaps(), "HD texture has a complete mip chain for distant geometry")
		_check(TexturePack.get_binding_report(material).sampler == "linear_mipmap_anisotropic", "actual HD sampler requests mipmapped anisotropic filtering")
		_check(original.albedo_texture == texture, "shared source material remains unchanged")
		TexturePack.set_enabled(false)
		_check(_albedo(material) == texture, "live Original switch restores this material's source")
		if material is BaseMaterial3D:
			_check((material as BaseMaterial3D).texture_filter == original.texture_filter, "Original restores the authored material filter")
		TexturePack.set_enabled(true)
		_check(_albedo(material) == enhanced, "live Enhanced switch reuses the correct cached replacement")
	if not matched.is_empty():
		_check_resolution_budget(matched[0])
		var prepared: Material = Materials.prepare_material(matched[0], true)
		var backdrop: ShaderMaterial = Materials.prepare_background_material(matched[0], prepared)
		_check(TexturePack.get_bound_source(backdrop) == matched[0].albedo_texture,
			"background rebinding retains the source frame, not the previous HD texture")
		_check(TexturePack.get_binding_report(backdrop).replaced,
			"camera-centred background is covered by the production replacement adapter")
		TexturePack.set_enabled(false)
		_check(backdrop.get_shader_parameter("source_texture") == matched[0].albedo_texture,
			"background Original mode restores its source frame")
		TexturePack.set_enabled(true)
		_check(TexturePack.get_binding_report(backdrop).sampler == "linear_mipmap_anisotropic",
			"background Enhanced mode restores its mipmapped sampler")
	if matched.size() >= 2:
		var animated := StandardMaterial3D.new()
		animated.resource_name = "synthetic_frame_selector__hugo_blend_0"
		animated.albedo_texture = matched[0].albedo_texture
		var shader: ShaderMaterial = Materials.prepare_material(animated, true) as ShaderMaterial
		var next_frame: Texture2D = matched[1].albedo_texture
		TexturePack.bind_material(shader, next_frame)
		_check(shader.get_shader_parameter("albedo_texture") == TexturePack.resolve(next_frame), "animated-frame rebinding selects that frame's HD replacement")
		TexturePack.set_enabled(false)
		_check(shader.get_shader_parameter("albedo_texture") == next_frame, "Original toggle restores the current animated frame, not its initial frame")
		TexturePack.set_enabled(true)
		_check(shader.get_shader_parameter("albedo_texture") == TexturePack.resolve(next_frame), "Enhanced toggle restores the current animated frame")
	level.free()
	TexturePack.set_enabled(false)
	_check(int(TexturePack.get_status().active_materials) == 0, "turning the pack off clears all active material replacements")
	_finish()


func _albedo(material: Material) -> Texture2D:
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).albedo_texture
	return (material as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D


func _check_shader_filters(source: Texture2D) -> void:
	for selector: int in range(3):
		TexturePack.set_enabled(true)
		var original := StandardMaterial3D.new()
		original.resource_name = "sampler_fixture__hugo_blend_%d" % selector
		original.albedo_texture = source
		original.albedo_color = Color(0.7, 0.6, 0.4, 0.5)
		original.texture_repeat = false
		var material: ShaderMaterial = Materials.prepare_material(original, true) as ShaderMaterial
		_check(TexturePack.get_binding_report(material).sampler == "linear_mipmap_anisotropic",
			"custom blend%d has the enhanced sampler" % selector)
		_check(material.shader.code.contains("repeat_disable"), "custom blend preserves source clamp wrapping")
		TexturePack.set_enabled(false)
		_check(material.shader.code.contains("filter_nearest,"), "custom blend Original mode uses point sampling")
		TexturePack.set_enabled(true)
		_check(material.get_shader_parameter("base_color") == original.albedo_color,
			"shader variant switch preserves the native material tint")
		_check(material.get_shader_parameter("albedo_texture") == source,
			"sampler switch preserves the current unmatched frame")


func _check_resolution_budget(original: BaseMaterial3D) -> void:
	var material: Material = Materials.prepare_material(original, true)
	var full: Vector2i = Vector2i(_albedo(material).get_width(), _albedo(material).get_height())
	_set_limit(512)
	var limited: Texture2D = _albedo(material)
	_check(limited != original.albedo_texture and maxi(limited.get_width(), limited.get_height()) <= 512,
		"memory tier uses the authored replacement within its requested dimension limit")
	_check(limited.get_image().has_mipmaps(), "memory tier retains the mipmap chain")
	_check(TexturePack.get_binding_report(material).sampler == "linear_mipmap_anisotropic",
		"memory tier retains the anisotropic sampler")
	var shared: Material = Materials.prepare_material(original, true)
	_check(_albedo(shared) == limited, "two materials share the same authored texture memory tier")
	var reference: WeakRef = weakref(limited)
	limited = null
	_set_limit(0)
	_check(Vector2i(_albedo(material).get_width(), _albedo(material).get_height()) == full,
		"maximum quality restores the original authored replacement resolution")
	_check(reference.get_ref() == null, "switching memory tiers releases the unused lower-resolution allocation")


func _check_alpha_contract() -> void:
	# Point an in-memory synthetic identity at one installed opaque replacement.
	# No source file or manifest is modified by this regression fixture.
	var entry: Dictionary = {}
	for candidate: Dictionary in TexturePack.get_manifest_entries().values():
		var path: String = TexturePack.MANIFEST.get_base_dir().path_join(str(candidate.path))
		var texture: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
		if texture != null and texture.get_image().detect_alpha() == Image.ALPHA_NONE:
			entry = candidate.duplicate(true)
			break
	if entry.is_empty():
		return
	var pixels := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	pixels.fill(Color(0.1, 0.3, 0.6, 128.0 / 255.0))
	var source: ImageTexture = ImageTexture.create_from_image(pixels)
	var key: String = TexturePack.get_source_key(source)
	var previous_size: bool = TexturePack._source_sizes.has("4x4")
	TexturePack._entries[key] = entry
	TexturePack._source_sizes["4x4"] = true
	TexturePack.set_enabled(true)
	var original := StandardMaterial3D.new()
	original.albedo_texture = source
	original.albedo_color.a = 0.75
	var standard: BaseMaterial3D = Materials.prepare_material(original, false) as BaseMaterial3D
	_check(absf(standard.albedo_color.a - 0.75 * 128.0 / 255.0) < 0.00001,
		"opaque replacement preserves a source texture's uniform half-alpha in standard materials")
	original.resource_name = "alpha_contract__hugo_blend_0"
	var shader: ShaderMaterial = Materials.prepare_material(original, false) as ShaderMaterial
	_check(absf(float(shader.get_shader_parameter("source_alpha_scale")) - 128.0 / 255.0) < 0.00001,
		"custom blends preserve the same uniform source alpha")
	TexturePack.set_enabled(false)
	_check(is_equal_approx(standard.albedo_color.a, 0.75) and is_equal_approx(float(shader.get_shader_parameter("source_alpha_scale")), 1.0),
		"Original mode restores tint and does not apply source alpha twice")
	TexturePack._entries.erase(key)
	pixels.set_pixel(0, 0, Color(0.1, 0.3, 0.6, 1.0))
	var mixed: ImageTexture = ImageTexture.create_from_image(pixels)
	var mixed_key: String = TexturePack.get_source_key(mixed)
	entry["alpha_policy"] = "source_mask"
	TexturePack._entries[mixed_key] = entry
	original.albedo_texture = mixed
	TexturePack.set_enabled(true)
	var masked: ShaderMaterial = Materials.prepare_material(original, false) as ShaderMaterial
	_check(bool(masked.get_shader_parameter("use_source_alpha")) and masked.get_shader_parameter("source_alpha_texture") == mixed,
		"mixed alpha policy binds only the source's functional alpha mask")
	_check(masked.get_shader_parameter("albedo_texture") != mixed and is_equal_approx(float(masked.get_shader_parameter("source_alpha_scale")), 1.0),
		"functional alpha policy keeps the new color art and avoids double alpha multiplication")
	TexturePack.set_enabled(false)
	_check(not bool(masked.get_shader_parameter("use_source_alpha")), "Original mode disables the auxiliary alpha-mask sample")
	TexturePack._entries.erase(mixed_key)
	if not previous_size:
		TexturePack._source_sizes.erase("4x4")
	TexturePack.set_enabled(true)


func _set_limit(value: int) -> void:
	TexturePack.set_max_texture_dimension(value)
	_check(int(TexturePack.get_status().max_texture_dimension) == value, "reported memory tier matches the selected cap")


func _check_hd_cache_release() -> void:
	var packed: PackedScene = load("res://assets/generated/levels/g006.glb") as PackedScene
	var owner: Node = packed.instantiate()
	var originals: Array[BaseMaterial3D] = []
	_collect_materials(owner, originals)
	TexturePack.set_enabled(true)
	var material: Material
	var source: Texture2D
	var replacement: Texture2D
	for original: BaseMaterial3D in originals:
		source = original.albedo_texture
		if source == null:
			continue
		replacement = TexturePack.resolve(source)
		if replacement != source:
			material = Materials.prepare_material(original, true)
			break
	_check(material != null and replacement != source, "real HD allocation exists before performance switch")
	if material != null:
		var reference: WeakRef = weakref(replacement)
		replacement = null
		TexturePack.set_enabled(false)
		_check(_albedo(material) == source, "performance switch restores original pixels")
		_check(reference.get_ref() == null, "performance mode releases HD texture with no remaining visual owner")
		TexturePack.set_enabled(true)
		_check(_albedo(material) != source and _albedo(material).get_image().has_mipmaps(), "quality mode recreates HD with mipmaps after release")
		var unloaded: WeakRef = weakref(_albedo(material))
		material = null
		_check(TexturePack.is_enabled() and unloaded.get_ref() == null,
			"scene material unload releases unused HD while Enhanced remains enabled")
	owner.free()


func _temporary_binding() -> Dictionary:
	var source := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var material := StandardMaterial3D.new()
	TexturePack.bind_material(material, source)
	return {"material": weakref(material), "source": weakref(source)}


func _check_binding_lifetime() -> void:
	var released: Array[Dictionary] = []
	for index: int in range(25):
		released.append(_temporary_binding())
	var live_source := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var live_material := StandardMaterial3D.new()
	TexturePack.bind_material(live_material, live_source)
	var live_reference: WeakRef = weakref(live_source)
	live_source = null
	# Do not touch the quality switch: actual scene unloading must reclaim the
	# original textures by itself, including while a pause menu is open.
	paused = true
	await create_timer(2.2, true, false, true).timeout
	paused = false
	var dead_materials: int = 0
	var dead_sources: int = 0
	for item: Dictionary in released:
		dead_materials += int((item.material as WeakRef).get_ref() == null)
		dead_sources += int((item.source as WeakRef).get_ref() == null)
	_check(dead_materials == 25, "texture bindings never own the material")
	_check(dead_sources == 25, "unloaded materials release all retained originals without a quality toggle")
	_check(live_reference.get_ref() != null and live_material.albedo_texture == live_reference.get_ref(), "cleanup preserves a live material and its current original texture")


func _collect_materials(node: Node, output: Array[BaseMaterial3D]) -> void:
	var mesh: MeshInstance3D = node as MeshInstance3D
	if mesh != null and mesh.mesh != null:
		for index: int in range(mesh.mesh.get_surface_count()):
			var material: BaseMaterial3D = mesh.get_active_material(index) as BaseMaterial3D
			if material != null:
				output.append(material)
	for child: Node in node.get_children():
		_collect_materials(child, output)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)


func _finish() -> void:
	print("HD_TEXTURE_PACK checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)
