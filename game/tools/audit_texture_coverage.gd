extends SceneTree
## Audit the complete local campaign, every exported player animation, every
## material frame, and the materials actually assigned by OriginalLevel.
## --strict fails on uncovered sources, legacy samplers or broken alpha/mips.
## --catalog-only skips live scenes; --report=PATH selects the JSON report.
## This verifies technical coverage, not the artistic quality of a redraw.

const Pack = preload("res://scripts/hd_texture_pack.gd")
const Materials = preload("res://scripts/native_materials.gd")
const ResourceData = preload("res://scripts/native_resource_data.gd")
const Level = preload("res://scripts/original_level.gd")
const BASE: String = "res://assets/generated/"
var _strict: bool = false
var _catalog_only: bool = false
var _output: String = "user://texture_coverage_report.json"
var _sources: Dictionary = {}
var _aliases: Dictionary = {}
var _canonical_by_runtime: Dictionary = {}
var _image_checks: Dictionary = {}
var _issues: Dictionary = {}
var _assets: Array[Dictionary] = []
var _levels: Array[Dictionary] = []
var _effects: Array[Dictionary] = []
var _materials: int = 0
var _frame_slots: int = 0
var _peak_image_bytes: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--strict":
			_strict = true
		elif argument == "--catalog-only":
			_catalog_only = true
		elif argument.begins_with("--report="):
			_output = argument.trim_prefix("--report=")
	Pack.set_enabled(true)
	var catalog: Dictionary = _read(BASE + "campaign.json")
	var animations: Dictionary = _read(BASE + "animation_manifest.json")
	var paths: Dictionary = {}
	for entry: Dictionary in catalog.get("levels", []):
		paths[str(entry.geometry_path)] = "chapter_geometry"
	for path: String in animations.get("files", {}):
		if path.ends_with(".glb"):
			paths[path] = "player_animation"
	if paths.is_empty():
		_issue("missing_campaign_assets", "", BASE)
	for path: String in paths:
		await _audit_glb(BASE + path, str(paths[path]))
	_audit_material_frames()
	if not _catalog_only:
		await _audit_live_scenes(catalog)
	var status: Dictionary = Pack.get_status()
	for key: String in status.manifest_errors:
		_issue("manifest:" + str(status.manifest_errors[key]), key, Pack.MANIFEST)
	var covered: int = 0
	var reviewed: int = 0
	for source: Dictionary in _sources.values():
		covered += int(int(source.replaced_uses) == int(source.uses))
		reviewed += int(str(source.visual_review) in ["approved", "reviewed"])
	var all_sources: Dictionary = _sources.duplicate()
	var effect_sources: Dictionary = {}
	var effect_definitions: int = 0
	var effect_anchors: int = 0
	for fx: Dictionary in _effects:
		effect_definitions += int(fx.definition_count)
		effect_anchors += int(fx.anchor_count)
		for key: String in fx.frame_identities:
			effect_sources[key] = true
			all_sources[key] = true
	var summary: Dictionary = {"unique_surface_sources": _sources.size(),
		"unique_effect_sources": effect_sources.size(), "unique_runtime_sources": all_sources.size(),
		"effect_definitions": effect_definitions, "effect_anchors": effect_anchors,
		"fully_replaced_surface_sources": covered, "bound_material_checks": _materials,
		"material_sequence_slots": _frame_slots, "glb_assets": _assets.size(),
		"live_chapters": _levels.size(), "effects_chapters": _effects.size(),
		"issue_types_and_sources": _issues.size(), "runtime_alias_sources": _aliases.size(),
		"recorded_visual_reviews": reviewed, "peak_resident_image_bytes": _peak_image_bytes,
		"technical_coverage_complete": not _sources.is_empty() and covered == _sources.size() and _issues.is_empty(),
		"artistic_quality_verified": false}
	var report: Dictionary = {"schema_version": 1, "kind": "actual_material_texture_coverage",
		"engine": Engine.get_version_info(), "created_utc": Time.get_datetime_string_from_system(true),
		"summary": summary, "pack_status": status, "sources": _sources,
		"runtime_keys": _aliases, "issues": _issues.values(), "assets": _assets,
		"live_levels": _levels, "effects": _effects,
		"limits": ["Resolution, mipmaps and coverage do not certify artistic quality.",
			"Resident image bytes exclude meshes, render targets and driver allocations.",
			"Analytical effects are audited independently from bitmap replacements."]}
	var output := FileAccess.open(_output, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write texture coverage report: " + _output)
		quit(1)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("TEXTURE_COVERAGE ", JSON.stringify(summary), " report=", _output)
	quit(1 if _strict and not bool(summary.technical_coverage_complete) else 0)


func _audit_glb(path: String, kind: String) -> void:
	var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		_issue("missing_glb", "", path)
		return
	var expected: Dictionary = _glb_material_keys(path)
	var node: Node = packed.instantiate()
	node.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(node)
	var before: int = _materials
	_prepare_and_audit(node, path, kind, expected)
	# Mesh override changes queue instance-shader updates in RenderingServer.
	# Let those finish before freeing the scene, including with the dummy driver.
	await process_frame
	var status: Dictionary = Pack.get_status()
	_peak_image_bytes = maxi(_peak_image_bytes, int(status.resident_image_bytes))
	_assets.append({"path": path.trim_prefix(BASE), "kind": kind,
		"bound_materials": _materials - before, "resident_image_bytes": status.resident_image_bytes})
	var retiring: Array[Material] = []
	_hold_materials(node, retiring)
	node.queue_free()
	await process_frame
	await process_frame
	retiring.clear()
	Pack.get_status() # Prune dead owners; the cache must not retain prior chapters.


func _prepare_and_audit(node: Node, context: String, kind: String, expected: Dictionary) -> void:
	var instance: MeshInstance3D = node as MeshInstance3D
	if instance != null and instance.mesh != null:
		for surface: int in range(instance.mesh.get_surface_count()):
			var source: BaseMaterial3D = instance.mesh.surface_get_material(surface) as BaseMaterial3D
			if source == null or source.albedo_texture == null:
				continue
			var material: Material = Materials.prepare_material(source, Materials.surface_has_vertex_colors(instance.mesh, surface))
			instance.set_surface_override_material(surface, material)
			_audit_material(instance.get_active_material(surface), str(expected.get(source.resource_name, "")),
				context + "/" + str(node.name) + ":" + str(surface), kind)
	for child: Node in node.get_children():
		_prepare_and_audit(child, context + "/" + str(node.name), kind, expected)


func _audit_material_frames() -> void:
	var manifest: Dictionary = _read(BASE + "material_animation_manifest.json")
	var visited: Dictionary = {}
	for id: String in manifest.get("materials", {}):
		var info: Dictionary = manifest.materials[id]
		var selector: int = (int(info.get("source_flags", 0)) >> 29) & 3
		for frame: Dictionary in info.get("texture_sequence", []):
			_frame_slots += 1
			var path: String = BASE + str(frame.get("path", ""))
			var identity: String = "%s:%d" % [path, selector]
			if visited.has(identity):
				continue
			visited[identity] = true
			var source: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
			if source == null:
				_issue("missing_animation_frame", "", path)
				continue
			var key: String = "%dx%d:%s" % [int(frame.width), int(frame.height), str(frame.payload_sha256)]
			var original := StandardMaterial3D.new()
			original.resource_name = id + "__hugo_blend_%d" % selector
			original.albedo_texture = source
			var material: Material = Materials.prepare_material(original, true)
			_audit_material(material, key, path, "material_animation_frame")


func _audit_live_scenes(catalog: Dictionary) -> void:
	for bus: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	var gameplay: Dictionary = _read(BASE + "gameplay_manifest.json")
	for entry: Dictionary in catalog.get("levels", []):
		var level: OriginalLevel = Level.new()
		level.process_mode = Node.PROCESS_MODE_DISABLED
		level.entry = entry
		level.data = _read(BASE + str(entry.manifest_path))
		level.gameplay = gameplay.get("levels", {}).get(str(entry.id), {})
		level.native_rules = gameplay.get("native_rules", {})
		root.add_child(level)
		await process_frame
		var before: int = _materials
		_audit_live_node(level, str(entry.id))
		if not level._ready_ok:
			_issue("chapter_initialization_failed", "", str(entry.id))
		var status: Dictionary = Pack.get_status()
		_peak_image_bytes = maxi(_peak_image_bytes, int(status.resident_image_bytes))
		_levels.append({"chapter": entry.id, "initialized": level._ready_ok,
			"bound_materials": _materials - before, "resident_image_bytes": status.resident_image_bytes})
		if level.effects != null:
			var fx: Dictionary = level.effects.get_quality_coverage()
			fx["chapter"] = entry.id
			_effects.append(fx)
			if int(fx.enhanced_definitions) != int(fx.definition_count) or not fx.missing_profiles.is_empty() \
					or not fx.missing_definitions.is_empty() or bool(fx.surface_source_bitmap_sampled):
				_issue("legacy_effect_surface", "", str(entry.id))
		var retiring: Array[Material] = []
		_hold_materials(level, retiring)
		level.queue_free()
		await process_frame
		await process_frame
		retiring.clear()
		Pack.get_status()


func _hold_materials(node: Node, materials: Array[Material]) -> void:
	# Headless Godot's dummy server queries queued instance uniforms during
	# teardown. Retain QA overrides until that queue drains; this also reproduces
	# a real rendering frame between closing one chapter and opening the next.
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh: MeshInstance3D = node as MeshInstance3D
		for surface: int in range(mesh.mesh.get_surface_count()):
			var material: Material = mesh.get_active_material(surface)
			if material != null:
				materials.append(material)
	for child: Node in node.get_children():
		_hold_materials(child, materials)


func _audit_live_node(node: Node, context: String) -> void:
	var instance: MeshInstance3D = node as MeshInstance3D
	if instance != null and instance.mesh != null:
		for surface: int in range(instance.mesh.get_surface_count()):
			var material: Material = instance.get_active_material(surface)
			if material == null:
				_issue("surface_without_material", "", context + "/" + str(node.name))
				continue
			if _texture(material) != null:
				_audit_material(material, "", context + "/" + str(node.name) + ":" + str(surface), "live_scene")
	for child: Node in node.get_children():
		_audit_live_node(child, context + "/" + str(node.name))


func _audit_material(material: Material, expected: String, context: String, kind: String) -> void:
	_materials += 1
	var report: Dictionary = Pack.get_binding_report(material, false)
	if not bool(report.get("bound", false)):
		_issue("texture_bypasses_replacement_adapter", expected, context)
		return
	var runtime_key: String = str(report.runtime_key)
	if expected.is_empty():
		expected = str(_canonical_by_runtime.get(runtime_key, report.source_key))
	elif not _canonical_by_runtime.has(runtime_key):
		_canonical_by_runtime[runtime_key] = expected
	elif _canonical_by_runtime[runtime_key] != expected:
		_issue("ambiguous_import_pixel_identity", expected, context)
	if expected != runtime_key:
		if not _aliases.has(expected):
			_aliases[expected] = []
		if not runtime_key in _aliases[expected]:
			_aliases[expected].append(runtime_key)
	if not _sources.has(expected):
		_sources[expected] = {"source_size": report.source_size, "uses": 0, "replaced_uses": 0,
			"kinds": [], "samplers": [], "contexts": [], "replacement_path": report.replacement_path,
			"bound_size": report.get("bound_size", []), "authoring": report.authoring,
			"visual_review": report.visual_review}
	var row: Dictionary = _sources[expected]
	row.uses = int(row.uses) + 1
	row.replaced_uses = int(row.replaced_uses) + int(bool(report.replaced))
	if not kind in row.kinds:
		row.kinds.append(kind)
	if not report.sampler in row.samplers:
		row.samplers.append(report.sampler)
	if row.contexts.size() < 8:
		row.contexts.append(context)
	if not bool(report.replaced):
		_issue("legacy_source_fallback:" + str(report.fallback_reason), expected, context)
	if str(report.source_key) != expected:
		_issue("runtime_alias_not_installed", expected, context)
	if str(report.sampler) != "linear_mipmap_anisotropic":
		_issue("legacy_or_unknown_sampler", expected, context)
	var bound: Texture2D = _texture(material)
	if bound == null:
		_issue("bound_texture_missing", expected, context)
		return
	var actual: Dictionary = _inspect_image(bound)
	if not bool(actual.get("mipmaps", false)):
		_issue("missing_mipmap_chain", expected, context)
	if bool(report.replaced):
		var original: Texture2D = Pack.get_bound_source(material)
		var original_info: Dictionary = _inspect_image(original)
		if bound.get_width() <= original.get_width() or bound.get_height() <= original.get_height():
			_issue("replacement_resolution_not_increased", expected, context)
		if bool(actual.get("invisible", false)) and not bool(original_info.get("invisible", false)):
			_issue("replacement_is_fully_transparent", expected, context)
		if int(original_info.get("alpha", -1)) == Image.ALPHA_NONE and int(actual.get("alpha", -1)) != Image.ALPHA_NONE:
			_issue("opaque_source_became_transparent", expected, context)
		row["mipmaps"] = actual.get("mipmaps", false)
		row["alpha_mode"] = actual.get("alpha", -1)
		row["resident_image_bytes"] = actual.get("bytes", 0)


func _texture(material: Material) -> Texture2D:
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).albedo_texture
	if material is ShaderMaterial:
		var texture: Texture2D = (material as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D
		return texture if texture != null else (material as ShaderMaterial).get_shader_parameter("source_texture") as Texture2D
	return null


func _inspect_image(texture: Texture2D) -> Dictionary:
	var id: int = texture.get_instance_id()
	if _image_checks.has(id):
		return _image_checks[id]
	var image: Image = texture.get_image()
	var result: Dictionary = {"mipmaps": image != null and image.has_mipmaps()}
	if image != null:
		result["bytes"] = image.get_data_size()
		if image.is_compressed():
			image = image.duplicate() as Image
			image.decompress()
		result["alpha"] = image.detect_alpha()
		result["invisible"] = image.is_invisible()
	_image_checks[id] = result
	return result


func _glb_material_keys(path: String) -> Dictionary:
	# Read only embedded PNG payloads. This supplies canonical raw identities
	# independently of Godot's alpha-border processing or resource names.
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	if file.get_32() != 0x46546c67 or file.get_32() != 2:
		return {}
	file.get_32()
	var json_size: int = file.get_32()
	if file.get_32() != 0x4e4f534a:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_buffer(json_size).get_string_from_utf8())
	if not parsed is Dictionary:
		return {}
	file.get_32()
	if file.get_32() != 0x004e4942:
		return {}
	var binary_offset: int = file.get_position()
	var images: Dictionary = {}
	var result: Dictionary = {}
	for material: Dictionary in parsed.get("materials", []):
		var slot: int = int(material.get("pbrMetallicRoughness", {}).get("baseColorTexture", {}).get("index", -1))
		if slot < 0:
			continue
		var index: int = int(parsed.textures[slot].source)
		if not images.has(index):
			var descriptor: Dictionary = parsed.images[index]
			if not descriptor.has("bufferView") or str(descriptor.get("mimeType", "")) != "image/png":
				continue
			var view: Dictionary = parsed.bufferViews[int(descriptor.bufferView)]
			file.seek(binary_offset + int(view.get("byteOffset", 0)))
			var image := Image.new()
			if image.load_png_from_buffer(file.get_buffer(int(view.byteLength))) != OK:
				continue
			image.convert(Image.FORMAT_RGBA8)
			var hash := HashingContext.new()
			hash.start(HashingContext.HASH_SHA256)
			hash.update(image.get_data())
			images[index] = "%dx%d:%s" % [image.get_width(), image.get_height(), hash.finish().hex_encode()]
		result[str(material.get("name", ""))] = images[index]
	return result


func _read(path: String) -> Dictionary:
	var value: Variant = ResourceData.read(path)
	return value as Dictionary if value is Dictionary else {}


func _issue(reason: String, key: String, context: String) -> void:
	var identity: String = reason + ":" + key
	if not _issues.has(identity):
		_issues[identity] = {"reason": reason, "source_key": key, "count": 0, "contexts": []}
	var item: Dictionary = _issues[identity]
	item.count = int(item.count) + 1
	if item.contexts.size() < 8:
		item.contexts.append(context)
