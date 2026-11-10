extends SceneTree
## Real physics/input/render integration for the independent shadow and blink.
## The generated fixture works without game assets; imported Hugo is optional.
## GPU A/B screenshots depict this QA fixture, not gameplay.

const PlayerScript = preload("res://scripts/player.gd")
const MaterialsScript = preload("res://scripts/native_materials.gd")
const LevelScript = preload("res://scripts/original_level.gd")
const GeometryScript = preload("res://scripts/native_geometry_quality.gd")
const FIXTURE_DIRECTORY: String = "user://native_shadow_test"
const SOURCE_MODEL: String = "res://assets/generated/hugo.glb"
const COEFFICIENT: float = 0.44999998062849045

class ShadowWorld extends Node3D:
	var health: int = 10
	var player: HugoPlayer
	var floor_body: StaticBody3D

var checks: int = 0
var failures: Array[String] = []
var skipped: Array[String] = []
var evidence: Array[Dictionary] = []
var report_path: String = "user://native_shadow_test.json"
var capture_prefix: String = ""
var fixture_only: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shadow-report="):
			report_path = argument.trim_prefix("--shadow-report=")
		elif argument.begins_with("--shadow-capture-prefix="):
			capture_prefix = argument.trim_prefix("--shadow-capture-prefix=")
		elif argument == "--shadow-fixture-only":
			fixture_only = true
	RemasterInput.configure()
	_release()
	root.size = Vector2i(800, 600)
	root.content_scale_size = Vector2i(800, 600)
	_create_fixture_assets()
	# Exact source-quad assertions require the original imported mesh. Enhanced
	# terrain support is exercised separately below, with all assertions intact.
	GeometryScript.set_enabled(false)
	await _exercise(FIXTURE_DIRECTORY.path_join("hugo.glb"), "fixture")
	await _reversed_floor_support()
	if not fixture_only and ResourceLoader.exists(SOURCE_MODEL, "PackedScene") \
			and FileAccess.file_exists("res://assets/generated/animation_manifest.json"):
		await _exercise(SOURCE_MODEL, "source")
		GeometryScript.set_enabled(true)
		await _beach_support()
	else:
		skipped.append("Imported Hugo/shadow: unavailable or fixture-only requested.")
		GeometryScript.set_enabled(true)
	_release()
	var result: Dictionary = {"kind": "native_shadow_scene_input_render_regression", "checks": checks,
		"failures": failures, "skipped": skipped, "evidence": evidence,
		"display": DisplayServer.get_name(), "engine": Engine.get_version_info(),
		"screenshots_are_gameplay": false, "passed": failures.is_empty()}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		_check(false, "report can be written")
	else:
		file.store_string(JSON.stringify(result, "\t"))
		file.close()
	print("NATIVE_SHADOW checks=", checks, " failures=", JSON.stringify(failures), " report=", report_path)
	quit(0 if failures.is_empty() else 1)


