class_name RemasterWorld
extends Node3D
## Authored traversal course for validating the remaster's controls and imports.
## Original chapters are loaded separately by campaign.gd / original_level.gd.

const PlayerScript = preload("res://scripts/player.gd")
const CameraScript = preload("res://scripts/follow_camera.gd")
const DiamondScript = preload("res://scripts/diamond.gd")
const HUDScript = preload("res://scripts/hud.gd")

var player: HugoPlayer
var camera_rig: HugoFollowCamera
var hud: RemasterHUD
var diamonds: Array[DiamondPickup] = []
var collected_count: int = 0
var total_diamonds: int = 12
var completed: bool = false
var elapsed_seconds: float = 0.0
var spawn_point := Vector3(0, 0.15, 7)
var exit_position := Vector3(-3, 2.2, -27.3)
var finish_area: Area3D
var checkpoint_active: bool = false
var _checkpoint_beacon: MeshInstance3D
var _palm_scene: PackedScene


func _ready() -> void:
	_configure_input()
	_build_environment()
	_build_course()
	player = PlayerScript.new()
	player.name = "Hugo"
	player.position = spawn_point
	# The recovered source faces -Y, which the importer maps to +Z. The
	# controller faces -Z; this offset applies only to an imported model.
	player.model_yaw_degrees = 180.0
	add_child(player)
	player.set_checkpoint(spawn_point)
	camera_rig = CameraScript.new()
	camera_rig.name = "FollowCamera"
	add_child(camera_rig)
	camera_rig.set_target(player)
	player.movement_camera = camera_rig.camera
	hud = HUDScript.new()
	add_child(hud)
	hud.restart_requested.connect(restart_run)
	player.respawned.connect(_on_respawn)
	hud.set_progress(0, total_diamonds, 0.0)
	hud.toast_key("toast.demo_start", {}, 6.0)
	_capture_if_requested.call_deferred()


func _process(delta: float) -> void:
	if not completed:
		elapsed_seconds += delta
	hud.set_progress(collected_count, total_diamonds, elapsed_seconds)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		var fullscreen: bool = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)


func restart_run() -> void:
	collected_count = 0
	elapsed_seconds = 0.0
	completed = false
	checkpoint_active = false
	for diamond in diamonds:
		diamond.reset_pickup()
	_checkpoint_beacon.material_override = _material(Color("5bd8d3"), true)
	player.controls_enabled = true
	player.set_checkpoint(spawn_point)
	hud.reset_hud()
	player.respawn()
	hud.set_progress(0, total_diamonds, 0.0)
	hud.toast_key("toast.collect_all", {}, 4.0)


func _on_diamond_collected(_diamond: DiamondPickup) -> void:
	collected_count += 1
	hud.play_pickup()
	if collected_count == total_diamonds:
		hud.toast_key("toast.all_collected", {}, 5.0)


func _on_respawn() -> void:
	if is_instance_valid(hud):
		hud.toast_key("toast.checkpoint_return" if checkpoint_active else "toast.beach_return", {}, 2.5)


func _on_checkpoint_entered(body: Node3D) -> void:
	if body != player or checkpoint_active:
		return
	checkpoint_active = true
	player.set_checkpoint(Vector3(3, 1.05, -10.6))
	_checkpoint_beacon.material_override = _material(Color("ffd980"), true)
	hud.toast_key("toast.checkpoint_saved", {}, 3.0)


func _on_finish_entered(body: Node3D) -> void:
	if body != player or completed:
		return
	if collected_count < total_diamonds:
		hud.toast_key("toast.diamonds_remaining", {"count": total_diamonds - collected_count})
		return
	completed = true
	player.controls_enabled = false
	hud.finish(elapsed_seconds)


