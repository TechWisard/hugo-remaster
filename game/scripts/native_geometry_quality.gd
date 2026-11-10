class_name NativeGeometryQuality
extends RefCounted
## Optional, offline rebuilt meshes. Live instances retain native actions,
## material phase and morph weights; a missing or incompatible local mesh keeps
## the complete original. The cache never owns unloaded chapter GPU resources.

const DEFAULT_MANIFEST: String = "res://assets/hd/models/geometry_pack.json"
const SOURCE_PREFIX: String = "res://assets/generated/"
const WEIGHTS_META: StringName = &"hugo_geometry_source_weights"
const LODS_META: StringName = &"hugo_geometry_lods"
const BINDING_META: StringName = &"hugo_material_animation"
const CLOSURE_META: StringName = &"hugo_boundary_closure"
static var _enabled: bool = true
static var _attempted: bool = false
static var _manifest: Dictionary = {}
static var _base: String = ""
static var _bindings: Dictionary = {}
static var _cache: Dictionary = {}
static var _failures: Dictionary = {}
static var _scene_mesh_entries: Dictionary = {}
static var _cleanup_pending: bool = false


static func load_manifest(path: String = DEFAULT_MANIFEST) -> bool:
	_attempted = true
	_manifest = {}
	_base = path.get_base_dir()
	_failures.clear()
	_scene_mesh_entries.clear()
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1 \
		or not parsed.get("meshes") is Dictionary or not parsed.get("instances") is Dictionary:
		_failures[path] = "invalid_manifest"
		return false
	_manifest = parsed
	for key: String in _manifest.meshes:
		var separator: int = key.find("|")
		if separator >= 0:
			var scene: String = key.substr(0, separator)
			if not _scene_mesh_entries.has(scene):
				_scene_mesh_entries[scene] = {}
			_scene_mesh_entries[scene][key.substr(separator + 1)] = _manifest.meshes[key]
	for binding: Dictionary in _bindings.values():
		var instance: MeshInstance3D = (binding.instance as WeakRef).get_ref() as MeshInstance3D
		if instance != null:
			binding.entry = _entry(binding.scene_path, str(instance.name), binding.source as Mesh)
			_apply(instance, binding)
	return true


static func is_enabled() -> bool:
	return _enabled


static func set_enabled(value: bool) -> void:
	_ensure_manifest()
	_enabled = value
	_prune()
	for binding: Dictionary in _bindings.values():
		var instance: MeshInstance3D = (binding.instance as WeakRef).get_ref() as MeshInstance3D
		if instance != null:
			_apply(instance, binding)


static func apply_instance(instance: MeshInstance3D, changed: Callable, scene_path: String = "",
		boundary_material_factory: Callable = Callable()) -> void:
	if instance == null or instance.mesh == null:
		return
	_ensure_manifest()
	var id: int = instance.get_instance_id()
	if _bindings.has(id) and (_bindings[id].instance as WeakRef).get_ref() == instance:
		return
	var source: Mesh = instance.mesh
	var path: String = scene_path
	if path.is_empty():
		path = source.resource_path.get_slice("::", 0)
	path = path.trim_prefix(SOURCE_PREFIX)
	# Procedural gameplay fixtures and the clean-checkout demonstration are not
	# source campaign assets and must not be counted as missing remaster meshes.
	if not path.ends_with(".glb"):
		return
	var binding: Dictionary = {"instance": weakref(instance), "source": source,
		"scene_path": path, "changed": changed, "enhanced": false,
		"boundary_material_factory": boundary_material_factory,
		"entry": _entry(path, str(instance.name), source), "fallback_reason": ""}
	_bindings[id] = binding
	_apply(instance, binding)
	_schedule_cleanup()


static func get_original_mesh(instance: MeshInstance3D) -> Mesh:
	var binding: Dictionary = _bindings.get(instance.get_instance_id(), {})
	if not binding.is_empty() and (binding.instance as WeakRef).get_ref() == instance:
		return binding.source as Mesh
	return instance.mesh


static func is_instance_enhanced(instance: MeshInstance3D) -> bool:
	var binding: Dictionary = _bindings.get(instance.get_instance_id(), {})
	return not binding.is_empty() and (binding.instance as WeakRef).get_ref() == instance \
		and bool(binding.get("enhanced", false))


