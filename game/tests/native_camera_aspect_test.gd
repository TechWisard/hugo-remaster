extends SceneTree
## Resize a real native rig; verify its projection and visible jump-height point.
## This needs no original assets and does not mutate the camera's source paths.

const CameraScript = preload("res://scripts/native_camera.gd")
const SOURCE_FOV: float = 50.025358
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	root.add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var target := Node3D.new()
	world.add_child(target)
	var source: Dictionary = {"transform": {"reference": {"group": 1, "record": 0}},
		"alternate_path": {"reference": {"group": 1, "record": 1}},
		"projection": {"horizontal_fov_degrees": SOURCE_FOV, "near": 0.3, "far": 500.0}}
	var tracks: Dictionary = {"g001_r0000": {"initial_translation": [0, -800, 400],
			"translation_keys": [[0, -800, 400], [100, -800, 400]]},
		"g001_r0001": {"initial_translation": [0, 0, 0], "translation_keys": [[0, 0, 0], [100, 0, 0]]}}
	var source_before: Dictionary = source.duplicate(true)
	var tracks_before: Dictionary = tracks.duplicate(true)
	var rig: HugoNativeCamera = CameraScript.new()
	_check(rig.configure(source, tracks), "the production rig accepts source camera and target tracks")
	rig.target = target
	world.add_child(rig)
	rig.set_physics_process(false)
	await process_frame
	await process_frame
	var camera: Camera3D = rig.camera
	var baseline_fov: float = camera.fov
	var baseline_projection: Projection = camera.get_camera_projection()
	var baseline_pose: Transform3D = camera.global_transform
	var baseline_checkpoint: Dictionary = rig.native_checkpoint_snapshot()
	var top: Vector3 = camera.to_global(Vector3(0.0, 2.2, -10.0))
	var baseline_top: Vector2 = camera.unproject_position(top)
	_check(camera.keep_aspect == Camera3D.KEEP_WIDTH and absf(baseline_fov - SOURCE_FOV) < 0.00001,
		"16:9 uses the source horizontal FOV and KEEP_WIDTH")
	_check(baseline_top.y > 0.0 and baseline_top.y < viewport.size.y, "the jump-height reference is visible in the 16:9 baseline")
	var vertical_fraction: float = baseline_top.y / viewport.size.y
	for size: Vector2i in [Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1920, 1200),
			Vector2i(1440, 1080), Vector2i(3440, 1440), Vector2i(5120, 1440), Vector2i(1920, 1080)]:
		viewport.size = size
		await process_frame
		await process_frame
		var projection: Projection = camera.get_camera_projection()
		var aspect: float = float(size.x) / size.y
		var wide: bool = aspect > 16.0 / 9.0
		_check(camera.keep_aspect == Camera3D.KEEP_WIDTH, "%s keeps the source projection convention" % size)
		_check(camera.fov > baseline_fov if wide else camera.fov == baseline_fov,
			"%s widens only an ultrawide horizontal FOV and restores the exact baseline" % size)
		if wide or is_equal_approx(aspect, 16.0 / 9.0):
			_check(absf(projection.y.y - baseline_projection.y.y) < 0.00001,
				"%s preserves vertical angular coverage when width grows" % size)
			var projected: Vector2 = camera.unproject_position(top)
			_check(projected.y >= 0.0 and projected.y <= size.y and absf(projected.y / size.y - vertical_fraction) < 0.00001,
				"%s keeps the jump-height point at the same normalized vertical position" % size)
		_check(absf(projection.y.y / projection.x.x - aspect) < 0.00001, "%s projection matches the actual viewport aspect" % size)
		var origin: Vector2 = camera.unproject_position(camera.to_global(Vector3(0.0, 0.0, -10.0)))
		var right: Vector2 = camera.unproject_position(camera.to_global(Vector3(1.0, 0.0, -10.0)))
		var up: Vector2 = camera.unproject_position(camera.to_global(Vector3(0.0, 1.0, -10.0)))
		_check(absf(origin.distance_to(right) - origin.distance_to(up)) < 0.01,
			"%s renders equal camera-space lengths without axis stretching" % size)
		_check(camera.global_transform.is_equal_approx(baseline_pose) and rig.native_checkpoint_snapshot() == baseline_checkpoint,
			"%s resize leaves the native tracker and camera pose untouched" % size)
	_check(source == source_before and tracks == tracks_before, "presentation adaptation leaves every recovered source value unchanged")
	viewport.free()
	await process_frame
	print("NATIVE_CAMERA_ASPECT checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)
