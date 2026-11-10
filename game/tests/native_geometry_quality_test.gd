extends SceneTree
## Asset-free native phase/attribute/collision/lifetime checks for mesh switching.
const Geometry = preload("res://scripts/native_geometry_quality.gd")
const Materials = preload("res://scripts/native_materials.gd")
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)
func _json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value)); file.close()
func _closure_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var points := PackedVector3Array([Vector3(0,0,1),Vector3(1,0,1),Vector3(0,1,1)])
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=points
	arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	mesh.set_meta("hugo_collision_faces",points)
	mesh.set_meta("hugo_collision_surface_types",PackedInt32Array([-1]))
	return mesh
func _boundary_hit(instance: MeshInstance3D) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(instance.global_transform*Vector3(0.25,0.25,2),instance.global_transform*Vector3(0.25,0.25,0),1)
	return instance.get_world_3d().direct_space_state.intersect_ray(query)
func _mesh(enhanced: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.resource_name = "fixture"
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	mesh.add_blend_shape("pose_001")
	var arrays: Array = []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(2,0), Vector2(0,0), Vector2(1,0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,2])
	var shape: Array = []; shape.resize(Mesh.ARRAY_MAX)
	shape[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0,0,0.2), Vector3(0,0,0.2), Vector3(0,0,0.2)])
	var lods: Dictionary = {}
	if enhanced:
		arrays[Mesh.ARRAY_VERTEX].append(Vector3(0.25,0.5,0.12))
		arrays[Mesh.ARRAY_COLOR].append(Color.WHITE)
		arrays[Mesh.ARRAY_TEX_UV].append(Vector2(0.25,0.5))
		arrays[Mesh.ARRAY_TEX_UV2].append(Vector2(-1,0))
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,3,1,2,3,2,0,3])
		shape[Mesh.ARRAY_VERTEX].append(Vector3(0,0,0.3))
		lods[0.25] = PackedInt32Array([0,1,2])
		mesh.set_meta(Geometry.WEIGHTS_META, [{"ids":PackedInt32Array([2,2,2,0,0,0,1,1,1,2,0,1]),
			"weights":PackedVector3Array([Vector3(1,0,0),Vector3(1,0,0),Vector3(1,0,0),Vector3(0.25,0.25,0.5)]),
			"part_index":0,"source_vertex_count":3,"native_material_key":"fixture"}])
		mesh.set_meta(Geometry.LODS_META,[lods])
		mesh.set_meta("hugo_collision_faces",PackedVector3Array([Vector3.ZERO,Vector3.RIGHT,Vector3.UP]))
		mesh.set_meta("hugo_collision_surface_types",PackedInt32Array([17]))
		mesh.set_meta("hugo_collision_complete",true)
		mesh.custom_aabb=AABB(Vector3(-0.1,-0.1,-0.1),Vector3(1.2,1.2,0.7))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[shape],lods)
	return mesh