static func get_binding_report(instance: MeshInstance3D) -> Dictionary:
	var binding: Dictionary = _bindings.get(instance.get_instance_id(), {})
	if binding.is_empty() or (binding.instance as WeakRef).get_ref() != instance:
		return {"bound":false}
	var entry: Dictionary = binding.entry
	return {"bound":true,"enhanced":bool(binding.enhanced),"scene_path":str(binding.scene_path),
		"source_mesh":(binding.source as Mesh).resource_name,
		"replacement_path":_base.path_join(str(entry.get("path",""))) if not entry.is_empty() else "",
		"source_group":entry.get("source_group",-1),"source_record":entry.get("source_record",-1),
		"fallback_reason":binding.get("fallback_reason",""),
		"mutable_attribute_copy":instance.mesh.resource_path.is_empty() and bool(binding.enhanced)}


static func get_status() -> Dictionary:
	_ensure_manifest()
	_prune()
	var enhanced: int = 0
	var reasons: Dictionary = {}
	var vertices: int = 0
	var triangles: int = 0
	var mutable_vertices: int = 0
	var mutable_instances: int = 0
	var live_meshes: Dictionary = {}
	var collision_triangles: int = 0
	var boundary_instances: int = 0
	var boundary_triangles: int = 0
	for binding: Dictionary in _bindings.values():
		var instance: MeshInstance3D = (binding.instance as WeakRef).get_ref() as MeshInstance3D
		if instance == null:
			continue
		var closure: MeshInstance3D = instance.get_node_or_null("RemasterBoundaryClosure") as MeshInstance3D
		if closure != null and closure.mesh != null:
			boundary_instances += 1
			boundary_triangles += closure.mesh.surface_get_array_index_len(0) / 3
		if bool(binding.enhanced):
			enhanced += 1
			var mesh: Mesh = instance.mesh
			if not live_meshes.has(mesh.get_instance_id()):
				live_meshes[mesh.get_instance_id()] = true
				for surface: int in range(mesh.get_surface_count()):
					vertices += mesh.surface_get_array_len(surface)
					triangles += mesh.surface_get_array_index_len(surface) / 3
				collision_triangles += (mesh.get_meta("hugo_collision_surface_types", PackedInt32Array()) as PackedInt32Array).size()
			var mutable_here: bool = false
			for material_binding: Dictionary in instance.get_meta(BINDING_META, []):
				if bool(material_binding.get("mutable", false)):
					mutable_vertices += (material_binding.ids as PackedInt32Array).size()
					mutable_here = true
			if mutable_here:
				mutable_instances += 1
		elif _enabled:
			var reason: String = str(binding.get("fallback_reason", "missing_source"))
			reasons[reason] = int(reasons.get(reason, 0)) + 1
	return {"available": not _manifest.is_empty(), "enabled": _enabled,
		"manifest_complete_campaign": bool(_manifest.get("complete_campaign", false)),
		"semantic_stage_enabled": bool(_manifest.get("semantic_stage_enabled", false)),
		"bound_instances": _bindings.size(), "enhanced_instances": enhanced,
		"missing_instances": _bindings.size() - enhanced if _enabled else 0,
		"unique_live_meshes": live_meshes.size(), "resident_vertices": vertices,
		"resident_triangles": triangles, "collision_triangles": collision_triangles,
		"permanent_boundary_instances": boundary_instances, "permanent_boundary_triangles": boundary_triangles,
		"mutable_attribute_instances": mutable_instances, "mutable_attribute_vertices": mutable_vertices,
		"fallback_reasons": reasons, "load_failures": _failures.duplicate(),
		"artistic_quality_verified": false}


static func collision_for_owner(owner_visual: Node3D) -> Dictionary:
	## Local-space exact support geometry. Partial owner replacement is rejected
	## so an unrepresented native wall/hazard can never silently disappear.
	var faces := PackedVector3Array()
	var types := PackedInt32Array()
	var found: bool = false
	for child: Node in owner_visual.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = child as MeshInstance3D
		if bool(instance.get_meta(CLOSURE_META, false)):
			continue
		if instance.mesh == null:
			continue
		if not is_instance_enhanced(instance) or not bool(instance.mesh.get_meta("hugo_collision_complete", false)):
			return {}
		var mesh_faces: PackedVector3Array = instance.mesh.get_meta("hugo_collision_faces", PackedVector3Array())
		var mesh_types: PackedInt32Array = instance.mesh.get_meta("hugo_collision_surface_types", PackedInt32Array())
		if mesh_faces.size() != mesh_types.size() * 3:
			return {}
		var transform: Transform3D = owner_visual.global_transform.affine_inverse() * instance.global_transform
		for point: Vector3 in mesh_faces:
			faces.append(transform * point)
		types.append_array(mesh_types)
		found = true
	return {"faces": faces, "surface_types": types} if found and not faces.is_empty() else {}


