class_name HugoNativeMaterials
extends RefCounted
## Ordinary mesh blend selectors are different from CPSXSprite's mode enum.
## The exporter keeps the selector in the material name because glTF material
## extras are not reliably exposed by the Godot importer.

const BLEND_TOKEN: String = "__hugo_blend_"
const ANIMATION_TOKEN: String = "__hugo_anim_"
const ALPHA_CUTOFF: float = 8.0 / 255.0
const DEFAULT_MANIFEST: String = "res://assets/generated/material_animation_manifest.json"
const BINDING_META: StringName = &"hugo_material_animation"
static var _shaders: Dictionary = {}
static var _animation_data: Dictionary = {}
static var _animation_base: String = ""
static var _manifest_attempted: bool = false
static var _textures: Dictionary = {}


static func blend_selector(material: Material) -> int:
	if material == null:
		return -1
	var name: String = material.resource_name
	var offset: int = name.rfind(BLEND_TOKEN)
	if offset < 0:
		return -1
	var suffix: String = name.substr(offset + BLEND_TOKEN.length())
	if suffix.length() != 1 or not suffix.is_valid_int():
		return -1
	var value: int = int(suffix)
	return value if value >= 0 and value <= 3 else -1


static func prepare_material(source: BaseMaterial3D, has_vertex_colors: bool) -> Material:
	var selector: int = blend_selector(source)
	if selector < 0 or selector == 3:
		# Godot 4.7 can omit COLOR_0 on the first imported surface. Change only
		# a private material copy; old imports without a selector remain usable.
		var material: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		if has_vertex_colors:
			material.vertex_color_use_as_albedo = true
		return material
	var material := ShaderMaterial.new()
	material.resource_name = source.resource_name
	material.render_priority = source.render_priority
	material.shader = _shader(selector)
	material.set_shader_parameter("base_color", source.albedo_color)
	material.set_shader_parameter("has_texture", source.albedo_texture != null)
	material.set_shader_parameter("use_vertex_color", has_vertex_colors)
	material.set_shader_parameter("uv_scale", Vector2(source.uv1_scale.x, source.uv1_scale.y))
	material.set_shader_parameter("uv_offset", Vector2(source.uv1_offset.x, source.uv1_offset.y))
	if source.albedo_texture != null:
		material.set_shader_parameter("albedo_texture", source.albedo_texture)
	return material


static func apply_recursive(node: Node) -> void:
	var instance: MeshInstance3D = node as MeshInstance3D
	if instance != null and instance.mesh != null:
		for surface: int in range(instance.mesh.get_surface_count()):
			var original: BaseMaterial3D = instance.get_active_material(surface) as BaseMaterial3D
			if original == null:
				continue
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			var has_colors: bool = false
			if arrays[Mesh.ARRAY_COLOR] is PackedColorArray:
				var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				has_colors = not colors.is_empty()
			instance.set_surface_override_material(surface, prepare_material(original, has_colors))
		prepare_animation_instance(instance)
	for child: Node in node.get_children():
		apply_recursive(child)


static func load_animation_manifest(path: String = DEFAULT_MANIFEST) -> bool:
	## Source texture sequences and byte RGB/UV samples share visual phase,
	## not an invented frame rate. An explicit path also supports isolated QA.
	_manifest_attempted = true
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not (parsed as Dictionary).get("materials") is Dictionary:
		return false
	_animation_data = (parsed as Dictionary)["materials"] as Dictionary
	_animation_base = path.get_base_dir()
	_textures.clear()
	return true


static func animation_key(material: Material) -> String:
	if material == null:
		return ""
	var material_name: String = material.resource_name
	var start: int = material_name.find(ANIMATION_TOKEN)
	var end: int = material_name.rfind(BLEND_TOKEN)
	if start < 0 or end <= start:
		return ""
	return material_name.substr(start + ANIMATION_TOKEN.length(), end - start - ANIMATION_TOKEN.length())