func _exercise(model_path: String, label: String) -> void:
	var world: ShadowWorld = _world(model_path)
	root.add_child(world)
	await _ticks(10)
	var player: HugoPlayer = world.player
	var visual: HugoPlayerVisual = player._visual
	var presentation: NativePlayerPresentation = visual.native_presentation
	_check(player.using_native_movement and visual.using_original_animation, label + ": production native player and animation pipeline load")
	_check(presentation != null and presentation.using_source_shadow, label + ": player creation attaches the independent shadow scene")
	if presentation == null or not presentation.using_source_shadow:
		world.free()
		return
	var meshes: Array[MeshInstance3D] = _meshes(presentation.shadow)
	_check(meshes.size() == 1, label + ": independent shadow has one mesh")
	if meshes.is_empty():
		world.free()
		return
	var mesh: MeshInstance3D = meshes[0]
	var original_vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var material: Material = mesh.get_active_material(0)
	_check(original_vertices.size() == 4 and mesh.mesh.surface_get_array_index_len(0) == 6,
		label + ": authored four-vertex/two-triangle quad survives import")
	_check(MaterialsScript.blend_selector(material) == 2 and material is ShaderMaterial,
		label + ": inverse-multiply source material reaches the runtime adapter")
	_check(absf(mesh.mesh.get_aabb().size.x - 2.26) < 0.002 and absf(mesh.mesh.get_aabb().size.z - 2.26) < 0.002,
		label + ": raw source quad keeps its 2.26 m size")
	_check(player.is_on_floor() and presentation.support_valid and absf(presentation.support_height) < 0.002,
		label + ": actual collision support is the fixture floor at y=0")
	_check(absf(presentation.global_position.y) < 0.002 and presentation.shadow.visible,
		label + ": visible shadow sits at actual support without a render offset")
	var phase_before: float = visual.original_animation.native_phase
	var local_pose: Transform3D = mesh.transform
	var jump_trace: Array[Dictionary] = []
	var max_height: float = 0.0
	var minimum_width: float = INF
	var formula_error: float = 0.0
	var support_stable: bool = true
	var captured: bool = false
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	_check(player._jump_in_progress and player.velocity.y > 0.0, label + ": ordinary jump input starts the real native trajectory")
	for frame: int in range(60):
		await _ticks(1)
		var height: float = player.global_position.y - presentation.support_height
		var width: float = mesh.mesh.get_aabb().size.x * mesh.global_basis.x.length()
		max_height = maxf(max_height, height)
		minimum_width = minf(minimum_width, width)
		formula_error = maxf(formula_error, absf(width / 2.26 - 1.0 / (1.0 + COEFFICIENT * height)))
		support_stable = support_stable and presentation.support_valid and absf(presentation.global_position.y) < 0.002
		jump_trace.append({"frame": frame, "feet_y": player.global_position.y, "support_y": presentation.support_height,
			"world_quad_width": width, "on_floor": player.is_on_floor(), "native_phase": visual.original_animation.native_phase})
		if not captured and frame >= 22:
			captured = true
			if DisplayServer.get_name() != "headless":
				await _pixel_proof(world, label, mesh)
	_check(max_height > 2.9 and max_height < 3.2, label + ": tested heights come from a real approximately 3 m jump")
	_check(minimum_width > 0.85 and minimum_width < 1.1 and formula_error < 0.002,
		label + ": rendered quad shrinks to about one metre at the real apex using the source height relation")
	_check(support_stable, label + ": jumping changes shadow size while its floor support remains fixed")
	_check(mesh.transform.is_equal_approx(local_pose) and mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == original_vertices \
		and _static_material_phase(mesh), label + ": shadow phase/vertices stay static while primary actions advance")
	_check(player.is_on_floor() and not player._jump_in_progress, label + ": real jump lands normally")
	_check(not is_equal_approx(phase_before, visual.original_animation.native_phase), label + ": primary animation was actually advancing")
	evidence.append({"label": label, "jump": jump_trace, "apex": max_height, "minimum_world_width": minimum_width,
		"maximum_formula_error": formula_error})
	# The corner block is outside the player's 0.4 m body half-width, but one
	# actual shadow-support ray meets it while the player is genuinely jumping.
	var corner: StaticBody3D = _solid(Vector3(0.55, 0.2, 0.55), Vector3(0.18, 0.4, 0.18))
	world.add_child(corner)
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	await _ticks(20)
	_check(player.global_position.y > 2.0 and absf(presentation.support_height - 0.4) < 0.003 \
		and absf(presentation.global_position.y - 0.4) < 0.003,
		label + ": support selects the higher actual corner face rather than the centre or cached flat floor")
	corner.free()
	await _ticks(3)
	_check(absf(presentation.support_height) < 0.002, label + ": removing corner support refreshes the actual floor query")
	await _ticks(40)
	await _blink_and_death(world, label)
	Input.action_press("move_right")
	var lost_support: bool = false
	for frame: int in range(100):
		await _ticks(1)
		if not presentation.support_valid:
			lost_support = true
			break
	Input.action_release("move_right")
	_check(lost_support and not presentation.shadow.visible, label + ": walking off the real platform removes unsupported shadow drawing")
	player.respawn()
	await _ticks(10)
	_check(player.is_on_floor() and presentation.support_valid and presentation.shadow.visible \
		and visual._pose_root.visible and player._invulnerability_remaining == 0.0,
		label + ": normal respawn restores grounded body/shadow and clears the blink timer")
	world.free()
	await _ticks(2)


