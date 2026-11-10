extends SceneTree
## Verifies complete imported CEmitter coverage and unchanged native simulation.
## With imported assets: --headless --script res://tests/native_effects_test.gd
## Without assets, still verifies the safe empty-world and unknown-art fallback.

const Effects = preload("res://scripts/native_effects.gd")
const Profiles = preload("res://scripts/native_effect_profiles.gd")
const CHAPTERS: PackedStringArray = ["g006", "g017", "g027", "g036", "g046", "g055", "g059", "g069"]
var checks: int = 0
var failures: Array[String] = []
var camera: Camera3D


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)


func _fixture(data: Dictionary, enhanced: bool) -> NativeEffects:
	var effects: NativeEffects = Effects.new()
	effects.source = data
	root.add_child(effects)
	effects.set_physics_process(false)
	effects.set_enhanced(enhanced)
	return effects


func _json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary


func _run() -> void:
	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0.0, 0.0, 12.0)
	camera.current = true
	var empty: NativeEffects = _fixture({}, true)
	_check(empty.active_particle_count() == 0 and empty.get_quality_coverage().loaded_definitions == 0, "empty checkout has no required FX bitmap dependency")
	empty._physics_process(1.0 / 60.0)
	empty.reset_native_world()
	empty.set_enhanced(false)
	empty.free()
	var unknown := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	unknown.fill(Color(0.21, 0.57, 0.83, 0.69))
	_check(int(Profiles.identify(ImageTexture.create_from_image(unknown)).profile) == -1, "unrecognized future art is reported, never silently assigned a wrong shape")
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("NATIVE_EFFECTS_TEST: PASS checks=", checks, " imported_campaign=absent")
		quit(0 if failures.is_empty() else 1)
		return
	var total_definitions: int = 0
	var total_anchors: int = 0
	var total_frames: int = 0
	var unique_frames: Dictionary = {}
	var coverage: Dictionary = {}
	for chapter: String in CHAPTERS:
		var data: Dictionary = _json("res://assets/generated/levels/" + chapter + ".json")
		var hq: NativeEffects = _fixture(data, true)
		var original: NativeEffects = _fixture(data, false)
		var status: Dictionary = hq.get_quality_coverage()
		coverage[chapter] = status
		total_definitions += int(status.definition_count)
		total_anchors += int(status.anchor_count)
		total_frames += int(status.source_texture_files)
		for identity: String in status.frame_identities:
			unique_frames[identity] = true
		_check(status.loaded_definitions == status.definition_count and status.enhanced_definitions == status.definition_count, chapter + " replaces every emitter definition")
		_check(status.missing_profiles.is_empty() and status.missing_definitions.is_empty() and not status.surface_source_bitmap_sampled, chapter + " has no low-resolution surface fallback in enhanced mode")
		_check(status.frame_sequence_preserved, chapter + " retains complete source sprite frame sequence")
		hq._random.seed = 781923
		original._random.seed = 781923
		var expected_random := RandomNumberGenerator.new()
		expected_random.seed = 781923
		for key: String in hq._definitions:
			var info: Dictionary = hq._definitions[key]
			var reference: Dictionary = original._definitions[key]
			hq._spawn(info, hq._pools[info.pool], Transform3D.IDENTITY, camera)
			original._spawn(reference, original._pools[reference.pool], Transform3D.IDENTITY, camera)
			for draw: int in range(10):
				expected_random.randf()
			_check(hq._random.state == expected_random.state and original._random.state == expected_random.state, key + " consumes exactly the original ten random draws")
			var a: Dictionary = hq._pools[info.pool].active.back()
			var b: Dictionary = original._pools[reference.pool].active.back()
			_check(_same_simulation(a, b), key + " enhanced and original initial particles are identical")
			var material: ShaderMaterial = (a.node as MeshInstance3D).material_override as ShaderMaterial
			_check(not material.shader.code.contains("sprite_texture") and int(material.get_shader_parameter("effect_profile")) >= 0, key + " uses the analytic production surface")
			var profile: int = int(info.profiles[int(a.frame)])
			if profile == Profiles.Kind.HEALTH_ORB or profile == Profiles.Kind.STONE:
				var mesh: Mesh = (a.node as MeshInstance3D).mesh
				_check(not mesh is QuadMesh and mesh.get_aabb().size.z > 0.6, key + " opaque particles have actual three-dimensional geometry")
				var before_transform: Transform3D = (a.node as MeshInstance3D).global_transform
				hq.set_enhanced(false)
				_check((a.node as MeshInstance3D).mesh is QuadMesh, key + " original mode restores source billboard geometry")
				hq.set_enhanced(true)
				_check((a.node as MeshInstance3D).mesh == mesh and (a.node as MeshInstance3D).global_transform == before_transform, key + " hot quality switch reuses solid mesh without moving the particle")
		for key: String in hq._pools:
			for tick: int in range(8):
				hq._update_pool(hq._pools[key], 1.0 / 60.0, camera)
				original._update_pool(original._pools[key], 1.0 / 60.0, camera)
			var active: Array = hq._pools[key].active
			var old_active: Array = original._pools[key].active
			_check(active.size() == old_active.size() and (active.is_empty() or _same_simulation(active[0], old_active[0])), key + " preserves drag, gravity, position, spin, size, color and lifetime updates")
		var before_count: int = hq.active_particle_count()
		var before_rng: int = hq._random.state
		hq.set_enhanced(false)
		hq.set_enhanced(true)
		_check(hq.active_particle_count() == before_count and hq._random.state == before_rng, chapter + " live quality changes preserve particles and random stream")
		hq.reset_native_world()
		_check(hq.active_particle_count() == 0, chapter + " checkpoint reset releases every particle")
		hq.free()
		original.free()
	_check(total_definitions == 69 and total_anchors == 1109, "all 69 definitions and 1109 campaign anchors are covered")
	_check(total_frames == 42 and unique_frames.size() == 7, "all 42 sprite aliases map to seven independently identified surfaces")
	_test_frame_sequence_and_pool()
	var report: Dictionary = {"checks": checks, "failures": failures, "definitions": total_definitions, "anchors": total_anchors,
		"source_texture_files": total_frames, "unique_source_frames": unique_frames.size(), "chapters": coverage}
	var output := FileAccess.open("user://native_effects_result.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "  "))
	output.close()
	print("NATIVE_EFFECTS_TEST: ", "PASS" if failures.is_empty() else "FAIL", " checks=", checks,
		" definitions=", total_definitions, " anchors=", total_anchors, " source_files=", total_frames, " unique_surfaces=", unique_frames.size())
	camera.free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _same_simulation(a: Dictionary, b: Dictionary) -> bool:
	for property: String in ["position", "velocity", "remaining", "lifetime", "start_size", "end_size", "spin", "angle", "start_color", "end_color", "frame", "tint"]:
		if a[property] != b[property]:
			return false
	return (a.node as MeshInstance3D).global_transform == (b.node as MeshInstance3D).global_transform


func _test_frame_sequence_and_pool() -> void:
	var data: Dictionary = _json("res://assets/generated/levels/g006.json")
	var definition: Dictionary = data.effect_definitions.g006_r0156.duplicate(true)
	definition.sprite.frames = [data.effect_definitions.g006_r0240.sprite.frames[0], data.effect_definitions.g006_r0242.sprite.frames[0]]
	var effects: NativeEffects = _fixture({"effect_definitions": {"sequence": definition}, "owners": []}, true)
	var info: Dictionary = effects._definitions.sequence
	var pool: Dictionary = effects._pools[info.pool]
	effects._spawn(info, pool, Transform3D.IDENTITY, camera)
	var particle: Dictionary = pool.active[0]
	particle.remaining = float(particle.lifetime) * 0.25
	effects._draw(particle, camera)
	var material: ShaderMaterial = (particle.node as MeshInstance3D).material_override as ShaderMaterial
	var tint: Color = material.get_shader_parameter("tint")
	_check(int(particle.frame) == 1 and int(material.get_shader_parameter("effect_profile")) == Profiles.Kind.RED_GLINT, "multi-frame fixture changes to the second source identity at its native lifetime phase")
	effects.set_enhanced(false)
	_check(material.get_shader_parameter("sprite_texture") == info.textures[1] and material.get_shader_parameter("tint") == tint, "live original mode restores the current frame and current tint immediately")
	effects.set_enhanced(true)
	_check(int(material.get_shader_parameter("effect_profile")) == Profiles.Kind.RED_GLINT and material.get_shader_parameter("tint") == tint, "live enhanced mode retains the current frame family and tint")
	effects.reset_native_world()
	var anchor := Node3D.new()
	root.add_child(anchor)
	effects._emitters = [{"source": {"effect_key": "sequence"}, "anchor": anchor, "is_player": false, "remainder": 0.0}]
	var maximum: int = 0
	for tick: int in range(180):
		effects._physics_process(1.0 / 60.0)
		maximum = maxi(maximum, effects.active_particle_count())
		if effects.active_particle_count() > int(pool.capacity):
			_check(false, "source pool budget exceeded")
			break
	_check(maximum == int(pool.capacity) and pool.active.size() + pool.free.size() == int(pool.capacity), "actual emission saturates and recycles the source pool without allocating extra nodes")
	anchor.hide()
	for tick: int in range(90):
		effects._physics_process(1.0 / 60.0)
	_check(effects.active_particle_count() == 0 and is_zero_approx(float(effects._emitters[0].remainder)), "inactive source anchor stops emission and existing particles expire")
	anchor.show()
	effects._physics_process(1.0 / 60.0)
	_check(effects.active_particle_count() > 0, "a reactivated source anchor reuses its pool")
	effects.reset_native_world()
	_check(effects.active_particle_count() == 0 and is_zero_approx(float(effects._emitters[0].remainder)), "checkpoint clears active particles and emission remainder")
	anchor.free()
	effects.free()
