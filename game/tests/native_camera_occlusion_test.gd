extends SceneTree
## A visible repaired boundary must block the player without hiding the body.
## Real physics queries; no source asset, hidden wall or rendered-alpha change.
const CameraScript = preload("res://scripts/native_camera.gd")
const PlayerScript = preload("res://scripts/player.gd")
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	root.add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var target := Node3D.new()
	world.add_child(target)
	var body := StaticBody3D.new()
	body.set_meta("hugo_boundary_closure", true)
	body.collision_layer = 1
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 8.0, 0.3)
	collision.shape = box
	body.add_child(collision)
	body.position = Vector3(0.0, 4.0, 2.0)
	world.add_child(body)
	var visible_wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = box.size
	visible_wall.mesh = wall_mesh
	body.add_child(visible_wall)
	var source: Dictionary = {"transform": {"reference": {"group": 1, "record": 0}},
		"alternate_path": {"reference": {"group": 1, "record": 1}},
		"projection": {"horizontal_fov_degrees": 50.0, "near": 0.3, "far": 500.0}}
	var tracks: Dictionary = {"g001_r0000": {"initial_translation": [0, -800, 700],
			"translation_keys": [[0, -800, 700], [100, -800, 700]]},
		"g001_r0001": {"initial_translation": [0, 0, 0], "translation_keys": [[0, 0, 0], [100, 0, 0]]}}
	var original_tracks: Dictionary = tracks.duplicate(true)
	var rig: HugoNativeCamera = CameraScript.new()
	_check(rig.configure(source, tracks), "source camera fixture loads")
	rig.target = target
	world.add_child(rig)
	rig.set_physics_process(false)
	await physics_frame
	await process_frame
	rig.boundary_occlusion_enabled = false
	rig._update_native(1.0 / 60.0, true)
	var blocked: Dictionary = rig._boundary_hit(target.position + Vector3.UP * rig.target_height, rig.camera.global_position)
	_check(not blocked.is_empty(), "unmodified native camera actually lies behind the visible wall")
	rig.boundary_occlusion_enabled = true
	var player: HugoPlayer = PlayerScript.new()
	player.movement_camera = rig.camera
	for z: float in [0.0, 0.7, 1.3, 1.4, 0.7, 0.0]:
		target.position.z = z
		rig.boundary_occlusion_enabled = false
		rig._update_native(1.0 / 60.0, true)
		var original_forward: Vector3 = -rig.camera.global_basis.z
		original_forward.y = 0.0
		original_forward = original_forward.normalized()
		rig.boundary_occlusion_enabled = true
		rig._update_native(1.0 / 60.0, false)
		var eye: Vector3 = target.global_position + Vector3.UP * rig.target_height
		var pose: Transform3D = rig.camera.global_transform
		_check(rig.boundary_occlusion_active and rig._boundary_hit(eye, pose.origin).is_empty() and rig._boundary_hit(target.global_position + Vector3.UP * rig.camera.near, pose.origin).is_empty(), "camera keeps clear torso and feet sightlines at z=%.2f" % z)
		_check(absf(pose.basis.z.y) < sin(deg_to_rad(50.0)) and pose.origin.distance_to(eye) >= rig.target_height * 3.5,
			"camera keeps a readable oblique view instead of looking down into the head at z=%.2f" % z)
		_check(player._camera_relative_direction(Vector2(0.0, 1.0)).dot(-original_forward) > 0.999,
			"camera shoulder avoidance preserves the original held S direction at z=%.2f" % z)
		var framed: bool = true
		for corner: Vector3 in [Vector3(-0.55, 0.0, 0.0), Vector3(0.55, 0.0, 0.0), Vector3(-0.55, 2.0, 0.0), Vector3(0.55, 2.0, 0.0)]:
			var point: Vector3 = target.global_position + corner
			framed = framed and not rig.camera.is_position_behind(point) and Rect2(Vector2.ZERO, Vector2(viewport.size)).has_point(rig.camera.unproject_position(point))
		_check(framed, "head and feet stay in frame at z=%.2f" % z)
		_check(visible_wall.visible and body.collision_layer == 1 and target.visible, "occlusion adaptation does not hide wall/body or disable collision")
	# A nearly vertical camera must not change S to an unrelated world heading.
	rig.set_manual_orbit(true)
	_check(not rig.camera.has_meta("hugo_native_movement_forward"), "manual orbit releases temporary native movement heading")
	for yaw: float in [0.0, PI * 0.5, PI, -PI * 0.5]:
		var back: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
		rig.camera.global_basis = Basis.looking_at(-back * 0.001 + Vector3.DOWN, Vector3.UP)
		_check(player._camera_relative_direction(Vector2(0.0, 1.0)).dot(back) > 0.999, "near-vertical S retains native horizontal heading at yaw=%.2f" % yaw)
	player.free()
	_check(tracks == original_tracks, "source camera tracks are unchanged")
	viewport.free()
	await process_frame
	print("NATIVE_CAMERA_OCCLUSION checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)