static func _entry(scene_path: String, node_name: String, source: Mesh) -> Dictionary:
	var instance_key: String = scene_path + "|" + node_name
	var instances: Dictionary = _manifest.get("instances", {})
	if instances.has(instance_key):
		return instances[instance_key]
	var meshes: Dictionary = _manifest.get("meshes", {})
	var exact: String = scene_path + "|" + source.resource_name
	if meshes.has(exact):
		return meshes[exact]
	# Godot prefixes embedded mesh resource names with the GLB basename. Node
	# names and the offline manifest retain the source mesh's original name.
	var imported_prefix: String = scene_path.get_file().get_basename() + "_"
	var normalized: String = scene_path + "|" + source.resource_name.trim_prefix(imported_prefix)
	if meshes.has(normalized):
		return meshes[normalized]
	# Level scenes instead use their authored root label, e.g. S05_TheBeach.
	# Accept only one exact source-name suffix within this GLB. Ambiguous names
	# retain the source, rather than choosing a possibly unrelated model.
	var matching: Dictionary = {}
	for name: String in _scene_mesh_entries.get(scene_path, {}):
		if source.resource_name.ends_with("_" + name):
			if not matching.is_empty():
				return {}
			matching = _scene_mesh_entries[scene_path][name]
	return matching


static func _replacement(entry: Dictionary, source: Mesh) -> Mesh:
	var cached: Mesh = _resource(entry)
	if cached == null:
		return null
	var path: String = cached.resource_path
	if cached.get_surface_count() != source.get_surface_count() \
		or cached.get_blend_shape_count() != source.get_blend_shape_count():
		_failures[path] = "incompatible_surfaces_or_morphs"
		return null
	var expected: Array = entry.get("source_index_counts", [])
	if not expected.is_empty():
		if expected.size() != source.get_surface_count():
			_failures[path] = "incompatible_source_index_counts"
			return null
		for surface: int in range(expected.size()):
			if int(expected[surface]) != source.surface_get_array_index_len(surface):
				_failures[path] = "incompatible_source_index_counts"
				return null
	for shape: int in range(source.get_blend_shape_count()):
		if cached.get_blend_shape_name(shape) != source.get_blend_shape_name(shape):
			_failures[path] = "incompatible_morph_names"
			return null
	return cached


static func _resource(entry: Dictionary) -> Mesh:
	var relative: String = str(entry.get("path", ""))
	if relative.is_empty() or relative.is_absolute_path() or ":" in relative \
		or "\\" in relative or ".." in relative.split("/"):
		return null
	var path: String = _base.path_join(relative)
	var cached: Mesh = (_cache[path] as WeakRef).get_ref() as Mesh if _cache.has(path) else null
	if cached == null and not _failures.has(path):
		if not ResourceLoader.exists(path, "ArrayMesh"):
			_failures[path] = "missing_resource"
			return null
		cached = ResourceLoader.load(path, "ArrayMesh") as Mesh
		if cached == null:
			_failures[path] = "invalid_resource"
			return null
		_cache[path] = weakref(cached)
	return cached


