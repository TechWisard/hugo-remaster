extends SceneTree

const Index = preload("res://scripts/native_scene_index.gd")
const Materials = preload("res://scripts/native_materials.gd")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var parent := Node.new()
	parent.name = "ExcludedRoot"
	root.add_child(parent)
	for branch: int in range(3):
		var group := Node.new()
		group.name = "Group%d" % branch
		parent.add_child(group)
		for item: int in range(4):
			var child := Node3D.new()
			child.name = "Shared" if item == 0 else "g%03d_o%04d_t10000" % [branch, item]
			group.add_child(child)
	var index: Dictionary = Index.descendants(parent)
	_check(not index.has("ExcludedRoot"), "root excluded")
	_check(index.get("missing") == null, "missing source name stays absent")
	for name: String in index:
		_check(index[name] == parent.find_child(name, true, false), "preorder match " + name)
	for colored: bool in [false, true]:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		if colored:
			arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.RED, Color.GREEN, Color.BLUE])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var original := StandardMaterial3D.new()
		original.resource_name = "fixture__hugo_blend_3"
		mesh.surface_set_material(0, original)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		parent.add_child(instance)
		Materials.apply_recursive(instance)
		var effective: Material = instance.get_active_material(0)
		_check(effective is ShaderMaterial, "native blend selector keeps its shader material %s" % colored)
		var uses_colors: Variant = (effective as ShaderMaterial).get_shader_parameter("use_vertex_color") if effective is ShaderMaterial else null
		_check(uses_colors is bool and uses_colors == colored, "format bit preserves color presence %s" % colored)
		_check(not original.vertex_color_use_as_albedo, "source material untouched")
	var box := BoxMesh.new()
	var plain := StandardMaterial3D.new()
	plain.resource_name = "primitive__hugo_blend_3"
	plain.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var primitive_colors: bool = Materials.surface_has_vertex_colors(box, 0)
	var prepared: Material = Materials.prepare_material(plain, primitive_colors)
	_check(prepared != plain, "PrimitiveMesh gets a private prepared material")
	_check(prepared is ShaderMaterial, "PrimitiveMesh retains the native blend shader")
	var primitive_uses_colors: Variant = (prepared as ShaderMaterial).get_shader_parameter("use_vertex_color") if prepared is ShaderMaterial else null
	_check(not primitive_colors and primitive_uses_colors is bool and not primitive_uses_colors, "PrimitiveMesh without colors preserves its appearance")
	parent.queue_free()
	await process_frame
	print("NATIVE_SCENE_INDEX ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)
