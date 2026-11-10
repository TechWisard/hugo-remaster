extends SceneTree
## Real image/resource loads, repeated frame cycles, quality invalidation, and
## owner lifetime. No original game files or editor imports are required.
const Materials=preload("res://scripts/native_materials.gd")
const Pack=preload("res://scripts/hd_texture_pack.gd")
var checks: int=0
var failures: Array[String]=[]
var directory: String="user://native_texture_animation_cache_test"

func _initialize() -> void:_run.call_deferred()
func _check(ok: bool,issue: String) -> void:
	checks+=1
	if not ok:failures.append(issue);push_error(issue)
func _json(path: String,value: Dictionary) -> void:
	var file:=FileAccess.open(path,FileAccess.WRITE);file.store_string(JSON.stringify(value));file.close()
func _resource(path: String,color: Color) -> void:
	var texture:=GradientTexture2D.new();texture.width=1024;texture.height=1024
	texture.gradient=Gradient.new();texture.gradient.colors=PackedColorArray([color,color])
	_check(ResourceSaver.save(texture,path)==OK,"native texture fixture saves")
func _fixture() -> MeshInstance3D:
	var mesh:=ArrayMesh.new();var arrays: Array=[];arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3.ZERO,Vector3.UP,Vector3.RIGHT])
	arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var material:=StandardMaterial3D.new();material.resource_name="cache__hugo_anim_cache__hugo_blend_3"
	mesh.surface_set_material(0,material)
	var instance:=MeshInstance3D.new();instance.mesh=mesh;root.add_child(instance)
	Materials.apply_recursive(instance)
	return instance
func _selected(instance: MeshInstance3D) -> Texture2D:
	return (instance.get_active_material(0) as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D

func _exercise(instance: MeshInstance3D,info: Dictionary) -> Array[WeakRef]:
	var binding: Dictionary=instance.get_meta(Materials.BINDING_META)[0]
	var frames: Pack.AnimationFrames=binding.frame_cache
	var red_source: WeakRef=weakref(Pack.get_bound_source(instance.get_active_material(0)))
	var red_hd: WeakRef=weakref(_selected(instance))
	Materials.apply_phase(instance,0.75)
	var blue_hd: WeakRef=weakref(_selected(instance))
	_check(red_source.get_ref()!=null and red_hd.get_ref()!=null,"previous original and HD frame remain resident while animation owner is alive")
	for cycle: int in range(100):
		Materials.apply_phase(instance,0.0);Materials.apply_phase(instance,0.75)
	_check(int(Materials._texture_load_counts.get(directory+"/source0.png",0))==1 and int(Materials._texture_load_counts.get(directory+"/source1.png",0))==1,
		"one source decode per demanded frame across one hundred loops")
	_check(int(Pack._replacement_load_counts.get(directory+"/hd0.tres@0",0))==1 and int(Pack._replacement_load_counts.get(directory+"/hd1.tres@0",0))==1,
		"one HD resource load per demanded frame across one hundred loops")
	_check(frames.sources.size()==2 and frames.resolved.size()==2,"cache owns only frames actually requested by this binding")
	Pack.set_max_texture_dimension(512)
	_check(red_hd.get_ref()==null and blue_hd.get_ref()==null and frames.sources.is_empty() and frames.resolved.is_empty(),
		"resolution change immediately releases old frame bank including inactive frames")
	Materials.apply_phase(instance,0.75)
	_check(_selected(instance).get_width()==512 and frames.resolved.size()==1,"unchanged native phase rebinds the new memory tier")
	Materials.apply_phase(instance,0.0)
	var resized: WeakRef=weakref(_selected(instance))
	Pack.set_enabled(false)
	_check(resized.get_ref()==null and frames.resolved.is_empty(),"Original immediately releases retained HD frames")
	Materials.apply_phase(instance,0.0)
	_check(_selected(instance).get_width()==2,"Original still selects the exact native source frame")
	_check("unshaded" in (instance.get_active_material(0) as ShaderMaterial).shader.code,"animated phase preserves Original lighting after initial texture-free registration")
	Pack.set_enabled(true)
	Materials.apply_phase(instance,0.0)
	_check(_selected(instance).get_width()==512,"Enhanced resumes at the selected phase and current tier")
	_check(Pack.load_manifest(directory+"/pack_v2.json"),"replacement manifest reloads")
	_check(frames.resolved.is_empty(),"manifest replacement immediately clears the owner's stale frame bank")
	Materials.apply_phase(instance,0.0)
	_check(_selected(instance).get_image().get_pixel(0,0).is_equal_approx(Color.GREEN),"same phase receives the new manifest's actual replacement")
	var reversed: Dictionary=info.duplicate(true);reversed.texture_sequence.reverse()
	_json(directory+"/animation_v2.json",{"materials":{"cache":reversed}})
	Materials.load_animation_manifest(directory+"/animation_v2.json")
	_check(frames.sources.is_empty() and frames.resolved.is_empty(),"native animation manifest invalidates frame ownership")
	Materials.apply_phase(instance,0.0)
	_check(Pack.get_bound_source(instance.get_active_material(0)).get_image().get_pixel(0,0).is_equal_approx(Color.BLUE),
		"native sequence reload changes the selected source even at an unchanged phase")
	return [weakref(frames),weakref(_selected(instance)),weakref(Pack.get_bound_source(instance.get_active_material(0)))]

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var keys: Array[String]=[]
	for id: int in range(2):
		var pixels:=Image.create(2,2,false,Image.FORMAT_RGBA8);pixels.fill(Color.RED if id==0 else Color.BLUE)
		_check(pixels.save_png(directory+"/source%d.png"%id)==OK,"source frame fixture saves")
		var digest:=HashingContext.new();digest.start(HashingContext.HASH_SHA256);digest.update(pixels.get_data())
		keys.append("2x2:"+digest.finish().hex_encode())
		_resource(directory+"/hd%d.tres"%id,Color.RED if id==0 else Color.BLUE)
		_resource(directory+"/next%d.tres"%id,Color.GREEN if id==0 else Color.YELLOW)
	_json(directory+"/pack.json",{"schema_version":1,"textures":{keys[0]:{"path":"hd0.tres"},keys[1]:{"path":"hd1.tres"}}})
	_json(directory+"/pack_v2.json",{"schema_version":1,"textures":{keys[0]:{"path":"next0.tres"},keys[1]:{"path":"next1.tres"}}})
	Pack.load_manifest(directory+"/pack.json");Pack.set_max_texture_dimension(0);Pack.set_enabled(true)
	var info: Dictionary={"part_index":0,"vertex_count":3,"stored_samples":1,"animate_texture":true,
		"texture_sequence":[{"path":"source0.png"},{"path":"source1.png"}]}
	_json(directory+"/animation.json",{"materials":{"cache":info}})
	Materials.load_animation_manifest(directory+"/animation.json")
	var instance: MeshInstance3D=_fixture()
	var references: Array[WeakRef]=_exercise(instance,info)
	instance.free();await process_frame
	var status: Dictionary=Pack.get_status()
	_check(status.live_animation_frame_caches==0 and references[0].get_ref()==null,"destroying the owner releases its frame cache")
	_check(references[1].get_ref()==null and references[2].get_ref()==null and status.resident_textures==0,
		"no global strong reference survives scene unload")
	print("NATIVE_ANIMATION_CACHE checks=",checks," failures=",JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)
