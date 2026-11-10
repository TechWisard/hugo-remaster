extends SceneTree
## Turn the offline numerical bake into portable native ArrayMesh resources.
## --geometry-input=PATH/index.json [--geometry-output=res://assets/hd/models]
## Original meshes, models and images are never overwritten.

var _input: String = ""
var _output: String = "res://assets/hd/models"
var _file: FileAccess
var _binary_offset: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--geometry-input="):
			_input = argument.trim_prefix("--geometry-input=")
		elif argument.begins_with("--geometry-output="):
			_output = argument.trim_prefix("--geometry-output=")
	if _input.is_empty() or not FileAccess.file_exists(_input):
		push_error("Use --geometry-input=PATH/index.json from tools/build_geometry_quality.py")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_input))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		push_error("Invalid geometry bake index")
		quit(1)
		return
	if DirAccess.make_dir_recursive_absolute(_output) != OK:
		push_error("Cannot create geometry output directory")
		quit(1)
		return
	var completed: int = 0
	var actual_resources: Dictionary = {}
	for name: String in parsed.get("resources", {}):
		if not _safe_relative(name):
			_failures.append("invalid_output_path:" + name)
			continue
		var record: Dictionary = parsed.resources[name]
		var relative: String = str(record.get("input", ""))
		if not _safe_relative(relative):
			_failures.append("invalid_input_path:" + relative)
			continue
		var path: String = _input.get_base_dir().path_join(relative)
		var mesh: ArrayMesh = _read_mesh(path)
		if mesh == null:
			_failures.append("invalid_mesh:" + relative)
			continue
		if ResourceSaver.save(mesh, _output.path_join(name), ResourceSaver.FLAG_COMPRESS) != OK:
			_failures.append("save_failed:" + name)
			continue
		var saved := FileAccess.open(_output.path_join(name), FileAccess.READ)
		actual_resources[name] = {"resource_sha256": FileAccess.get_sha256(_output.path_join(name)),
			"resource_bytes": saved.get_length() if saved != null else 0}
		if saved != null:
			saved.close()
		completed += 1
		if completed % 25 == 0:
			print("GEOMETRY_IMPORT progress=", completed, "/", parsed.resources.size())
		await process_frame
	var manifest: Dictionary = {"schema_version": 1, "complete_campaign": parsed.get("complete_campaign", false),
		"semantic_stage_enabled": parsed.get("semantic_stage_enabled", false), "meshes": parsed.get("meshes", {}),
		"cutout_stage_enabled": parsed.get("cutout_stage_enabled", false),
		"instances": parsed.get("instances", {}), "closures": parsed.get("closures", {}), "summary": parsed.get("summary", {}),
		"resources": {}, "imported_resources": completed, "failures": _failures,
		"source_inputs": parsed.get("source_inputs", {}),
		"replacement_alpha_inputs": parsed.get("replacement_alpha_inputs", {}),
		"pipeline_sha256": parsed.get("pipeline_sha256", {}), "build_options": parsed.get("build_options", {}),
		"method": "Offline curved surfaces, explicit native attribute weights, semantic volumes, preserved morph phases and index LODs"}
	for name: String in parsed.get("resources", {}):
		var metadata: Dictionary = (parsed.resources[name] as Dictionary).duplicate(true)
		metadata.erase("input")
		metadata.merge(actual_resources.get(name, {}), true)
		manifest.resources[name] = metadata
	if not _failures.is_empty():
		push_error("Geometry import incomplete; existing production manifest remains unchanged: " + JSON.stringify(_failures))
		quit(1)
		return
	var target: String = _output.path_join("geometry_pack.json")
	var output := FileAccess.open(target, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write geometry pack manifest")
		quit(1)
		return
	output.store_string(JSON.stringify(manifest, "\t"))
	output.close()
	print("GEOMETRY_IMPORT ", JSON.stringify({"resources": completed, "manifest": target,
		"complete_campaign": manifest.complete_campaign, "failures": _failures}))
	quit(0)


func _read_mesh(path: String) -> ArrayMesh:
	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null or _file.get_buffer(8).get_string_from_ascii() != "HUGOGEO1":
		return null
	var length: int = _file.get_32()
	if length <= 0 or length > _file.get_length() - 12:
		return null
	var parsed: Variant = JSON.parse_string(_file.get_buffer(length).get_string_from_utf8())
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		return null
	var header: Dictionary = parsed
	_binary_offset = 12 + length
	var mesh := ArrayMesh.new()
	mesh.resource_name = str(header.get("mesh_name", "")) + "__remastered"
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	for name: String in header.get("blend_shape_names", []):
		mesh.add_blend_shape(name)
	var all_weights: Array[Dictionary] = []
	var all_lods: Array[Dictionary] = []
	var bounds := AABB()
	var bounds_set: bool = false
	var pose_count: int = int(header.pose_count)
	for surface: Dictionary in header.get("surfaces", []):
		var points: PackedVector3Array = _vectors3(surface.positions)
		var normals: PackedVector3Array = _vectors3(surface.normals)
		var vertex_count: int = int(surface.positions.shape[1])
		if points.size() != vertex_count * pose_count or normals.size() != points.size():
			return null
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = points.slice(0, vertex_count)
		arrays[Mesh.ARRAY_NORMAL] = normals.slice(0, vertex_count)
		arrays[Mesh.ARRAY_COLOR] = _colors(surface.colors)
		arrays[Mesh.ARRAY_INDEX] = _godot_indices(surface.indices)
		if surface.get("uv") is Dictionary:
			arrays[Mesh.ARRAY_TEX_UV] = _vectors2(surface.uv)
		if surface.get("uv2") is Dictionary:
			arrays[Mesh.ARRAY_TEX_UV2] = _vectors2(surface.uv2)
		var targets: Array[Array] = []
		for pose: int in range(1, pose_count):
			var target: Array = []
			target.resize(Mesh.ARRAY_MAX)
			var positions_delta := PackedVector3Array()
			var normals_delta := PackedVector3Array()
			positions_delta.resize(vertex_count)
			normals_delta.resize(vertex_count)
			for index: int in range(vertex_count):
				positions_delta[index] = points[pose * vertex_count + index] - points[index]
				normals_delta[index] = normals[pose * vertex_count + index] - normals[index]
			target[Mesh.ARRAY_VERTEX] = positions_delta
			target[Mesh.ARRAY_NORMAL] = normals_delta
			targets.append(target)
		var lods: Dictionary = {}
		for distance: String in surface.get("lods", {}):
			lods[float(distance)] = _godot_indices(surface.lods[distance])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, targets, lods)
		mesh.surface_set_name(mesh.get_surface_count() - 1, "surface_%03d" % (mesh.get_surface_count() - 1))
		all_lods.append(lods)
		all_weights.append({"ids": _ints(surface.source_ids), "weights": _vectors3(surface.source_weights),
			"part_index": int(surface.get("part_index", -1)),
			"native_material_key": str(surface.get("native_material_key", "")),
			"source_vertex_count": int(surface.get("source_vertex_count", 0))})
		for point: Vector3 in points:
			if not point.is_finite():
				return null
			if not bounds_set:
				bounds = AABB(point, Vector3.ZERO)
				bounds_set = true
			else:
				bounds = bounds.expand(point)
	if mesh.get_surface_count() != header.surfaces.size():
		return null
	# Morphing bodies must remain inside their culling bounds in every action
	# pose, including geometry that extends beyond the original bind pose.
	mesh.custom_aabb = bounds.grow(0.001)
	mesh.set_meta("hugo_geometry_source_weights", all_weights)
	mesh.set_meta("hugo_geometry_lods", all_lods)
	mesh.set_meta("hugo_geometry_metadata", header.get("metadata", {}))
	mesh.set_meta("hugo_collision_faces", _vectors3(header.collision_faces))
	mesh.set_meta("hugo_collision_surface_types", _ints(header.collision_surface_types))
	mesh.set_meta("hugo_collision_complete", true)
	_file.close()
	_file = null
	return mesh