func _reversed_floor_support() -> void:
	# Imported native terrain explicitly enables backface collision. A BoxShape
	# cannot exercise that contract, so use an actual downward-wound concave floor.
	var world: ShadowWorld = _world(FIXTURE_DIRECTORY.path_join("hugo.glb"))
	world.floor_body.free()
	world.floor_body = StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var floor_shape := ConcavePolygonShape3D.new()
	floor_shape.set_faces(PackedVector3Array([
		Vector3(-4, 0, -4), Vector3(4, 0, 4), Vector3(4, 0, -4),
		Vector3(-4, 0, -4), Vector3(-4, 0, 4), Vector3(4, 0, 4)]))
	floor_shape.backface_collision = true
	collision.shape = floor_shape
	world.floor_body.add_child(collision)
	world.add_child(world.floor_body)
	root.add_child(world)
	await _ticks(10)
	var player: HugoPlayer = world.player
	var presentation: NativePlayerPresentation = player._visual.native_presentation
	_check(player.is_on_floor(), "backface terrain: the real player physically stands on the concave floor")
	_check(presentation.support_valid and presentation.shadow.visible and absf(presentation.support_height) < 0.002,
		"backface terrain: shadow support accepts the same reverse-wound floor as player collision")
	Input.action_press("jump")
	await _ticks(1)
	Input.action_release("jump")
	await _ticks(24)
	_check(player.global_position.y > 2.9 and presentation.support_valid and presentation.shadow.visible,
		"backface terrain: real jumping preserves floor support and visible shadow")
	evidence.append({"label": "backface_terrain", "floor_backface_collision": floor_shape.backface_collision,
		"actual_jump_height": player.global_position.y, "support_valid": presentation.support_valid})
	world.free()
	await _ticks(2)


func _beach_support() -> void:
	var catalog_path: String = "res://assets/generated/campaign.json"
	var gameplay_path: String = "res://assets/generated/gameplay_manifest.json"
	if not FileAccess.file_exists(catalog_path) or not FileAccess.file_exists(gameplay_path):
		skipped.append("Real Beach shadow support: campaign assets unavailable.")
		return
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(catalog_path)) as Dictionary
	var gameplay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(gameplay_path)) as Dictionary
	var entry: Dictionary = {}
	for candidate: Dictionary in catalog.get("levels", []):
		if str(candidate.get("id", "")) == "g006":
			entry = candidate.duplicate(true)
			break
	if entry.is_empty() or not gameplay.get("levels", {}).has("g006"):
		skipped.append("Real Beach shadow support: g006 unavailable.")
		return
	for bus: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	var level: OriginalLevel = LevelScript.new() as OriginalLevel
	level.entry = entry
	level.entry["title"] = "Beach shadow regression"
	level.data = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/generated/" + str(entry.manifest_path))) as Dictionary
	level.gameplay = gameplay.levels.g006
	level.native_rules = gameplay.get("native_rules", {})
	root.add_child(level)
	_check(level._ready_ok, "Beach: actual production chapter loads with source collision and actors")
	if not level._ready_ok:
		level.free()
		return
	await _ticks(60)
	var player: HugoPlayer = level.player
	var presentation: NativePlayerPresentation = player._visual.native_presentation
	_check(player.is_on_floor() and presentation.support_valid and presentation.shadow.visible,
		"Beach: normal spawn settles on source terrain with a visible supported shadow")
	var start: Vector3 = player.global_position
	var jump_observed: bool = false
	var supported_frames: int = 0
	var following_frames: int = 0
	var trace: Array[Dictionary] = []
	for frame: int in range(90):
		# Ordinary world +X steering converted to the live camera's action axes.
		var forward: Vector3 = -player.movement_camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right: Vector3 = forward.cross(Vector3.UP)
		var x: float = Vector3.RIGHT.dot(right)
		var y: float = -Vector3.RIGHT.dot(forward)
		Input.action_press("move_left", maxf(0.0, -x))
		Input.action_press("move_right", maxf(0.0, x))
		Input.action_press("move_forward", maxf(0.0, -y))
		Input.action_press("move_back", maxf(0.0, y))
		if frame == 15:
			Input.action_press("jump")
		elif frame == 16:
			Input.action_release("jump")
		await _ticks(1)
		jump_observed = jump_observed or player._jump_in_progress
		if presentation.support_valid:
			supported_frames += 1
			if Vector2(player.global_position.x, player.global_position.z).distance_to(
					Vector2(presentation.global_position.x, presentation.global_position.z)) < 0.002:
				following_frames += 1
		if frame % 6 == 0:
			trace.append({"frame": frame, "position": str(player.global_position),
				"shadow_position": str(presentation.global_position), "support_valid": presentation.support_valid,
				"visible": presentation.shadow.visible, "native_jump": player._jump_in_progress})
	_release()
	_check(jump_observed and player.global_position.distance_to(start) > 5.0,
		"Beach: the actual chapter exercises ordinary movement and a real native jump")
	_check(supported_frames >= 80 and following_frames == supported_frames,
		"Beach: source shadow support follows the player's real moving pose")
	_check(level.lives == 4 and level.checkpoint_id.is_empty(),
		"Beach: support regression uses the live starting world without reset or checkpoint substitution")
	evidence.append({"label": "real_Beach_normal_input", "supported_frames": supported_frames,
		"following_frames": following_frames, "normal_input_frames": 90, "trace": trace,
		"world_physics_modified": false, "teleports_or_requested_resets": 0})
	level.free()
	await _ticks(2)


