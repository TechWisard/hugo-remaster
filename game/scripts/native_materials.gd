class_name HugoNativeMaterials
extends RefCounted
const TexturePackScript = preload("res://scripts/hd_texture_pack.gd")
const ResourceDataScript = preload("res://scripts/native_resource_data.gd")
const BackgroundShader = preload("res://scripts/native_background.gdshader")
const GeometryQualityScript = preload("res://scripts/native_geometry_quality.gd")
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
static var _texture_load_counts: Dictionary = {}
static var _manifest_revision: int = 0
static var _background_original_shader: Shader
static var _profile_animation: bool = false
static var _animation_profile: Dictionary = {}


static func reset_animation_profile(enabled: bool = true) -> void:
	_profile_animation = enabled
	_animation_profile = {"calls":0,"cpu_usec":0,"mutable_updates":0,
		"native_vertices_sampled":0,"vertices_rewritten":0,"color_vertices":0,"uv_vertices":0,
		"attribute_bytes_uploaded":0}


static func stop_animation_profile() -> Dictionary:
	_profile_animation = false
	return _animation_profile.duplicate()


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
	if selector < 0:
		# Godot 4.7 can omit COLOR_0 on the first imported surface. Change only
		# a private material copy; old imports without a selector remain usable.
		var material: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		if has_vertex_colors:
			material.vertex_color_use_as_albedo = true
		TexturePackScript.bind_material(material, source.albedo_texture)
		return material
	var material := ShaderMaterial.new()
	material.resource_name = source.resource_name
	material.render_priority = source.render_priority
	material.shader = _shader(selector, TexturePackScript.is_enabled(), source.texture_repeat)
	material.set_shader_parameter("base_color", source.albedo_color)
	material.set_shader_parameter("has_texture", source.albedo_texture != null)
	material.set_shader_parameter("use_vertex_color", has_vertex_colors)
	material.set_shader_parameter("uv_scale", Vector2(source.uv1_scale.x, source.uv1_scale.y))
	material.set_shader_parameter("uv_offset", Vector2(source.uv1_offset.x, source.uv1_offset.y))
	if source.albedo_texture != null:
		material.set_shader_parameter("albedo_texture", source.albedo_texture)
		TexturePackScript.bind_material(material, source.albedo_texture, &"albedo_texture",
			_shader(selector, true, source.texture_repeat), _shader(selector, false, source.texture_repeat))
	else:
		TexturePackScript.bind_quality_shader(material, _shader(selector, true, source.texture_repeat),
			_shader(selector, false, source.texture_repeat))
	return material


static func prepare_background_material(source: BaseMaterial3D, previous: Material = null) -> ShaderMaterial:
	# Backgrounds are prepared after ordinary materials. Recover the original
	# current frame instead of accidentally registering its already-HD texture
	# as a new source and losing the live Original/Enhanced toggle.
	var texture: Texture2D = TexturePackScript.get_bound_source(previous)
	if texture == null:
		texture = source.albedo_texture
	if _background_original_shader == null:
		_background_original_shader = Shader.new()
		_background_original_shader.code = BackgroundShader.code.replace("filter_linear_mipmap_anisotropic", "filter_nearest")
	var material := ShaderMaterial.new()
	material.resource_name = source.resource_name
	material.render_priority = source.render_priority
	material.shader = BackgroundShader if TexturePackScript.is_enabled() else _background_original_shader
	material.set_shader_parameter("background_tint", source.albedo_color)
	material.set_shader_parameter("has_texture", texture != null)
	if texture != null:
		TexturePackScript.bind_material(material, texture, &"source_texture", BackgroundShader, _background_original_shader)
	return material


