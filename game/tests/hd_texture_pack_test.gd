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
	TexturePack.set_enabled(false)
	_check(untouched.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST, "original mode preserves the authored texture filter")
	await _check_binding_lifetime()
	if not TexturePack.is_available() or not ResourceLoader.exists("res://assets/generated/levels/g006.glb"):
		_check(not bool(TexturePack.get_status().enabled), "clean checkout has no active HD replacement")
		_finish()
		return
	_check_hd_cache_release()
	var packed: PackedScene = load("res://assets/generated/levels/g006.glb") as PackedScene
	var level: Node = packed.instantiate()
	root.add_child(level)
	var originals: Array[BaseMaterial3D] = []
	_collect_materials(level, originals)
	TexturePack.set_enabled(true)
	var matched: Array[BaseMaterial3D] = []
	var seen: Dictionary = {}
	for original: BaseMaterial3D in originals:
		var texture: Texture2D = original.albedo_texture
		if texture == null:
			continue
		var enhanced: Texture2D = TexturePack.resolve(texture)
		if enhanced == texture or seen.has(enhanced.get_instance_id()):
			continue
		seen[enhanced.get_instance_id()] = true
		matched.append(original)
	_check(matched.size() == int(TexturePack.get_status().source_textures), "every installed replacement matches a real original Beach material")
	for original: BaseMaterial3D in matched:
		var texture: Texture2D = original.albedo_texture
		var material: BaseMaterial3D = Materials.prepare_material(original, true) as BaseMaterial3D
		_check(material != null and material.albedo_texture != texture, "production material uses the matched HD texture")
		if material == null:
			continue
		var enhanced: Texture2D = material.albedo_texture
		_check(enhanced.get_width() > texture.get_width() and enhanced.get_height() > texture.get_height(), "replacement contains more pixels in both axes")
		_check(enhanced.get_image().has_mipmaps(), "HD texture has a complete mip chain for distant geometry")
		_check(material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, "HD material requests mipmapped anisotropic filtering")
		_check(original.albedo_texture == texture, "shared source material remains unchanged")
		TexturePack.set_enabled(false)
		_check(material.albedo_texture == texture and material.texture_filter == original.texture_filter, "live Original switch restores this material and filter")
		TexturePack.set_enabled(true)
		_check(material.albedo_texture == enhanced, "live Enhanced switch reuses the correct cached replacement")
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


func _check_hd_cache_release() -> void:
	var packed: PackedScene = load("res://assets/generated/levels/g006.glb") as PackedScene
	var owner: Node = packed.instantiate()
	var originals: Array[BaseMaterial3D] = []
	_collect_materials(owner, originals)
	TexturePack.set_enabled(true)
	var material: BaseMaterial3D
	var source: Texture2D
	var replacement: Texture2D
	for original: BaseMaterial3D in originals:
		source = original.albedo_texture
		if source == null:
			continue
		replacement = TexturePack.resolve(source)
		if replacement != source:
			material = Materials.prepare_material(original, true) as BaseMaterial3D
			break
	_check(material != null and replacement != source, "real HD allocation exists before performance switch")
	if material != null:
		var reference: WeakRef = weakref(replacement)
		replacement = null
		TexturePack.set_enabled(false)
		_check(material.albedo_texture == source, "performance switch restores original pixels")
		_check(reference.get_ref() == null, "performance mode releases HD texture with no remaining visual owner")
		TexturePack.set_enabled(true)
		_check(material.albedo_texture != source and material.albedo_texture.get_image().has_mipmaps(), "quality mode recreates HD with mipmaps after release")
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