func _blink_and_death(world: ShadowWorld, label: String) -> void:
	var player: HugoPlayer = world.player
	var visual: HugoPlayerVisual = player._visual
	var presentation: NativePlayerPresentation = visual.native_presentation
	_check(player.apply_damage(1), label + ": normal damage starts the source invulnerability timer")
	# Golden first 16 steps after 600 source ticks. At 60 Hz each real
	# controller step consumes five of the native 300-Hz ticks.
	var expected_hidden: Array[bool] = [false, false, false, false, true, true, true, true,
		true, true, true, false, false, false, false, false]
	var mask_ok: bool = true
	var shared_ok: bool = true
	var timers_ok: bool = true
	var samples: Array[Dictionary] = []
	for frame: int in range(120):
		await _ticks(1)
		if frame < expected_hidden.size():
			mask_ok = mask_ok and presentation.hidden_by_blink == expected_hidden[frame]
		timers_ok = timers_ok and presentation.remaining_ticks == maxi(0, 600 - (frame + 1) * 5)
		shared_ok = shared_ok and visual._pose_root.visible == presentation.shadow.visible \
			and visual._pose_root.visible == not presentation.hidden_by_blink
		if frame < 16 or frame == 119:
			samples.append({"frame": frame + 1, "native_ticks_remaining": presentation.remaining_ticks,
				"body_visible": visual._pose_root.visible, "shadow_visible": presentation.shadow.visible})
	_check(mask_ok and timers_ok, label + ": actual damage timer follows 300-Hz bit-0x20 visibility windows")
	_check(shared_ok, label + ": body and shadow blink together throughout real timer decay")
	_check(presentation.remaining_ticks == 0 and visual._pose_root.visible and presentation.shadow.visible,
		label + ": expiry returns both visuals to visible")
	evidence.append({"label": label, "blink_samples": samples})
	# The public controller stores seconds; let a sub-tick floating remainder
	# clear before asking for a second hit. The 600-tick render window above
	# already has a strict, independent check.
	await _ticks(1)
	_check(player.apply_damage(1), label + ": another hit is accepted after invulnerability expires")
	await _ticks(5)
	_check(presentation.hidden_by_blink, label + ": death exception starts inside an actual hidden blink window")
	world.health = 0
	player.play_death()
	await _ticks(1)
	_check(player._death_playing and not presentation.hidden_by_blink and visual._pose_root.visible and presentation.shadow.visible,
		label + ": generic death renders body plus shadow despite the active blink bit")
	var replacement: String = ""
	for action: String in visual.original_animation.manifest.get("bindings", {}):
		if action.begins_with("surface_death_"):
			replacement = action
			break
	_check(not replacement.is_empty(), label + ": a surface replacement clip is available")
	if not replacement.is_empty():
		player.play_death(replacement)
		await _ticks(1)
		_check(visual.original_animation.current_action == replacement and visual._pose_root.visible \
			and not presentation.shadow.visible, label + ": real surface death action replaces the visual without the normal ground shadow")
	world.health = 10
	player.respawn()
	await _ticks(10)
	_check(not visual.original_animation.current_action.begins_with("surface_death_") and not player._death_playing \
		and visual._pose_root.visible and presentation.shadow.visible,
		label + ": production reset exits the surface replacement and restores both visuals")