func _bytes(descriptor: Dictionary) -> PackedByteArray:
	var elements: int = 1
	for count: int in descriptor.shape:
		elements *= count
	var position: int = _binary_offset + int(descriptor.offset)
	if position < _binary_offset or position + elements * 4 > _file.get_length():
		push_error("Geometry numerical array is outside its input file")
		return PackedByteArray()
	_file.seek(position)
	return _file.get_buffer(elements * 4)


func _ints(descriptor: Dictionary) -> PackedInt32Array:
	return _bytes(descriptor).to_int32_array()


func _godot_indices(descriptor: Dictionary) -> PackedInt32Array:
	# The numerical bake follows glTF's counterclockwise front faces. Godot's
	# native GLB importer reverses them; portable ArrayMesh must do the same.
	# Normals already point outward and must not be negated with the indices.
	var indices: PackedInt32Array = _ints(descriptor)
	for at: int in range(0,indices.size(),3):
		var second: int = indices[at+1]
		indices[at+1] = indices[at+2]
		indices[at+2] = second
	return indices


func _vectors3(descriptor: Dictionary) -> PackedVector3Array:
	var values: PackedFloat32Array = _bytes(descriptor).to_float32_array()
	var result := PackedVector3Array()
	result.resize(values.size() / 3)
	for index: int in range(result.size()):
		result[index] = Vector3(values[index * 3], values[index * 3 + 1], values[index * 3 + 2])
	return result


func _vectors2(descriptor: Dictionary) -> PackedVector2Array:
	var values: PackedFloat32Array = _bytes(descriptor).to_float32_array()
	var result := PackedVector2Array()
	result.resize(values.size() / 2)
	for index: int in range(result.size()):
		result[index] = Vector2(values[index * 2], values[index * 2 + 1])
	return result


func _colors(descriptor: Dictionary) -> PackedColorArray:
	var values: PackedFloat32Array = _bytes(descriptor).to_float32_array()
	var result := PackedColorArray()
	result.resize(values.size() / 4)
	for index: int in range(result.size()):
		result[index] = Color(values[index * 4], values[index * 4 + 1], values[index * 4 + 2], values[index * 4 + 3])
	return result


func _safe_relative(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and not ":" in path \
		and not "\\" in path and not ".." in path.split("/")