func _build_course() -> void:
	_island(Vector3(0, 0, 3.5), 7.5, 7.0, 15)
	_island(Vector3(3, 0.9, -11.5), 5.5, 5.0, 36)
	_island(Vector3(-3, 1.9, -24), 7.3, 6.0, 68)
	_box_platform(Vector3(0, 0.15, -4.8), Vector3(2.6, 0.6, 2.5), Color("b9a17a"))
	_box_platform(Vector3(1.9, 0.3, -7.1), Vector3(2.5, 0.6, 2.5), Color("c7b288"))
	# A small fallen beam gives the opening route a deliberate jump obstacle.
	_box_platform(Vector3(0, 0.35, 0), Vector3(4.2, 0.7, 0.55), Color("72503b"))
	_bridge(Vector3(1, 0.94, -14.5), Vector3(-2, 1.95, -19.3))
	var points: Array[Vector3] = [
		Vector3(0, 0.9, 4.4), Vector3(0, 0.9, 1.5), Vector3(1, 0.9, -1.2),
		Vector3(0, 1.2, -4.8), Vector3(2, 1.5, -7.1), Vector3(3, 1.8, -9.4),
		Vector3(5, 1.8, -12.4), Vector3(1, 1.8, -13.0), Vector3(0, 2.4, -16.1),
		Vector3(-2, 2.8, -19.0), Vector3(-3, 2.8, -22), Vector3(-1, 2.8, -25.0)]
	total_diamonds = points.size()
	for i in range(points.size()):
		var diamond: DiamondPickup = DiamondScript.new()
		diamond.name = "Diamond%02d" % (i + 1)
		diamond.position = points[i]
		diamond.phase = i * 0.63
		add_child(diamond)
		diamond.collected.connect(_on_diamond_collected)
		diamonds.append(diamond)
	_build_checkpoint()
	_build_exit()
	_build_scenery()


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("4b9ebd")
	sky_material.sky_horizon_color = Color("d3e9df")
	sky_material.ground_bottom_color = Color("1f6574")
	sky_material.ground_horizon_color = Color("cfdfce")
	sky_material.sun_angle_max = 8.0
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_sky_contribution = 0.0
	environment.ambient_light_color = Color("c6dece")
	environment.ambient_light_energy = 0.25
	# Keep the authored palette below clipping in the Compatibility renderer.
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.fog_enabled = true
	environment.fog_light_color = Color("9fcdc8")
	environment.fog_density = 0.0028
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-47, -28, 0)
	sun.light_color = Color("ffe6ae")
	sun.light_energy = 0.42
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 75.0
	add_child(sun)
	var water := MeshInstance3D.new()
	var water_mesh := PlaneMesh.new()
	water_mesh.size = Vector2(220, 220)
	water_mesh.subdivide_width = 50
	water_mesh.subdivide_depth = 50
	water.mesh = water_mesh
	water.position = Vector3(0, -1.0, -30)
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_disabled;
varying vec2 water_position;
void vertex() {
    water_position = VERTEX.xz;
    VERTEX.y += sin(VERTEX.x * 0.31 + TIME * 0.65) * 0.065 + cos(VERTEX.z * 0.26 + TIME * 0.4) * 0.045;
}
void fragment() {
    float wave = sin(water_position.x * 0.5 + TIME * 0.8) * cos(water_position.y * 0.4 - TIME * 0.6);
    ALBEDO = mix(vec3(0.012, 0.14, 0.20), vec3(0.035, 0.32, 0.33), wave * 0.25 + 0.55);
    METALLIC = 0.12;
    ROUGHNESS = 0.28;
}
"""
	var water_material := ShaderMaterial.new()
	water_material.shader = shader
	water.material_override = water_material
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


func _island(center: Vector3, radius_x: float, radius_z: float, seed_value: int) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(24):
		var angle: float = TAU * i / 24.0
		var radius: float = rng.randf_range(0.91, 1.08)
		ring.append(Vector3(cos(angle) * radius_x * radius, 0, sin(angle) * radius_z * radius))
	for i in range(ring.size()):
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % ring.size()]
		var sand := Color("d5bf87").lightened(rng.randf_range(-0.05, 0.05))
		_triangle(surface, Vector3.ZERO, a, b, sand)
		var a_lower: Vector3 = Vector3(a.x * 1.12, -2.0 - center.y, a.z * 1.12)
		var b_lower: Vector3 = Vector3(b.x * 1.12, -2.0 - center.y, b.z * 1.12)
		_triangle(surface, a, a_lower, b, Color("ab9c75"))
		_triangle(surface, b, a_lower, b_lower, Color("96896b"))
	surface.generate_normals()
	var terrain_mesh: ArrayMesh = surface.commit()
	var terrain := MeshInstance3D.new()
	terrain.mesh = terrain_mesh
	terrain.position = center
	var terrain_material := _material(Color.WHITE)
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.vertex_color_is_srgb = true
	terrain.material_override = terrain_material
	add_child(terrain)
	var body := StaticBody3D.new()
	body.position = center
	var collision := CollisionShape3D.new()
	collision.shape = terrain_mesh.create_trimesh_shape()
	body.add_child(collision)
	add_child(body)
	# Low foliage patches stay away from the central traversal line.
	for side: float in [-1.0, 1.0]:
		var patch := MeshInstance3D.new()
		var patch_mesh := CylinderMesh.new()
		patch_mesh.top_radius = radius_x * 0.23
		patch_mesh.bottom_radius = patch_mesh.top_radius
		patch_mesh.height = 0.035
		patch_mesh.radial_segments = 14
		patch.mesh = patch_mesh
		patch.position = center + Vector3(side * radius_x * 0.62, 0.025, -radius_z * 0.10)
		patch.scale.z = 1.6
		patch.material_override = _material(Color("76986a"))
		add_child(patch)


func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	for vertex: Vector3 in [a, b, c]:
		surface.set_color(color)
		surface.add_vertex(vertex)


func _box_platform(center: Vector3, dimensions: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	var model := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	model.mesh = mesh
	model.material_override = _material(color)
	body.add_child(model)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = dimensions
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	return body


func _bridge(start: Vector3, finish: Vector3) -> void:
	var direction: Vector3 = finish - start
	var yaw: float = atan2(direction.x, direction.z)
	for i in range(13):
		var t: float = i / 12.0
		var point: Vector3 = start.lerp(finish, t)
		var plank := _box_platform(point - Vector3(0, 0.12, 0), Vector3(2.0, 0.24, direction.length() / 12.0 + 0.025), Color("8b6541"))
		plank.rotation.y = yaw
		if i % 3 == 0:
			for side: float in [-1.0, 1.0]:
				var offset := Vector3(cos(yaw), 0, -sin(yaw)) * side * 1.0
				_box_platform(point + offset + Vector3(0, 0.45, 0), Vector3(0.12, 1.15, 0.12), Color("674a35"))


func _build_checkpoint() -> void:
	var area := Area3D.new()
	area.position = Vector3(3, 1.5, -10.6)
	area.collision_layer = 0
	area.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 1.3
	collision.shape = shape
	area.add_child(collision)
	area.body_entered.connect(_on_checkpoint_entered)
	add_child(area)
	_checkpoint_beacon = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.65
	ring.outer_radius = 0.78
	ring.rings = 20
	ring.ring_segments = 8
	_checkpoint_beacon.mesh = ring
	_checkpoint_beacon.position = Vector3(3, 0.97, -10.6)
	_checkpoint_beacon.material_override = _material(Color("5bd8d3"), true)
	add_child(_checkpoint_beacon)


func _build_exit() -> void:
	for side: float in [-1.0, 1.0]:
		var pillar := _box_platform(Vector3(-3 + side * 1.55, 3.4, -27.6), Vector3(0.85, 3.0, 1.0), Color("a29d86"))
		pillar.rotation.z = side * -0.04
	_box_platform(Vector3(-3, 5.05, -27.6), Vector3(4.2, 0.7, 1.2), Color("c6bd99"))
	finish_area = Area3D.new()
	finish_area.name = "Exit"
	finish_area.position = exit_position
	finish_area.collision_layer = 0
	finish_area.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.6, 3.0, 1.8)
	collision.shape = shape
	finish_area.add_child(collision)
	finish_area.body_entered.connect(_on_finish_entered)
	add_child(finish_area)


func _build_scenery() -> void:
	if ResourceLoader.exists("res://assets/generated/palm.glb"):
		_palm_scene = load("res://assets/generated/palm.glb") as PackedScene
	var positions: Array[Vector3] = [Vector3(-4.7, 0, 4), Vector3(5.0, 0, 3), Vector3(-4.6, 0, -0.7), Vector3(5.1, 0, 7.4), Vector3(6.9, 0.9, -10), Vector3(-0.5, 0.9, -12), Vector3(5.5, 0.9, -14), Vector3(-7.8, 1.9, -22), Vector3(2.0, 1.9, -23.7), Vector3(-7, 1.9, -26)]
	for i in range(positions.size()):
		_palm(positions[i], 4.4 + (i % 3) * 0.6, i * 0.71)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7839
	for i in range(30):
		var side: float = -1.0 if i % 2 else 1.0
		var position := Vector3(side * rng.randf_range(14, 40), -1.8, rng.randf_range(-65, 10))
		_rock(position, Vector3(rng.randf_range(3, 7), rng.randf_range(5, 15), rng.randf_range(3, 7)), Color("557b78"))
	for position: Vector3 in [Vector3(-5.8, 0.25, 6), Vector3(5.4, 0.3, -0.7), Vector3(7.1, 1.1, -12.8), Vector3(-7.5, 2.1, -24.3)]:
		_rock(position, Vector3(1.3, 0.9, 1.0), Color("a39e84"))


func _rock(position: Vector3, dimensions: Vector3, color: Color) -> void:
	var rock := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 7
	mesh.rings = 3
	rock.mesh = mesh
	rock.position = position
	rock.scale = dimensions
	rock.rotation.y = position.z
	rock.material_override = _material(color)
	add_child(rock)


func _palm(position: Vector3, height: float, turn: float) -> void:
	if _palm_scene:
		var palm := _palm_scene.instantiate() as Node3D
		var wrapper := Node3D.new()
		wrapper.position = position
		wrapper.rotation.y = turn
		var normalizer := Node3D.new()
		wrapper.add_child(normalizer)
		normalizer.add_child(palm)
		var bounds: AABB = _scene_bounds(palm)
		var scale_factor: float = height / maxf(bounds.size.y, 0.001)
		normalizer.scale = Vector3.ONE * scale_factor
		var center: Vector3 = bounds.get_center()
		normalizer.position = -Vector3(center.x, bounds.position.y, center.z) * scale_factor
		add_child(wrapper)
		return
	var palm_root := Node3D.new()
	palm_root.position = position
	palm_root.rotation.y = turn
	add_child(palm_root)
	var trunk := MeshInstance3D.new()
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.12
	trunk_mesh.bottom_radius = 0.25
	trunk_mesh.height = height * 0.8
	trunk_mesh.radial_segments = 7
	trunk.mesh = trunk_mesh
	trunk.position.y = height * 0.4
	trunk.material_override = _material(Color("826344"))
	palm_root.add_child(trunk)
	for i in range(7):
		var leaf := MeshInstance3D.new()
		var leaf_mesh := PrismMesh.new()
		leaf_mesh.size = Vector3(0.75, 0.16, height * 0.58)
		leaf.mesh = leaf_mesh
		leaf.material_override = _material(Color("4b8350"))
		var angle: float = TAU * i / 7.0
		leaf.position = Vector3(sin(angle) * height * 0.23, height * 0.78, cos(angle) * height * 0.23)
		leaf.rotation = Vector3(0.16, angle, 0)
		palm_root.add_child(leaf)


func _scene_bounds(root: Node3D) -> AABB:
	var result := AABB()
	var found: bool = false
	var nodes: Array[Node] = [root]
	var transforms: Array[Transform3D] = [Transform3D.IDENTITY]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		var transform: Transform3D = transforms.pop_back()
		if node is Node3D:
			transform = transform * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var box: AABB = transform * (node as MeshInstance3D).mesh.get_aabb()
			result = result.merge(box) if found else box
			found = true
		for child in node.get_children():
			nodes.append(child)
			transforms.append(transform)
	return result


func _material(color: Color, emissive: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 0.7
	return material


func _configure_input() -> void:
	var keys: Dictionary = {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN],
		"jump": [KEY_SPACE], "sprint": [KEY_SHIFT], "reset": [KEY_R], "pause": [KEY_ESCAPE]}
	for action: String in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.18)
		for key: int in keys[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)
	var axis_actions: Array[String] = ["move_left", "move_right", "move_forward", "move_back"]
	for i in range(axis_actions.size()):
		var event := InputEventJoypadMotion.new()
		event.axis = JOY_AXIS_LEFT_X if i < 2 else JOY_AXIS_LEFT_Y
		event.axis_value = -1.0 if i % 2 == 0 else 1.0
		if not InputMap.action_has_event(axis_actions[i], event):
			InputMap.action_add_event(axis_actions[i], event)
	for pair: Array in [["jump", JOY_BUTTON_A], ["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B], ["sprint", JOY_BUTTON_RIGHT_SHOULDER], ["pause", JOY_BUTTON_START]]:
		var event := InputEventJoypadButton.new()
		event.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], event):
			InputMap.action_add_event(pair[0], event)


func _capture_if_requested() -> void:
	var capture_path: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			capture_path = argument.trim_prefix("--capture=")
	if capture_path.is_empty() or DisplayServer.get_name() == "headless":
		return
	if "--hero-view" in OS.get_cmdline_user_args():
		var close_camera := Camera3D.new()
		close_camera.fov = 40.0
		add_child(close_camera)
		close_camera.global_position = player.global_position + Vector3(2.5, 1.8, -3.8)
		close_camera.look_at(player.global_position + Vector3(0, 0.88, 0))
		close_camera.current = true
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var picture: Image = get_viewport().get_texture().get_image()
	var error: Error = picture.save_png(capture_path)
	print("CAPTURE ", capture_path, " status=", error)
	get_tree().quit(0 if error == OK else 1)