func _pixel_proof(world: ShadowWorld, label: String, mesh: MeshInstance3D) -> void:
	var player: HugoPlayer = world.player
	var presentation: NativePlayerPresentation = player._visual.native_presentation
	# Freeze only this QA fixture at a pose reached by real input. A/B images
	# differ solely in shadow visibility and cannot be presented as gameplay.
	player.set_physics_process(false)
	presentation.set_physics_process(false)
	var material: ShaderMaterial = mesh.get_active_material(0) as ShaderMaterial
	var saved_color: Variant = material.get_shader_parameter("base_color")
	if label == "fixture":
		material.set_shader_parameter("base_color", Color(0.25, 0.25, 0.25, 1.0))
	presentation.shadow.visible = true
	var with_shadow: Image = await _frame()
	presentation.shadow.visible = false
	var without_shadow: Image = await _frame()
	var difference: Dictionary = _difference(without_shadow, with_shadow)
	_check(int(difference.darkened_pixels) > 40 and float(difference.maximum_darkening) > 0.01,
		label + ": real GPU framebuffer contains nonzero floor darkening from the shadow")
	_check(int(difference.brightened_pixels) < maxi(4, int(difference.darkened_pixels) / 20),
		label + ": source shadow darkens the floor instead of adding light")
	if label == "fixture":
		material.set_shader_parameter("base_color", Color(0.75, 0.75, 0.75, 1.0))
		presentation.shadow.visible = true
		var stronger_source: Image = await _frame()
		var inverse: Dictionary = _difference(with_shadow, stronger_source)
		_check(int(inverse.darkened_pixels) > 40 and int(inverse.brightened_pixels) == 0,
			"fixture: increasing source RGB produces a darker framebuffer, proving inverse rather than ordinary blend")
		material.set_shader_parameter("base_color", saved_color)
	if not capture_prefix.is_empty():
		var shown: String = capture_prefix + "_" + label + "_with_shadow.png"
		var hidden: String = capture_prefix + "_" + label + "_without_shadow.png"
		_check(with_shadow.save_png(shown) == OK and without_shadow.save_png(hidden) == OK, label + ": A/B proof images saved")
		difference["with_shadow_image"] = shown
		difference["without_shadow_image"] = hidden
	difference["label"] = label
	difference["actual_jump_feet_y"] = player.global_position.y
	difference["qa_fixture_not_gameplay"] = true
	evidence.append(difference)
	presentation.shadow.visible = true
	player.set_physics_process(true)
	presentation.set_physics_process(true)


func _difference(before: Image, after: Image) -> Dictionary:
	var dark: int = 0
	var bright: int = 0
	var maximum: float = 0.0
	for y: int in range(before.get_height()):
		for x: int in range(before.get_width()):
			var a: Color = before.get_pixel(x, y)
			var b: Color = after.get_pixel(x, y)
			var delta: float = (a.r + a.g + a.b - b.r - b.g - b.b) / 3.0
			if delta > 0.004:
				dark += 1
			elif delta < -0.004:
				bright += 1
			maximum = maxf(maximum, delta)
	return {"darkened_pixels": dark, "brightened_pixels": bright, "maximum_darkening": maximum,
		"width": before.get_width(), "height": before.get_height()}


func _frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _world(model_path: String) -> ShadowWorld:
	var world := ShadowWorld.new()
	world.floor_body = _solid(Vector3(0, -0.5, 0), Vector3(8, 1, 8))
	world.add_child(world.floor_body)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	ground.mesh = plane
	var sand := StandardMaterial3D.new()
	sand.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sand.albedo_color = Color(0.82, 0.72, 0.58)
	ground.material_override = sand
	world.add_child(ground)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.12, 0.15, 0.19)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.8
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.8, -0.4, 0)
	light.shadow_enabled = false
	world.add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(5, 9, 10)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 9.5
	camera.current = true
	world.add_child(camera)
	camera.look_at_from_position(camera.position, Vector3(0, 2, 0))
	world.player = PlayerScript.new() as HugoPlayer
	world.player.model_path = model_path
	world.player.character_height = 3.33077
	world.player.position = Vector3(0, 0.05, 0)
	world.player.fall_reset_height = -15.0
	world.player.set_native_configuration(_profile())
	world.add_child(world.player)
	return world