static func _ensure_closure(instance: MeshInstance3D, binding: Dictionary) -> void:
	# Critical map completions are independent of the cosmetic quality setting.
	# They reuse the prepared source material, so its texture-quality binding is
	# still shared. A single exact visible triangle collider serves both modes.
	var key: String = str(binding.scene_path) + "|" + str(instance.name)
	var entry: Dictionary = (_manifest.get("closures", {}) as Dictionary).get(key, {})
	var old: MeshInstance3D = instance.get_node_or_null("RemasterBoundaryClosure") as MeshInstance3D
	if entry.is_empty():
		if old != null and bool(old.get_meta(CLOSURE_META, false)):
			instance.remove_child(old)
			old.queue_free()
		return
	var surface: int = int(entry.get("source_surface_index", -1))
	if surface < 0 or surface >= instance.mesh.get_surface_count():
		_failures[key] = "invalid_boundary_source_surface"
		return
	var path: String = _base.path_join(str(entry.get("path", "")))
	if old != null and old.mesh != null and old.mesh.resource_path == path:
		if not entry.has("material_source_mesh_name"):
			old.material_override = instance.get_active_material(surface)
		return
	var mesh: Mesh = _resource(entry)
	if mesh == null or mesh.get_surface_count() != 1 or mesh.get_blend_shape_count() != 0:
		_failures[key] = "missing_or_invalid_permanent_boundary"
		return
	var faces: PackedVector3Array = mesh.get_meta("hugo_collision_faces", PackedVector3Array())
	var types: PackedInt32Array = mesh.get_meta("hugo_collision_surface_types", PackedInt32Array())
	if faces.is_empty() or faces.size() != types.size() * 3:
		_failures[key] = "invalid_boundary_collision"
		return
	if old != null:
		instance.remove_child(old)
		old.queue_free()
	var visual := MeshInstance3D.new()
	visual.name = "RemasterBoundaryClosure"
	visual.mesh = mesh
	visual.material_override = instance.get_active_material(surface)
	if entry.has("material_source_mesh_name"):
		var factory: Callable = binding.get("boundary_material_factory", Callable())
		var material: Material = factory.call(instance, entry) as Material if factory.is_valid() else null
		if material == null:
			_failures[key] = "missing_boundary_material_source"
		else:
			visual.material_override = material
	visual.set_meta(CLOSURE_META, true)
	visual.set_meta("boundary_kind", entry.get("kind", ""))
	var body := StaticBody3D.new()
	body.name = "PermanentBoundaryCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta("native_owner", str(entry.get("native_owner", "")))
	body.set_meta("native_surfaces", Array(types))
	body.set_meta(CLOSURE_META, true)
	body.set_meta("active_triangle_count", types.size())
	var collision := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	collision.shape = shape
	body.add_child(collision)
	visual.add_child(body)
	instance.add_child(visual)


static func _apply(instance: MeshInstance3D, binding: Dictionary) -> void:
	_ensure_closure(instance, binding)
	var target: Mesh = binding.source as Mesh
	var enhanced: bool = false
	binding.fallback_reason = ""
	if _enabled:
		if (binding.entry as Dictionary).is_empty():
			binding.fallback_reason = "source_not_in_pack"
		else:
			var replacement: Mesh = _replacement(binding.entry, target)
			if replacement != null:
				target = replacement
				enhanced = true
			else:
				binding.fallback_reason = "replacement_unavailable_or_incompatible"
	# Native material animation may have made a private GPU attribute clone of
	# this target. Reassign only on a real mode/resource change, never every tick.
	var previous_path: String = str(binding.get("applied_path", ""))
	var target_path: String = target.resource_path if enhanced else "original"
	if bool(binding.enhanced) == enhanced and previous_path == target_path:
		return
	if not bool(binding.enhanced) and not enhanced and previous_path.is_empty():
		binding.applied_path = target_path
		return
	var materials: Array[Material] = []
	for surface: int in range(instance.mesh.get_surface_count()):
		materials.append(instance.get_active_material(surface))
	var morphs := PackedFloat32Array()
	for shape: int in range(instance.mesh.get_blend_shape_count()):
		morphs.append(instance.get_blend_shape_value(shape))
	var phase: float = 0.0
	var material_bindings: Array = instance.get_meta(BINDING_META, [])
	if not material_bindings.is_empty():
		phase = maxf(float(material_bindings[0].get("last_phase", 0.0)), 0.0)
	instance.mesh = target
	for surface: int in range(materials.size()):
		instance.set_surface_override_material(surface, materials[surface])
	binding.enhanced = enhanced
	binding.applied_path = target_path
	var changed: Callable = binding.changed
	if changed.is_valid():
		changed.call(instance, phase)
	for shape: int in range(morphs.size()):
		instance.set_blend_shape_value(shape, morphs[shape])
	if instance.is_inside_tree():
		instance.get_tree().call_group("native_geometry_owners", "native_geometry_changed", instance)


static func _ensure_manifest() -> void:
	if not _attempted:
		load_manifest()


static func _prune() -> void:
	for id: int in _bindings.keys():
		if (_bindings[id].instance as WeakRef).get_ref() == null:
			_bindings.erase(id)
	for path: String in _cache.keys():
		if (_cache[path] as WeakRef).get_ref() == null:
			_cache.erase(path)


static func _schedule_cleanup() -> void:
	if _cleanup_pending:
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_cleanup_pending = true
	tree.create_timer(2.0, true, false, true).timeout.connect(_cleanup)


static func _cleanup() -> void:
	_cleanup_pending = false
	_prune()
	if not _bindings.is_empty():
		_schedule_cleanup()