func _run() -> void:
	var directory: String="user://geometry_quality_test"
	DirAccess.make_dir_recursive_absolute(directory)
	var info: Dictionary={"vertex_count":3,"part_index":0,"stored_samples":2,"timeline_words":[0,65536],
		"timeline_loop":false,"source_color_animation":true,"animate_uv":true,"animate_texture":false,"vertex_alpha":1.0,
		"color_samples":[[[109,109,109],[0,255,128],[255,128,0]],[[29,29,29],[255,0,128],[0,128,255]]],
		"uv_samples":[[[250,0],[255,32],[0,255]],[[10,255],[0,128],[255,0]]]}
	_json(directory+"/materials.json",{"materials":{"fixture":info}})
	_check(Materials.load_animation_manifest(directory+"/materials.json"),"native animation fixture loads")
	var replacement: ArrayMesh=_mesh(true)
	_check(ResourceSaver.save(replacement,directory+"/fixture.res")==OK,"rebuilt resource saves")
	replacement=null
	_check(ResourceSaver.save(_closure_mesh(),directory+"/closure.res")==OK,"independent visible boundary resource saves")
	_json(directory+"/geometry.json",{"schema_version":1,"meshes":{"levels/fixture.glb|fixture":{"path":"fixture.res"}},"instances":{},
		"closures":{"levels/fixture.glb|fixture_node":{"path":"closure.res","source_surface_index":0,"native_owner":"fixture_owner","always_present":true}}})
	_check(Geometry.load_manifest(directory+"/geometry.json"),"geometry manifest loads")
	Geometry.set_enabled(false)
	var source: ArrayMesh=_mesh(false)
	var material:=StandardMaterial3D.new()
	material.resource_name="fixture__hugo_anim_fixture__hugo_blend_3"
	source.surface_set_material(0,material)
	var owner:=Node3D.new(); root.add_child(owner)
	owner.position=Vector3(5,2,3)
	var instance:=MeshInstance3D.new(); instance.name="fixture_node"; instance.mesh=source
	owner.add_child(instance); instance.position=Vector3(0.5,0,0)
	Materials.apply_recursive(instance,"levels/fixture.glb")
	var closure: MeshInstance3D=instance.get_node_or_null("RemasterBoundaryClosure") as MeshInstance3D
	_check(closure!=null and closure.visible and closure.mesh.get_surface_count()==1,"Original includes the same explicit visible border completion")
	_check(Geometry.get_status().bound_instances==1 and Geometry.get_status().permanent_boundary_instances==1,"repair is counted separately from optional source geometry replacement")
	await physics_frame
	await physics_frame
	var initial_hit: Dictionary=_boundary_hit(instance)
	_check(not initial_hit.is_empty() and initial_hit.collider.get_meta("native_owner")=="fixture_owner" and initial_hit.collider.get_meta("native_surfaces")==[-1],
		"Original ray hits the visible completion with no inherited hazard classification")
	Materials.apply_phase(instance,0.35)
	instance.set_blend_shape_value(0,0.6)
	var transform: Transform3D=instance.global_transform
	var active: Material=instance.get_active_material(0)
	Geometry.set_enabled(true)
	_check(instance.get_node_or_null("RemasterBoundaryClosure")==closure and closure.material_override==active,"Enhanced preserves the same boundary and shared texture material")
	_check(Geometry.is_instance_enhanced(instance),"Enhanced binds the rebuilt mesh")
	_check(instance.mesh.surface_get_array_len(0)==4,"new curved vertex participates in the actual submitted mesh")
	_check(instance.get_active_material(0)==active,"quality toggle preserves current material resource")
	_check(instance.global_transform==transform and is_equal_approx(instance.get_blend_shape_value(0),0.6),"quality toggle preserves native transform and morph weight")
	var binding: Dictionary=instance.get_meta(Materials.BINDING_META)[0]
	_check(is_equal_approx(float(binding.last_phase),0.35),"quality toggle retains exact material phase")
	var sampled: Dictionary=Materials.sample_material(info,0.35)
	var bytes: PackedByteArray=binding.attributes
	var base: int=3*int(binding.stride)
	var rgb_offset: int=base+int(binding.color_offset)
	var uv_offset: int=base+int(binding.uv_offset)
	var weights: Array[float]=[0.25,0.25,0.5]
	var ids: Array[int]=[2,0,1]
	var weighted_uv:=Vector2.ZERO
	var weighted_color:=Vector3.ZERO
	for corner: int in range(3):
		weighted_uv+=Vector2(sampled.uv[ids[corner]][0],sampled.uv[ids[corner]][1])*weights[corner]
		weighted_color+=Vector3(sampled.rgb_bytes[ids[corner]][0],sampled.rgb_bytes[ids[corner]][1],sampled.rgb_bytes[ids[corner]][2])*weights[corner]
	_check(absf(bytes.decode_float(uv_offset)-weighted_uv.x)<0.000001 and absf(bytes.decode_float(uv_offset+4)-weighted_uv.y)<0.000001,
		"new UV uses all three source IDs and noninteger barycentric weights")
	_check(bytes[rgb_offset]==roundi(weighted_color.x) and bytes[rgb_offset+1]==roundi(weighted_color.y) and bytes[rgb_offset+2]==roundi(weighted_color.z),
		"new animated RGB samples preserve source byte semantics before spatial interpolation")
	var arrays: Array=instance.mesh.surface_get_arrays(0)
	_check((arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array)[3].x==-1.0,"weighted vertex sentinel is never rounded into a source vertex ID")
	_check(instance.mesh.has_meta(Geometry.LODS_META) and instance.mesh.get_meta(Geometry.LODS_META)[0].has(0.25),"private animated buffer preserves native mesh LOD indices")
	_check((instance.mesh as ArrayMesh).custom_aabb.size.z>0.6,"private animated buffer preserves all-pose culling bounds")
	var collision: Dictionary=Geometry.collision_for_owner(owner)
	_check(not collision.is_empty() and collision.faces[0]==Vector3(0.5,0,0) and collision.surface_types[0]==17,
		"rebuilt collision uses owner-local coordinates and original native surface type")
	var enhanced_ref: WeakRef=weakref(instance.mesh)
	Geometry.set_enabled(false)
	await physics_frame
	_check(instance.get_node_or_null("RemasterBoundaryClosure")==closure and not _boundary_hit(instance).is_empty(),"return to Original cannot reopen the missing map border")
	_check(not Geometry.is_instance_enhanced(instance) and instance.mesh.surface_get_array_len(0)==3,"Original restores every original vertex")
	_check(instance.get_active_material(0)==active and is_equal_approx(instance.get_blend_shape_value(0),0.6),"return to Original keeps material and morph playback")
	_check(is_equal_approx(float(instance.get_meta(Materials.BINDING_META)[0].last_phase),0.35),"return to Original keeps material phase")
	_check(Geometry.collision_for_owner(owner).is_empty(),"Original asks level to restore original native collision")
	_check(enhanced_ref.get_ref()==null,"unselected private rebuilt mesh is released")
	Geometry.set_enabled(true)
	Materials.apply_phase(instance,0.75)
	var valid_status: Dictionary=Geometry.get_status()
	_check(valid_status.enhanced_instances==1 and valid_status.mutable_attribute_vertices==4,"status counts actual mutable upload vertices")
	var live_ref: WeakRef=weakref(instance.mesh)
	owner.free()
	await process_frame
	_check(Geometry.get_status().bound_instances==0 and live_ref.get_ref()==null,"normal scene unload releases rebuilt mesh without disabling Enhanced")
	var missing:=MeshInstance3D.new(); missing.mesh=source; root.add_child(missing)
	Materials.apply_recursive(missing,"levels/missing.glb")
	_check(not Geometry.is_instance_enhanced(missing) and missing.mesh.surface_get_array_len(0)==3,"missing geometry falls back to complete source and still runs native material animation")
	_check(Geometry.get_status().fallback_reasons.get("source_not_in_pack",0)==1,"missing source fallback is explicit in coverage")
	missing.free()
	await process_frame
	print("NATIVE_GEOMETRY checks=",checks," failures=",JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)