func _solid(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	body.position = at
	return body


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		result.append_array(_meshes(child))
	return result


func _static_material_phase(mesh: MeshInstance3D) -> bool:
	for binding: Dictionary in mesh.get_meta(MaterialsScript.BINDING_META, []):
		if not is_zero_approx(float(binding.get("last_phase", 0.0))):
			return false
	return true


func _create_fixture_assets() -> void:
	DirAccess.make_dir_recursive_absolute(FIXTURE_DIRECTORY)
	var body := Node3D.new()
	var body_mesh := MeshInstance3D.new()
	body_mesh.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(1, 3, 1)
	body_mesh.mesh = box
	body_mesh.position.y = 1.5
	var blue := StandardMaterial3D.new()
	blue.albedo_color = Color(0.12, 0.25, 0.6)
	box.material = blue
	body.add_child(body_mesh)
	body_mesh.owner = body
	_save_scene(body, "body.tscn")
	var shadow := Node3D.new()
	var quad := MeshInstance3D.new()
	quad.name = "Quad"
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1.13, 0, -1.13), Vector3(1.13, 0, -1.13), Vector3(1.13, 0, 1.13), Vector3(-1.13, 0, 1.13)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inverse := StandardMaterial3D.new()
	inverse.resource_name = "fixture_shadow__hugo_blend_2"
	inverse.albedo_color = Color(0.35, 0.35, 0.35, 1.0)
	mesh.surface_set_material(0, inverse)
	quad.mesh = mesh
	shadow.add_child(quad)
	quad.owner = shadow
	_save_scene(shadow, "shadow.tscn")
	var clips: Dictionary = {}
	var bindings: Dictionary = {}
	var names: Array[String] = ["idle", "attack", "crouch", "crawl", "walk", "run", "land", "jump", "jump_moving", "fall", "hurt", "death", "surface_death_fixture"]
	for index: int in range(names.size()):
		var id: String = "action_%02d" % index
		clips[id] = {"path": "body.tscn", "authored_duration_seconds": 0.8, "authored_duration_timer_ticks": 240.0,
			"phase_domain": "seconds", "loop": names[index] not in ["death", "surface_death_fixture"],
			"nodes": [{"node": "Body", "transform_chain": ["moving_body"], "stored_samples": 1}]}
		bindings[names[index]] = {"clip": id}
	var manifest: Dictionary = {"schema_version": 1, "source_scale": 0.01, "clips": clips, "bindings": bindings,
		"bind_bounds": {"min": [-0.5, 0, -0.5], "max": [0.5, 3, 0.5]},
		"tracks": {"moving_body": {"initial_translation": [0, 0, 150],
			"translation_keys": [[0, 0, 150], [30, 0, 170], [0, 0, 150]], "translation_loop": true,
			"initial_basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]}},
		"hugo_shadow": {"role": "ground_shadow", "path": "shadow.tscn", "native_phase": 0.0,
			"render_policy": {"height_scale_coefficient_world": COEFFICIENT}}}
	var file := FileAccess.open(FIXTURE_DIRECTORY.path_join("animation_manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest))
	file.close()


func _save_scene(scene: Node3D, filename: String) -> void:
	var packed := PackedScene.new()
	_check(packed.pack(scene) == OK and ResourceSaver.save(packed, FIXTURE_DIRECTORY.path_join(filename)) == OK,
		"fixture scene saves: " + filename)
	scene.free()


func _profile() -> Dictionary:
	var path: String = "res://assets/generated/gameplay_manifest.json"
	if FileAccess.file_exists(path):
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
		var movement: Dictionary = data.get("levels", {}).get("g006", {}).get("native_player", {}).get("movement", {}) as Dictionary
		if not movement.is_empty():
			return movement
	return {"schema_version": 1, "native_timer_hz": 300.0,
		"ground_max_speed": 8.25, "ground_response_per_tick": 0.05,
		"crawl_speed": 3.0, "crawl_response_per_tick": 0.9,
		"jump_initial_velocity": 1800.0 / 121.0, "jump_gravity": 4500.0 / 121.0,
		"jump_horizontal_speed": 11.25, "jump_response_per_tick": 0.01,
		"fall_horizontal_speed": 3.0, "fall_response_per_tick": 0.005,
		"fall_gravity": 216.0, "fall_terminal_speed": 9.0,
		"standing_box_size": [0.8, 3.0, 0.8], "crouching_box_size": [0.8, 2.0, 0.8],
		"invulnerability_seconds": 2.0}


func _ticks(count: int) -> void:
	for frame: int in range(count):
		await physics_frame
		await process_frame


func _release() -> void:
	for action: String in ["move_left", "move_right", "move_forward", "move_back", "jump", "attack", "crouch"]:
		Input.action_release(action)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)
