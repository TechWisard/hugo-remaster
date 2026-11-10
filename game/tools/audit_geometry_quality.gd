extends SceneTree
## Inspect actual bound campaign meshes, every morph, native attribute weights,
## index LODs, resource lifetime, and optionally live chapter collision owners.
## --geometry-manifest=PATH --geometry-report=PATH [--geometry-with-levels]

const Geometry = preload("res://scripts/native_geometry_quality.gd")
const Materials = preload("res://scripts/native_materials.gd")
const LevelScript = preload("res://scripts/original_level.gd")
const AudioScript = preload("res://scripts/native_audio.gd")
var manifest_path: String = Geometry.DEFAULT_MANIFEST
var output: String = "user://geometry_quality_report.json"
var with_levels: bool = false
var failures: Array[Dictionary] = []
var checks: int = 0
var scenes: Array[Dictionary] = []
var levels: Array[Dictionary] = []
var inspected_resources: Dictionary = {}
var morph_targets: int = 0

func _hold_materials(node: Node, retained: Array[Material]) -> void:
	# Instance shader parameters can still be queued when a scene is removed.
	# Keep their materials alive until two rendering-server flushes have passed,
	# including with Godot's headless dummy renderer.
	if node is MeshInstance3D:
		var instance: MeshInstance3D=node as MeshInstance3D
		if instance.mesh!=null:
			for surface: int in range(instance.mesh.get_surface_count()):
				var material: Material=instance.get_active_material(surface)
				if material!=null:retained.append(material)
	for child: Node in node.get_children():_hold_materials(child,retained)

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, subject: String, message: String) -> void:
	checks += 1
	if not ok:
		failures.append({"subject":subject,"issue":message})