static func prepare_boundary_material(instance: MeshInstance3D, entry: Dictionary) -> Material:
	# A new bank can borrow the cliff material from another native mesh in the
	# same already-loaded scene. Resolve its original resource directly; do not
	# instantiate another level or keep a global strong material/texture cache.
	var scene: Node = instance
	while scene.get_parent() != null and scene.scene_file_path.is_empty():
		scene = scene.get_parent()
	var name: String = str(entry.get("material_source_mesh_name", ""))
	var surface: int = int(entry.get("material_source_surface_index", -1))
	for candidate: Node in scene.find_children("*", "MeshInstance3D", true, false):
		var source_mesh: Mesh = GeometryQualityScript.get_original_mesh(candidate as MeshInstance3D)
		if source_mesh == null or name.is_empty() or (source_mesh.resource_name != name \
			and not source_mesh.resource_name.ends_with("_" + name)):
			continue
		if surface < 0 or surface >= source_mesh.get_surface_count():
			return null
		var source: BaseMaterial3D = source_mesh.surface_get_material(surface) as BaseMaterial3D
		if source == null or source.albedo_texture == null:
			return null
		var expected: String = str(entry.get("material_source_texture_key", ""))
		if not expected.is_empty() and TexturePackScript.get_source_key(source.albedo_texture) != expected:
			return null
		var private_source: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		private_source.texture_repeat = bool(entry.get("texture_repeat", false))
		# Only this new surface has physical, continuous UVs. Its native neighbour
		# keeps the authored clamp sampler and its unchanged original UV mapping.
		return prepare_material(private_source, true)
	return null


static func rebind_animation_material(instance: MeshInstance3D, surface: int, material: Material) -> void:
	# A camera-centred background can replace an already prepared shader while
	# retaining the texture/color/UV sequence's native phase and frame indices.
	if not instance.has_meta(BINDING_META):
		return
	for binding: Dictionary in instance.get_meta(BINDING_META):
		if int(binding.surface) == surface:
			binding.material = material


static func apply_recursive(node: Node, scene_path: String = "") -> void:
	if bool(node.get_meta(GeometryQualityScript.CLOSURE_META, false)):
		# This permanent repair shares an already prepared native material. It is
		# not a second imported mesh or a new source texture identity.
		return
	if not node.scene_file_path.is_empty():
		scene_path = node.scene_file_path
	var instance: MeshInstance3D = node as MeshInstance3D
	if instance != null and instance.mesh != null:
		for surface: int in range(instance.mesh.get_surface_count()):
			var original: BaseMaterial3D = instance.get_active_material(surface) as BaseMaterial3D
			if original == null:
				continue
			# The format already records COLOR_0. Reading every vertex/UV/morph
			# array here needlessly copies mesh data during every scene load.
			var has_colors: bool = surface_has_vertex_colors(instance.mesh, surface)
			instance.set_surface_override_material(surface, prepare_material(original, has_colors))
		GeometryQualityScript.apply_instance(instance, _geometry_changed, scene_path, prepare_boundary_material)
		prepare_animation_instance(instance)
	for child: Node in node.get_children():
		apply_recursive(child, scene_path)


static func _geometry_changed(instance: MeshInstance3D, phase: float) -> void:
	if instance.has_meta(BINDING_META):
		instance.remove_meta(BINDING_META)
	prepare_animation_instance(instance, phase)


static func surface_has_vertex_colors(mesh: Mesh, surface: int) -> bool:
	if mesh is ArrayMesh:
		return ((mesh as ArrayMesh).surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR) != 0
	# PrimitiveMesh exposes arrays but not ArrayMesh.surface_get_format.
	var arrays: Array = mesh.surface_get_arrays(surface)
	return arrays[Mesh.ARRAY_COLOR] is PackedColorArray and not arrays[Mesh.ARRAY_COLOR].is_empty()


static func load_animation_manifest(path: String = DEFAULT_MANIFEST) -> bool:
	## Source texture sequences and byte RGB/UV samples share visual phase,
	## not an invented frame rate. An explicit path also supports isolated QA.
	_manifest_attempted = true
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = ResourceDataScript.read(path)
	if not parsed is Dictionary or not (parsed as Dictionary).get("materials") is Dictionary:
		return false
	_animation_data = (parsed as Dictionary)["materials"] as Dictionary
	_animation_base = path.get_base_dir()
	_textures.clear()
	_manifest_revision += 1
	TexturePackScript.invalidate_animation_frames()
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


