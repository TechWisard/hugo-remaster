extends SceneTree
## Asset-free regressions for native material sampling and private GPU streams.
## Headless checks the submitted bytes; OpenGL also reads the GPU buffer back.

const MaterialsScript = preload("res://scripts/native_materials.gd")
const MotionScript = preload("res://scripts/native_actor_motion.gd")
const SamplerScript = preload("res://scripts/original_animation.gd")
const GeometryScript = preload("res://scripts/native_geometry_quality.gd")
const TexturePackScript = preload("res://scripts/hd_texture_pack.gd")
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _write_json(path: String, value: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _run() -> void:
	# This fixture asserts exact native vertex/UV IDs and morph bytes. The
	# separate geometry suite checks weighted attributes on rebuilt surfaces.
	GeometryScript.set_enabled(false)
	var directory: String = "user://native_material_test"
	DirAccess.make_dir_recursive_absolute(directory)
	var red: Image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	red.fill(Color.RED)
	red.save_png(directory + "/red.png")
	var blue: Image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	blue.fill(Color.BLUE)
	blue.save_png(directory + "/blue.png")
	var info: Dictionary = {
		"vertex_count": 3, "part_index": 0, "stored_samples": 2,
		"timeline_words": [0, 65536], "timeline_loop": false,
		"source_color_animation": true, "animate_uv": true, "animate_texture": true,
		"vertex_alpha": 1.0,
		"texture_sequence": [{"path": "red.png"}, {"path": "red.png"}, {"path": "blue.png"}],
		"color_samples": [[[109, 109, 109], [0, 255, 128], [255, 128, 0]],
			[[29, 29, 29], [255, 0, 128], [0, 128, 255]]],
		"uv_samples": [[[250, 0], [255, 32], [0, 255]], [[10, 255], [0, 128], [255, 0]]]
	}
	_write_json(directory + "/manifest.json", {"materials": {"g001_r0002_p000": info}})
	_check(MaterialsScript.load_animation_manifest(directory + "/manifest.json"), "synthetic manifest loads")
	var edge: Dictionary = MaterialsScript.sample_material(info, 0.15)
	_check(edge.rgb_bytes[0] == [96, 97, 97], "native R x87 / G,B float32 truncation edge")
	_check(edge.rgb_bytes[1] == [38, 216, 128], "native RGB interpolation truncates bytes")
	_check(absf(float(edge.uv[0][0]) - 0.8392157554626465) < 0.0000001,
		"UV interpolates through byte values without seam wrapping")
	_check(absf(float(edge.uv[0][1]) - 0.15000002086162567) < 0.0000001,
		"UV multiplies source float32 reciprocal 255")
	var end: Dictionary = MaterialsScript.sample_material(info, 1.0)
	_check(int(end.sample_a) == 1 and float(end.sample_weight) == 0.0, "nonlooping morph timeline retains its final sample")
	_check(int(end.texture_frame_index) == 0, "texture sequence independently wraps exact phase one")
	_check(int(MaterialsScript.sample_material(info, 0.5).texture_frame_index) == 1,
		"duplicate texture entries remain authored sequence slots")
	var loop: Dictionary = info.duplicate(true)
	loop.timeline_loop = true
	_check(int(MaterialsScript.sample_material(loop, 1.0).sample_a) == 0, "looping timeline wraps its final sample")
	var plain: Dictionary = info.duplicate(true)
	plain.source_color_animation = false
	plain.color_samples = [info.color_samples[0]]
	plain.vertex_alpha = 128.0 / 255.0
	var static_color: Dictionary = MaterialsScript.sample_material(plain, 0.75)
	_check(static_color.rgb_bytes[0] == [109, 109, 109], "clear source color flag uses first RGB sample")
	_check(absf(float(static_color.rgba[0][3]) - 128.0 / 255.0) < 0.0000001,
		"plain vertex alpha is fixed128/255")
	var material := StandardMaterial3D.new()
	material.resource_name = "fixture__hugo_anim_g001_r0002_p000__hugo_blend_0"
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = ImageTexture.create_from_image(red)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	# Deliberately reordered IDs: never assume source and imported vertex order.
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(2, 0), Vector2(0, 0), Vector2(1, 0)])
	var pose: Array = []
	pose.resize(Mesh.ARRAY_MAX)
	pose[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0,0,0.1), Vector3(1,0,0.1), Vector3(0,1,0.1)])
	var mesh := ArrayMesh.new()
	mesh.add_blend_shape("sample_001")
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [pose])
	mesh.surface_set_material(0, material)
	var owner_visual := Node3D.new()
	root.add_child(owner_visual)
	var action := Node3D.new()
	action.name = "Action000"
	owner_visual.add_child(action)
	var instance := MeshInstance3D.new()
	instance.name = "MaterialFixture"
	instance.mesh = mesh
	action.add_child(instance)
	MaterialsScript.apply_recursive(instance)
	_check(instance.mesh != mesh, "mutable attributes use a private mesh")
	_check(instance.get_active_material(0) != material and mesh.surface_get_material(0) == material,
		"material overrides leave shared source resources unchanged")
	_check(instance.mesh.get_surface_count() == 1 and instance.mesh.surface_get_array_len(0) == 3,
		"private copy preserves geometry counts")
	_check(instance.mesh.get_blend_shape_count() == 1 and instance.mesh.get_blend_shape_name(0) == "sample_001",
		"private copy preserves original morph target")
	_check(instance.mesh.surface_get_blend_shape_arrays(0)[0][Mesh.ARRAY_VERTEX] == pose[Mesh.ARRAY_VERTEX],
		"private copy preserves morph vertex data")
	instance.set_blend_shape_value(0, 0.4)
	MaterialsScript.apply_phase(instance, 0.15)
	_check(is_equal_approx(instance.get_blend_shape_value(0), 0.4), "material sampling leaves morph playback untouched")
	var bindings: Array = instance.get_meta(MaterialsScript.BINDING_META) as Array
	var binding: Dictionary = bindings[0]
	var bytes: PackedByteArray = binding.attributes
	var stride: int = int(binding.stride)
	var color_offset: int = int(binding.color_offset)
	var uv_offset: int = int(binding.uv_offset)
	var ids: PackedInt32Array = binding.ids
	var valid: bool = true
	for vertex: int in range(3):
		for channel: int in range(3):
			valid = valid and int(bytes[vertex * stride + color_offset + channel]) == int(edge.rgb_bytes[ids[vertex]][channel])
		valid = valid and absf(bytes.decode_float(vertex * stride + uv_offset) - float(edge.uv[ids[vertex]][0])) < 0.0000001
	_check(valid, "attribute upload follows source IDs after vertex reordering")
	var format: int = instance.mesh.surface_get_format(0)
	var id_offset: int = RenderingServer.mesh_surface_get_format_offset(format, 3, Mesh.ARRAY_TEX_UV2)
	_check(bytes.decode_float(id_offset) == 2.0 and bytes.decode_float(stride + id_offset) == 0.0
		and bytes.decode_float(2 * stride + id_offset) == 1.0, "attribute upload retains UV2 IDs")
	if DisplayServer.get_name() != "headless":
		var storage: Dictionary = RenderingServer.mesh_get_surface(instance.mesh.get_rid(), 0)
		_check((storage.attribute_data as PackedByteArray) == bytes, "actual GPU attribute buffer matches submitted native bytes")
	MaterialsScript.apply_phase(instance, 0.75)
	var adapted: ShaderMaterial = instance.get_active_material(0) as ShaderMaterial
	_check((adapted.get_shader_parameter("albedo_texture") as Texture2D).get_image().get_data() == blue.get_data(),
		"shader receives exact selected texture frame")
	MaterialsScript.apply_phase(instance, 1.0)
	_check((adapted.get_shader_parameter("albedo_texture") as Texture2D).get_image().get_data() == red.get_data(),
		"shader texture resets at sequence endpoint")
	var sampler: HugoOriginalAnimation = SamplerScript.new()
	root.add_child(sampler)
	var motion: NativeActorMotion = MotionScript.new()
	motion.owner_visual = owner_visual
	motion.sampler = sampler
	motion.source = {"actions": [{"index": 0, "node_name": "Action000", "duration": 1.0}],
		"mesh_instances": [{"name": "MaterialFixture", "action": 0, "stored_samples": 1, "transform_chain": []}]}
	motion.native = {}
	motion.tracks = {}
	motion.autonomous = false
	root.add_child(motion)
	motion.sample_state(0, 0.75, 0.0, {})
	_check((adapted.get_shader_parameter("albedo_texture") as Texture2D).get_image().get_data() == blue.get_data(),
		"actor visual phase animates materials even with one stored morph sample")
	sampler.manifest = {"tracks": {}}
	sampler.current_clip = "fixture"
	sampler.native_phase = 1.0
	sampler._bindings = {"fixture": [{"instance": instance, "data": {"stored_samples": 1}}]}
	sampler._apply_pose()
	_check((adapted.get_shader_parameter("albedo_texture") as Texture2D).get_image().get_data() == red.get_data(),
		"Hugo original animation forwards its native visual phase")
	var rock_mesh := ArrayMesh.new()
	rock_mesh.resource_name = "ImportedScene_BoundaryRockSource"
	rock_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var rock_source := StandardMaterial3D.new()
	rock_source.resource_name = "rock__hugo_blend_3"
	rock_source.albedo_texture = material.albedo_texture
	rock_source.texture_repeat = false
	rock_mesh.surface_set_material(0, rock_source)
	var neighbour := MeshInstance3D.new()
	neighbour.mesh = rock_mesh
	owner_visual.add_child(neighbour)
	var bank: ShaderMaterial = MaterialsScript.prepare_boundary_material(instance, {
		"material_source_mesh_name":"BoundaryRockSource", "material_source_surface_index":0,
		"material_source_texture_key":TexturePackScript.get_source_key(rock_source.albedo_texture),
		"texture_repeat":true}) as ShaderMaterial
	_check(bank != null and TexturePackScript.get_bound_source(bank) == rock_source.albedo_texture,
		"permanent bank borrows the exact native neighbour texture without reloading the scene")
	_check(not rock_source.texture_repeat and rock_mesh.surface_get_material(0) == rock_source,
		"new physical UV mapping leaves the neighbour's authored clamp material unchanged")
	TexturePackScript.set_enabled(false)
	_check(bank.shader.code.contains("filter_nearest, repeat_enable"),
		"Original bank retains physical tiling while using the original texture filter")
	TexturePackScript.set_enabled(true)
	_check(bank.shader.code.contains("filter_linear_mipmap_anisotropic, repeat_enable"),
		"Enhanced bank restores anisotropic mipmapped tiling through the live quality binding")
	motion.free()
	sampler.free()
	owner_visual.free()
	GeometryScript.set_enabled(true)
	await process_frame
	print("NATIVE MATERIAL TEST: ", "PASS" if failures.is_empty() else "FAIL", " ", checks - failures.size(), "/", checks)
	quit(0 if failures.is_empty() else 1)