func _inspect(instance: MeshInstance3D, scene: String) -> void:
	if bool(instance.get_meta(Geometry.CLOSURE_META,false)):
		return
	var label: String=scene+"|"+str(instance.name)
	_check(Geometry.is_instance_enhanced(instance),label,"source mesh has no compatible rebuilt binding")
	if not Geometry.is_instance_enhanced(instance):
		return
	var mesh: ArrayMesh=instance.mesh as ArrayMesh
	_check(mesh!=null,label,"rebuilt mesh must be a native ArrayMesh")
	if mesh==null:
		return
	var resource: String=str(Geometry.get_binding_report(instance).get("replacement_path",mesh.resource_path))
	# Mutable material copies share geometry, but their buffers are inspected
	# individually by the native runtime tests. Avoid expanding identical static
	# morph arrays for every repeated tree or actor instance in this census.
	var key: String=resource+":"+str(mesh.get_surface_count())+":"+str(mesh.get_blend_shape_count())
	if inspected_resources.has(key):
		return
	inspected_resources[key]=true
	var weights: Array=mesh.get_meta(Geometry.WEIGHTS_META,[])
	var lods: Array=mesh.get_meta(Geometry.LODS_META,[])
	var original: Mesh=Geometry.get_original_mesh(instance)
	_check(weights.size()==mesh.get_surface_count() and lods.size()==mesh.get_surface_count(),label,"provenance and LOD metadata cover every surface")
	for surface: int in range(mesh.get_surface_count()):
		var arrays: Array=mesh.surface_get_arrays(surface)
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var bounds: AABB=mesh.custom_aabb.grow(0.0001)
		for point: Vector3 in points:
			if not point.is_finite() or not bounds.has_point(point):
				_check(false,label,"base vertex is nonfinite or outside custom culling bounds")
				break
		if surface<weights.size():
			var row: Dictionary=weights[surface]
			var ids: PackedInt32Array=row.get("ids",PackedInt32Array())
			var bary: PackedVector3Array=row.get("weights",PackedVector3Array())
			_check(ids.size()==points.size()*3 and bary.size()==points.size(),label,"one valid native source triple per submitted vertex")
			var allowed: Dictionary={}
			var source_arrays: Array=original.surface_get_arrays(surface)
			var source_uv2: PackedVector2Array=source_arrays[Mesh.ARRAY_TEX_UV2] if source_arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array else PackedVector2Array()
			if source_uv2.is_empty():
				for vertex: int in range(original.surface_get_array_len(surface)):allowed[vertex]=true
			else:
				for native: Vector2 in source_uv2:allowed[roundi(native.x)]=true
			for native: int in ids:
				if not allowed.has(native):
					_check(false,label,"rebuilt vertex references a native ID absent from its original material surface")
					break
			for value: Vector3 in bary:
				if not value.is_finite() or minf(value.x,minf(value.y,value.z))< -0.00001 or absf(value.x+value.y+value.z-1.0)>0.0001:
					_check(false,label,"negative or nonnormalized native interpolation weights")
					break
		if surface<lods.size():
			for threshold: Variant in lods[surface]:
				var indices: PackedInt32Array=lods[surface][threshold]
				_check(float(threshold)>0 and indices.size()%3==0,label,"LOD has valid projected error and complete triangles")
				for vertex: int in indices:
					if vertex<0 or vertex>=points.size():
						_check(false,label,"LOD references an absent vertex")
						break
		var shapes: Array=mesh.surface_get_blend_shape_arrays(surface)
		_check(shapes.size()==mesh.get_blend_shape_count(),label,"every native morph target is retained")
		for shape: Array in shapes:
			var delta: PackedVector3Array=shape[Mesh.ARRAY_VERTEX]
			morph_targets+=1
			_check(delta.size()==points.size(),label,"morph vertex count matches rebuilt surface")
			for vertex: int in range(mini(delta.size(),points.size())):
				var moved: Vector3=points[vertex]+delta[vertex]
				if not moved.is_finite() or not bounds.has_point(moved):
					_check(false,label,"authored morph pose leaves its culling bounds")
					break

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--geometry-manifest="):manifest_path=arg.trim_prefix("--geometry-manifest=")
		elif arg.begins_with("--geometry-report="):output=arg.trim_prefix("--geometry-report=")
		elif arg=="--geometry-with-levels":with_levels=true
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("GEOMETRY_AUDIT no local source campaign; clean checkout demonstration remains available")
		quit(0);return
	_check(Geometry.load_manifest(manifest_path),manifest_path,"geometry pack manifest loads")
	Geometry.set_enabled(true)
	var catalog: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/campaign.json"))
	var animation: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/animation_manifest.json"))
	var paths: Array[String]=[]
	for entry: Dictionary in catalog.levels:paths.append(str(entry.geometry_path))
	for path: String in animation.files:
		if path.ends_with(".glb") and not path in paths:paths.append(path)
	for path: String in paths:
		var packed: PackedScene=ResourceLoader.load("res://assets/generated/"+path,"PackedScene") as PackedScene
		_check(packed!=null,path,"source scene loads")
		if packed==null:continue
		var scene: Node=packed.instantiate()
		root.add_child(scene)
		Materials.apply_recursive(scene,"res://assets/generated/"+path)
		for child: Node in scene.find_children("*","MeshInstance3D",true,false):_inspect(child as MeshInstance3D,path)
		await process_frame
		scenes.append({"scene":path,"actual_bound_status":Geometry.get_status()})
		_check((scenes.back().actual_bound_status.load_failures as Dictionary).is_empty(),path,"mesh and permanent-boundary material bindings load without fallback errors")
		var retained: Array[Material]=[]
		_hold_materials(scene,retained)
		scene.queue_free();packed=null
		await process_frame;await process_frame
		retained.clear()
		_check(Geometry.get_status().bound_instances==0,path,"chapter/clip unload releases all rebuilt bindings")
		print("GEOMETRY_AUDIT_SCENE ",path," missing=",scenes.back().actual_bound_status.missing_instances)
	if with_levels:
		var gameplay: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/gameplay_manifest.json"))
		AudioScript.configure_catalog(gameplay.audio)
		for bus: String in ["Music","Effects"]:
			if AudioServer.get_bus_index(bus)<0:AudioServer.add_bus();AudioServer.set_bus_name(AudioServer.bus_count-1,bus)
		for entry: Dictionary in catalog.levels:
			var level: OriginalLevel=LevelScript.new();level.entry=entry
			level.data=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/"+str(entry.manifest_path)))
			level.gameplay=gameplay.levels[str(entry.id)];level.native_rules=gameplay.native_rules
			root.add_child(level)
			Geometry.set_enabled(true)
			await process_frame;await physics_frame;await physics_frame
			var owners: int=0;var faces: int=0;var quality: int=0
			for body: Node in level.find_children("NativeCollision","StaticBody3D",true,false):
				if not body.has_meta("native_triangle_count"):continue
				owners+=1;faces+=int(body.get_meta("active_triangle_count",0))
				quality+=1 if bool(body.get_meta("geometry_quality_enhanced",false)) else 0
				_check(bool(body.get_meta("geometry_quality_enhanced",false)),str(entry.id)+"|"+str(body.get_meta("native_owner","")),"live terrain owner uses the exact rebuilt collision")
			levels.append({"level":entry.id,"terrain_owners":owners,"rebuilt_collision_owners":quality,
				"active_collision_triangles":faces,"geometry":Geometry.get_status()})
			_check((levels.back().geometry.load_failures as Dictionary).is_empty(),str(entry.id),"live chapter has no mesh or boundary material load failures")
			var retained: Array[Material]=[]
			_hold_materials(level,retained)
			level.queue_free();await process_frame;await process_frame
			retained.clear()
	var manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(manifest_path)) if FileAccess.file_exists(manifest_path) else {}
	var unchanged: Array[Dictionary]=[]
	for path: String in manifest.get("resources",{}):
		var item: Dictionary=manifest.resources[path]
		if int(item.get("triangles",0))==int(item.get("source_triangles",-1)) and float(item.get("max_curvature_displacement",0.0))<0.0000001:
			unchanged.append({"path":path,"group":item.get("source_group"),"record":item.get("source_record"),
				"owner_classes":item.get("owner_classes",[]),"triangles":item.get("triangles",0)})
	var report: Dictionary={"schema_version":1,"manifest":manifest_path,"manifest_sha256":FileAccess.get_sha256(manifest_path),"checks":checks,"failures":failures,
		"scenes":scenes,"live_levels":levels,"inspected_unique_geometry":inspected_resources.size(),
		"morph_surface_targets_inspected":morph_targets,"unchanged_planar_meshes":unchanged,
		"offline_summary":manifest.get("summary",{}),
		"final_resource_status":Geometry.get_status(),"complete_binding_coverage":failures.is_empty() and scenes.size()==paths.size(),
		"artistic_quality_verified":false,"note":"Geometry, morph, LOD and collision correspondence; visual review is separate."}
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file:=FileAccess.open(output,FileAccess.WRITE)
	if file==null:push_error("Cannot save geometry audit");quit(1);return
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("GEOMETRY_AUDIT ",JSON.stringify({"checks":checks,"failures":failures.size(),"scenes":scenes.size(),"report":output}))
	quit(0 if failures.is_empty() else 1)