static func prepare_animation_instance(instance: MeshInstance3D, initial_phase: float = 0.0) -> void:
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
		var provenance: Dictionary = {}
		if mutate:
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			var vertex_count: int = instance.mesh.surface_get_array_len(surface)
			var valid: bool = true
			var weights: Array = instance.mesh.get_meta(GeometryQualityScript.WEIGHTS_META, [])
			ids.resize(vertex_count)
			if surface < weights.size():
				provenance = weights[surface]
				var source_ids: PackedInt32Array = provenance.get("ids", PackedInt32Array())
				var barycentric: PackedVector3Array = provenance.get("weights", PackedVector3Array())
				valid = source_ids.size() == vertex_count * 3 and barycentric.size() == vertex_count \
					and int(provenance.get("part_index", -1)) == int(info.part_index)
				if valid:
					for vertex: int in range(vertex_count):
						var weight: Vector3 = barycentric[vertex]
						if not weight.is_finite() \
							or minf(weight.x, minf(weight.y, weight.z)) < -0.00001 \
							or absf(weight.x + weight.y + weight.z - 1.0) > 0.0001:
							valid = false
							break
						for corner: int in range(3):
							var source_id: int = source_ids[vertex * 3 + corner]
							if source_id < 0 or source_id >= int(info.vertex_count):
								valid = false
								break
						ids[vertex] = source_ids[vertex * 3]
			else:
				var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array else PackedVector2Array()
				valid = uv2.size() == vertex_count
				if valid:
					for vertex: int in range(vertex_count):
						var source_id: int = roundi(uv2[vertex].x)
						if source_id < 0 or source_id >= int(info.vertex_count) or roundi(uv2[vertex].y) != int(info.part_index):
							valid = false
							break
						ids[vertex] = source_id
			if not valid:
				push_error("Native material source vertex IDs/weights are invalid: " + key)
				continue
			mutable_attributes = true
		bindings.append({"surface": surface, "key": key, "info": info,
			"material": material, "ids": ids, "mutable": mutate, "texture_index": -1,
			"source_weights": provenance, "last_phase": -1.0,
			"manifest_revision": _manifest_revision,
			"frame_cache": TexturePackScript.create_animation_cache() if bool(info.get("animate_texture",false)) else null})
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
		if source_mesh is ArrayMesh:
			mesh.custom_aabb = (source_mesh as ArrayMesh).custom_aabb
		for metadata: StringName in source_mesh.get_meta_list():
			if str(metadata).begins_with("hugo_geometry_") or str(metadata).begins_with("hugo_collision_"):
				mesh.set_meta(metadata, source_mesh.get_meta(metadata))
		var source_lods: Array = source_mesh.get_meta(GeometryQualityScript.LODS_META, [])
		for shape: int in range(source_mesh.get_blend_shape_count()):
			mesh.add_blend_shape(source_mesh.get_blend_shape_name(shape))
		for surface: int in range(source_mesh.get_surface_count()):
			mesh.add_surface_from_arrays(source_mesh.surface_get_primitive_type(surface),
				source_mesh.surface_get_arrays(surface), source_mesh.surface_get_blend_shape_arrays(surface),
				source_lods[surface] if surface < source_lods.size() else {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
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
	apply_phase(instance, initial_phase)


static func apply_phase(instance: MeshInstance3D, phase: float) -> void:
	if not instance.has_meta(BINDING_META) or not is_finite(phase):
		return
	var profile_start: int = Time.get_ticks_usec() if _profile_animation else 0
	var bindings: Array = instance.get_meta(BINDING_META) as Array
	var normalized: float = _float32(clampf(phase, 0.0, 1.0))
	for binding: Dictionary in bindings:
		var frames: TexturePackScript.AnimationFrames = binding.get("frame_cache") as TexturePackScript.AnimationFrames
		var texture_invalidated: bool = frames != null and frames.revision != TexturePackScript.animation_revision()
		if int(binding.get("manifest_revision",0)) != _manifest_revision:
			var updated: Dictionary = _animation_data.get(str(binding.key),{})
			if not updated.is_empty() and int(updated.get("vertex_count",-1))==int(binding.info.get("vertex_count",-2)) \
				and int(updated.get("part_index",-1))==int(binding.info.get("part_index",-2)):
				binding.info = updated
			binding.manifest_revision = _manifest_revision
			binding.last_phase = -1.0
			texture_invalidated = true
		if float(binding.last_phase) == normalized and not texture_invalidated:
			continue
		binding["last_phase"] = normalized
		var info: Dictionary = binding.info as Dictionary
		var sample: Dictionary = _sample_indices(info, normalized)
		var texture_index: int = int(sample.texture_frame_index)
		if bool(info.get("animate_texture", false)) and (texture_index != int(binding.texture_index) or texture_invalidated):
			var sequence: Array = info.get("texture_sequence", []) as Array
			if texture_index >= 0 and texture_index < sequence.size():
				var frame: Dictionary = sequence[texture_index] as Dictionary
				var relative: String = str(frame.get("path", ""))
				if frames == null:
					frames = TexturePackScript.create_animation_cache()
					binding.frame_cache = frames
				var texture: Texture2D = frames.sources.get(relative) as Texture2D
				if texture == null:
					texture = _texture(relative)
					if texture != null:
						frames.sources[relative] = texture
				if texture != null:
					var material: Material = binding.material as Material
					if material is ShaderMaterial:
						(material as ShaderMaterial).set_shader_parameter("has_texture", true)
					TexturePackScript.bind_material(material, texture)
					TexturePackScript.retain_animation_frame(frames, texture)
					binding["texture_index"] = texture_index
		if not bool(binding.mutable):
			continue
		var mesh: ArrayMesh = instance.mesh as ArrayMesh
		var ids: PackedInt32Array = binding.ids
		var buffer: PackedByteArray = binding.attributes
		var stride: int = int(binding.stride)
		var animate_color: bool = bool(info.get("source_color_animation", false))
		var animate_uv: bool = bool(info.get("animate_uv", false))
		var provenance: Dictionary = binding.get("source_weights", {})
		var weighted: bool = not provenance.is_empty()
		var source_ids: PackedInt32Array = provenance.get("ids", PackedInt32Array())
		var weights: PackedVector3Array = provenance.get("weights", PackedVector3Array())
		# Sample each original vertex once. Refinement increases only cheap
		# interpolation/upload work, never native timeline lookups per new corner.
		var sampled_colors := PackedVector3Array()
		var sampled_uvs := PackedVector2Array()
		if weighted:
			if animate_color:
				sampled_colors.resize(int(info.vertex_count))
			if animate_uv:
				sampled_uvs.resize(int(info.vertex_count))
			for source_id: int in range(int(info.vertex_count)):
				if animate_color:
					sampled_colors[source_id] = Vector3(_sample_rgb(info, sample, source_id))
				if animate_uv:
					sampled_uvs[source_id] = _sample_uv(info, sample, source_id)
		for vertex: int in range(ids.size()):
			var source_id: int = ids[vertex]
			var base: int = vertex * stride
			if animate_color:
				var color: Vector3i = Vector3i.ZERO
				if weighted:
					var value: Vector3 = Vector3.ZERO
					for corner: int in range(3):
						value += sampled_colors[source_ids[vertex * 3 + corner]] * weights[vertex][corner]
					color = Vector3i(roundi(value.x), roundi(value.y), roundi(value.z))
				else:
					color = _sample_rgb(info, sample, source_id)
				var offset: int = base + int(binding.color_offset)
				buffer[offset] = color.x
				buffer[offset + 1] = color.y
				buffer[offset + 2] = color.z
				buffer[offset + 3] = roundi(float(info.get("vertex_alpha", 1.0)) * 255.0)
			if animate_uv:
				var uv: Vector2 = Vector2.ZERO
				if weighted:
					uv = Vector2.ZERO
					for corner: int in range(3):
						uv += sampled_uvs[source_ids[vertex * 3 + corner]] * weights[vertex][corner]
				else:
					uv = _sample_uv(info, sample, source_id)
				var offset: int = base + int(binding.uv_offset)
				buffer.encode_float(offset, uv.x)
				buffer.encode_float(offset + 4, uv.y)
		binding["attributes"] = buffer
		mesh.surface_update_attribute_region(int(binding.surface), 0, buffer)
		if _profile_animation:
			_animation_profile.mutable_updates += 1
			_animation_profile.native_vertices_sampled += int(info.vertex_count) if weighted else ids.size()
			_animation_profile.vertices_rewritten += ids.size()
			_animation_profile.color_vertices += ids.size() if animate_color else 0
			_animation_profile.uv_vertices += ids.size() if animate_uv else 0
			_animation_profile.attribute_bytes_uploaded += buffer.size()
	if _profile_animation:
		_animation_profile.calls += 1
		_animation_profile.cpu_usec += Time.get_ticks_usec() - profile_start


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
		var existing: Texture2D = (_textures[path] as WeakRef).get_ref() as Texture2D
		if existing != null:
			return existing
	var texture: Texture2D
	_texture_load_counts[path] = int(_texture_load_counts.get(path,0))+1
	if path.begins_with("res://") and ResourceLoader.exists(path, "Texture2D"):
		texture = ResourceLoader.load(path, "Texture2D") as Texture2D
	elif FileAccess.file_exists(path):
		# Isolated source fixtures need no editor import and never modify .godot.
		var image := Image.new()
		if image.load(path) == OK:
			texture = ImageTexture.create_from_image(image)
	if texture != null:
		_textures[path] = weakref(texture)
	return texture


static func _shader(selector: int, enhanced: bool = false, repeat_enabled: bool = true) -> Shader:
	var key: String = "%d:%s:%s" % [selector, enhanced, repeat_enabled]
	if _shaders.has(key):
		return _shaders[key] as Shader
	var blend: String = "blend_mix" if selector == 0 or selector == 3 else ("blend_add" if selector == 1 else "blend_mul")
	var rgb: String = "vec3(1.0) - source.rgb" if selector == 2 else "source.rgb"
	var alpha: String = "source.a" if selector == 0 else "1.0"
	var filtering: String = "filter_linear_mipmap_anisotropic" if enhanced else "filter_nearest"
	var wrapping: String = "repeat_enable" if repeat_enabled else "repeat_disable"
	var lit: bool = enhanced and (selector == 0 or selector == 3)
	var modes: String = "cull_disabled, " + blend
	if selector != 3:
		modes += ", depth_draw_never"
	if not lit:
		modes += ", unshaded"
	# Native vertex colours already contain painted illumination. Preserve a
	# large ambient/emissive share while actual mesh normals and scene lights
	# reveal bevels and volume. Additive/inverse effects retain native equations.
	var output: String = "ALBEDO = " + rgb + ";"
	if lit:
		output = "ALBEDO = source.rgb * 0.40; EMISSION = source.rgb * 0.70; ROUGHNESS = 0.72; SPECULAR = 0.20;"
	if selector != 3:
		output += " ALPHA = " + alpha + ";"
	var shader := Shader.new()
	# 0x41090A disables Z writes for the sorted transparent queue.
	# 0x410919..0x410991 select alpha/add/inverse multiplication; the global
	# alpha test is >=8/255 (0x40F385), independently of the blend factors.
	shader.code = "shader_type spatial;\nrender_mode " + modes + ";\n" + \
		"uniform sampler2D albedo_texture : source_color, " + filtering + ", " + wrapping + ";\n" + \
		"uniform sampler2D source_alpha_texture : filter_linear, " + wrapping + ";\n" + \
		"uniform vec4 base_color : source_color = vec4(1.0);\n" + \
		"uniform float source_alpha_scale = 1.0;\n" + \
		"uniform bool use_source_alpha = false;\n" + \
		"uniform bool has_texture = false;\nuniform bool use_vertex_color = true;\n" + \
		"uniform vec2 uv_scale = vec2(1.0);\nuniform vec2 uv_offset = vec2(0.0);\n" + \
		"void fragment() {\n" + \
		"vec4 source = base_color * (has_texture ? texture(albedo_texture, UV * uv_scale + uv_offset) : vec4(1.0));\n" + \
		"if (use_source_alpha) { source.a = base_color.a * texture(source_alpha_texture, UV * uv_scale + uv_offset).a; }\n" + \
		"if (use_vertex_color) { source *= COLOR; }\n" + \
		"source.a *= source_alpha_scale;\n" + \
		"if (source.a < (8.0 / 255.0)) { discard; }\n" + \
		"source.rgb = clamp(source.rgb, vec3(0.0), vec3(1.0));\n" + \
		output + "\n}"
	_shaders[key] = shader
	return shader