static func prepare_animation_instance(instance: MeshInstance3D) -> void:
	if instance.mesh == null or instance.has_meta(BINDING_META):
		return
	if not _manifest_attempted:
		load_animation_manifest()
	var bindings: Array[Dictionary] = []
	var mutable_attributes: bool = false
	for surface: int in range(instance.mesh.get_surface_count()):
		var material: Material = instance.get_active_material(surface)
		var key: String = animation_key(material)
		if not _animation_data.has(key):
			continue
		var info: Dictionary = _animation_data[key] as Dictionary
		var mutate: bool = bool(info.get("source_color_animation", false)) or bool(info.get("animate_uv", false))
		var ids := PackedInt32Array()
		if mutate:
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			var vertex_count: int = instance.mesh.surface_get_array_len(surface)
			var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array else PackedVector2Array()
			if uv2.size() != vertex_count:
				push_error("Native material has no source vertex IDs: " + key)
				continue
			ids.resize(vertex_count)
			var valid: bool = true
			for vertex: int in range(vertex_count):
				var source_id: int = roundi(uv2[vertex].x)
				if source_id < 0 or source_id >= int(info.vertex_count) or roundi(uv2[vertex].y) != int(info.part_index):
					valid = false
					break
				ids[vertex] = source_id
			if not valid:
				push_error("Native material vertex IDs are out of range: " + key)
				continue
			mutable_attributes = true
		bindings.append({"surface": surface, "key": key, "info": info,
			"material": material, "ids": ids, "mutable": mutate, "texture_index": -1,
			"last_phase": -1.0})
	if bindings.is_empty():
		return
	if mutable_attributes:
		# Imported arrays may be reordered or compressed. Keep UV2 source IDs,
		# every primitive and every morph target, but make private uncompressed
		# attribute buffers. Neither the shared imported mesh nor its poses change.
		var source_mesh: Mesh = instance.mesh
		var mesh := ArrayMesh.new()
		mesh.resource_name = source_mesh.resource_name + "_native_attributes"
		mesh.blend_shape_mode = source_mesh.blend_shape_mode
		for shape: int in range(source_mesh.get_blend_shape_count()):
			mesh.add_blend_shape(source_mesh.get_blend_shape_name(shape))
		for surface: int in range(source_mesh.get_surface_count()):
			mesh.add_surface_from_arrays(source_mesh.surface_get_primitive_type(surface),
				source_mesh.surface_get_arrays(surface), source_mesh.surface_get_blend_shape_arrays(surface),
				{}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
			mesh.surface_set_material(surface, source_mesh.surface_get_material(surface))
		instance.mesh = mesh
		for binding: Dictionary in bindings:
			if not bool(binding.mutable):
				continue
			var surface: int = int(binding.surface)
			var vertex_count: int = mesh.surface_get_array_len(surface)
			var format: int = mesh.surface_get_format(surface)
			var storage: Dictionary = RenderingServer.mesh_get_surface(mesh.get_rid(), surface)
			binding["attributes"] = storage.get("attribute_data", PackedByteArray())
			binding["stride"] = RenderingServer.mesh_surface_get_format_attribute_stride(format, vertex_count)
			binding["color_offset"] = RenderingServer.mesh_surface_get_format_offset(format, vertex_count, Mesh.ARRAY_COLOR)
			binding["uv_offset"] = RenderingServer.mesh_surface_get_format_offset(format, vertex_count, Mesh.ARRAY_TEX_UV)
	instance.set_meta(BINDING_META, bindings)
	apply_phase(instance, 0.0)


static func apply_phase(instance: MeshInstance3D, phase: float) -> void:
	if not instance.has_meta(BINDING_META) or not is_finite(phase):
		return
	var bindings: Array = instance.get_meta(BINDING_META) as Array
	var normalized: float = _float32(clampf(phase, 0.0, 1.0))
	for binding: Dictionary in bindings:
		if float(binding.last_phase) == normalized:
			continue
		binding["last_phase"] = normalized
		var info: Dictionary = binding.info as Dictionary
		var sample: Dictionary = _sample_indices(info, normalized)
		var texture_index: int = int(sample.texture_frame_index)
		if bool(info.get("animate_texture", false)) and texture_index != int(binding.texture_index):
			var sequence: Array = info.get("texture_sequence", []) as Array
			if texture_index >= 0 and texture_index < sequence.size():
				var frame: Dictionary = sequence[texture_index] as Dictionary
				var texture: Texture2D = _texture(str(frame.get("path", "")))
				if texture != null:
					var material: Material = binding.material as Material
					if material is ShaderMaterial:
						(material as ShaderMaterial).set_shader_parameter("albedo_texture", texture)
						(material as ShaderMaterial).set_shader_parameter("has_texture", true)
					elif material is BaseMaterial3D:
						(material as BaseMaterial3D).albedo_texture = texture
					binding["texture_index"] = texture_index
		if not bool(binding.mutable):
			continue
		var mesh: ArrayMesh = instance.mesh as ArrayMesh
		var ids: PackedInt32Array = binding.ids
		var buffer: PackedByteArray = binding.attributes
		var stride: int = int(binding.stride)
		var animate_color: bool = bool(info.get("source_color_animation", false))
		var animate_uv: bool = bool(info.get("animate_uv", false))
		for vertex: int in range(ids.size()):
			var source_id: int = ids[vertex]
			var base: int = vertex * stride
			if animate_color:
				var color: Vector3i = _sample_rgb(info, sample, source_id)
				var offset: int = base + int(binding.color_offset)
				buffer[offset] = color.x
				buffer[offset + 1] = color.y
				buffer[offset + 2] = color.z
				buffer[offset + 3] = roundi(float(info.get("vertex_alpha", 1.0)) * 255.0)
			if animate_uv:
				var uv: Vector2 = _sample_uv(info, sample, source_id)
				var offset: int = base + int(binding.uv_offset)
				buffer.encode_float(offset, uv.x)
				buffer.encode_float(offset + 4, uv.y)
		binding["attributes"] = buffer
		mesh.surface_update_attribute_region(int(binding.surface), 0, buffer)


static func sample_material(info: Dictionary, phase: float) -> Dictionary:
	## Pure reference-visible sample; the runtime writes the same byte values
	## directly into a private attribute buffer in imported vertex order.
	var state: Dictionary = _sample_indices(info, _float32(clampf(phase, 0.0, 1.0)))
	var rgb: Array = []
	var rgba: Array = []
	var uv: Array = []
	var has_uv: bool = not (info.get("uv_samples", []) as Array).is_empty()
	for index: int in range(int(info.get("vertex_count", 0))):
		var color: Vector3i = _sample_rgb(info, state, index)
		rgb.append([color.x, color.y, color.z])
		var normalized := Color(float(color.x) / 255.0, float(color.y) / 255.0,
			float(color.z) / 255.0, float(info.get("vertex_alpha", 1.0)))
		rgba.append([normalized.r, normalized.g, normalized.b, normalized.a])
		if has_uv:
			var value: Vector2 = _sample_uv(info, state, index)
			uv.append([value.x, value.y])
	state["rgb_bytes"] = rgb
	state["rgba"] = rgba
	state["uv"] = uv
	if int(state.texture_frame_index) < 0:
		state["texture_frame_index"] = null
	return state


static func _sample_indices(info: Dictionary, phase: float) -> Dictionary:
	var words: Array = info.get("timeline_words", [0]) as Array
	var stored: int = int(info.get("stored_samples", 1))
	var loop: bool = bool(info.get("timeline_loop", false))
	var timeline_phase: float = fposmod(phase, 1.0) if loop else phase
	var coordinate: float = timeline_phase * float(words.size() if loop else words.size() - 1)
	var first: int = mini(int(coordinate), words.size() - 1)
	var second: int = (first + 1) % words.size() if loop else mini(first + 1, words.size() - 1)
	var word_a: int = int(words[first])
	var word_b: int = int(words[second])
	var sample_a: int = word_a >> 16
	var fraction: float = float(word_a & 4095) / 4096.0
	var difference: float = float(word_b >> 16) + float(word_b & 4095) / 4096.0 - float(sample_a) - fraction
	if difference < 0.0:
		difference += float(stored)
	var weight: float = _float32(fraction + (coordinate - floorf(coordinate)) * difference)
	var sequence: Array = info.get("texture_sequence", []) as Array
	# Keep the product in float64/x87 precision until truncation. Phase itself
	# was stored float32 by the native caller. The endpoint selects frame zero.
	var texture_index: int = int(phase * float(sequence.size())) % sequence.size() if not sequence.is_empty() else -1
	return {"sample_a": sample_a, "sample_b": (sample_a + 1) % stored,
		"sample_weight": weight, "texture_frame_index": texture_index}


static func _sample_rgb(info: Dictionary, state: Dictionary, index: int) -> Vector3i:
	var colors: Array = info.get("color_samples", []) as Array
	if not bool(info.get("source_color_animation", false)):
		var color: Array = colors[0][index] as Array
		return Vector3i(int(color[0]), int(color[1]), int(color[2]))
	var first: Array = colors[int(state.sample_a)][index] as Array
	var second: Array = colors[int(state.sample_b)][index] as Array
	var weight: float = float(state.sample_weight)
	var inverse: float = 1.0 - weight
	# Native R stays on the x87 stack; G/B are float32 temporaries before
	# truncation (0x413121/0x413165). This distinction can change a byte by one.
	var red: int = int(float(first[0]) * inverse + float(second[0]) * weight)
	var gb := Color(0.0, float(first[1]) * inverse + float(second[1]) * weight,
		float(first[2]) * inverse + float(second[2]) * weight, 1.0)
	return Vector3i(red, int(gb.g), int(gb.b))


static func _sample_uv(info: Dictionary, state: Dictionary, index: int) -> Vector2:
	var samples: Array = info.get("uv_samples", []) as Array
	var first: Array = samples[int(state.sample_a) if samples.size() > 1 else 0][index] as Array
	var second: Array = samples[int(state.sample_b) if samples.size() > 1 else 0][index] as Array
	var weight: float = float(state.sample_weight) if samples.size() > 1 else 0.0
	var inverse: float = 1.0 - weight
	var divisor: float = _float32(1.0 / 255.0)
	return Vector2((float(first[0]) * inverse + float(second[0]) * weight) * divisor,
		(float(first[1]) * inverse + float(second[1]) * weight) * divisor)


static func _float32(value: float) -> float:
	return Color(value, 0.0, 0.0, 0.0).r


static func _texture(relative: String) -> Texture2D:
	if relative.is_empty() or relative.is_absolute_path() or relative.contains(".."):
		return null
	var path: String = _animation_base.path_join(relative)
	if _textures.has(path):
		return _textures[path] as Texture2D
	var texture: Texture2D
	if path.begins_with("res://") and ResourceLoader.exists(path, "Texture2D"):
		texture = ResourceLoader.load(path, "Texture2D") as Texture2D
	elif FileAccess.file_exists(path):
		# Isolated source fixtures need no editor import and never modify .godot.
		var image := Image.new()
		if image.load(path) == OK:
			texture = ImageTexture.create_from_image(image)
	if texture != null:
		_textures[path] = texture
	return texture


static func _shader(selector: int) -> Shader:
	if _shaders.has(selector):
		return _shaders[selector] as Shader
	var blend: String = "blend_mix" if selector == 0 else ("blend_add" if selector == 1 else "blend_mul")
	var rgb: String = "vec3(1.0) - source.rgb" if selector == 2 else "source.rgb"
	var alpha: String = "source.a" if selector == 0 else "1.0"
	var shader := Shader.new()
	# 0x41090A disables Z writes for the sorted transparent queue.
	# 0x410919..0x410991 select alpha/add/inverse multiplication; the global
	# alpha test is >=8/255 (0x40F385), independently of the blend factors.
	shader.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_draw_never, " + blend + ";\n" + \
		"uniform sampler2D albedo_texture : source_color, filter_nearest, repeat_enable;\n" + \
		"uniform vec4 base_color : source_color = vec4(1.0);\n" + \
		"uniform bool has_texture = false;\nuniform bool use_vertex_color = true;\n" + \
		"uniform vec2 uv_scale = vec2(1.0);\nuniform vec2 uv_offset = vec2(0.0);\n" + \
		"void fragment() {\n" + \
		"vec4 source = base_color * (has_texture ? texture(albedo_texture, UV * uv_scale + uv_offset) : vec4(1.0));\n" + \
		"if (use_vertex_color) { source *= COLOR; }\n" + \
		"if (source.a < (8.0 / 255.0)) { discard; }\n" + \
		"source.rgb = clamp(source.rgb, vec3(0.0), vec3(1.0));\n" + \
		"ALBEDO = " + rgb + "; ALPHA = " + alpha + ";\n}"
	_shaders[selector] = shader
	return shader
