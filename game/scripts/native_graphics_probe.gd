class_name NativeGraphicsProbe
extends Node3D
## Short, asset-free renderer preflight. An external module needs its own proof.

const GraphicsScript = preload("res://scripts/native_graphics_settings.gd")
const SCHEMA: int = 1
const MIN_SIZE := Vector2i(640, 360)
const SAMPLE_SIZE := Vector2i(64, 36)

var options: Dictionary = {}
var _moving_mesh: MeshInstance3D


static func parse_arguments(arguments: PackedStringArray) -> Dictionary:
	var result: Dictionary = {"requested": false, "path": "", "frames": 120, "error": ""}
	for argument: String in arguments:
		if argument.begins_with("--graphics-probe="):
			if result.requested:
				result.error = "graphics_probe_path_repeated"
			result.requested = true
			result.path = argument.trim_prefix("--graphics-probe=")
		elif argument.begins_with("--graphics-probe-frames="):
			var value: String = argument.trim_prefix("--graphics-probe-frames=")
			if value.is_valid_int():
				result.frames = clampi(int(value), 3, 3600)
			else:
				result.error = "invalid_graphics_probe_frames"
	return result


static func output_path_error(path: String) -> String:
	if path.is_empty() or not path.is_absolute_path() or path.begins_with("res://") or path.begins_with("user://"):
		return "graphics_probe_requires_absolute_path"
	if path.get_extension().to_lower() != "json":
		return "graphics_probe_requires_json_path"
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return "graphics_probe_output_already_exists"
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return "graphics_probe_parent_missing"
	return ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var path: String = str(options.get("path", ""))
	var path_error: String = output_path_error(path)
	if not path_error.is_empty():
		print("GRAPHICS_PROBE success=false reason=", path_error)
		get_tree().quit(2)
		return
	var report: Dictionary = _base_report()
	var argument_error: String = str(options.get("error", ""))
	if not argument_error.is_empty():
		report.failure_reason = argument_error
		_finish(path, report)
		return
	var started_usec: int = Time.get_ticks_usec()
	var window: Window = get_tree().root
	if not report.headless:
		window.title = "Кузя — проверка графики"
		window.mode = Window.MODE_WINDOWED
		window.size = Vector2i(maxi(window.size.x, MIN_SIZE.x), maxi(window.size.y, MIN_SIZE.y))
	# Probe resolution is diagnostic and must never restore or apply game display preferences.
	GraphicsScript.apply(window, GraphicsScript.defaults(), false)
	_build_fixture()
	var first_image: Image
	var last_image: Image
	var frames: int = int(options.get("frames", 120))
	for frame: int in range(frames):
		_moving_mesh.rotation = Vector3(0.15 + frame * 0.013, frame * 0.047, 0.1)
		_moving_mesh.position.x = sin(frame * 0.031) * 0.8
		await get_tree().process_frame
		if not report.headless:
			await RenderingServer.frame_post_draw
			if frame == 0 or frame == frames - 1:
				var picture: Image = window.get_texture().get_image()
				if picture != null and not picture.is_empty():
					if frame == 0:
						first_image = picture
					else:
						last_image = picture
			report.rendered_frames = frame + 1
	report.elapsed_seconds = (Time.get_ticks_usec() - started_usec) / 1000000.0
	report.viewport_size = [window.size.x, window.size.y]
	report.msaa_samples = _msaa_samples(window.msaa_3d)
	report.render_scale = window.scaling_3d_scale
	report.vsync_mode = DisplayServer.window_get_vsync_mode() if not report.headless else -1
	report.anisotropic_filtering_level = int(ProjectSettings.get_setting("rendering/textures/default_filters/anisotropic_filtering_level", 0))
	report.limits = _device_limits()
	report.frame_validation = _validate_frames(first_image, last_image)
	report.draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	report.success = not report.headless and bool(report.frame_validation.valid)
	report.hardware_verified = report.success and not report.software_renderer and not str(report.adapter.name).is_empty()
	if not report.success:
		report.failure_reason = "headless_has_no_gpu_evidence" if report.headless else "framebuffer_validation_failed"
	_finish(path, report)


func _base_report() -> Dictionary:
	var headless: bool = DisplayServer.get_name() == "headless"
	var adapter_name: String = RenderingServer.get_video_adapter_name()
	var vendor: String = RenderingServer.get_video_adapter_vendor()
	var api: String = RenderingServer.get_video_adapter_api_version()
	var driver: String = RenderingServer.get_current_rendering_driver_name()
	var description: String = (adapter_name + " " + vendor + " " + api).to_lower()
	var software: bool = RenderingServer.get_video_adapter_type() == RenderingDevice.DEVICE_TYPE_CPU
	for marker: String in ["llvmpipe", "softpipe", "lavapipe", "swiftshader", "software rasterizer", "basic render driver", "microsoft basic"]:
		software = software or marker in description
	var engine_args: PackedStringArray = OS.get_cmdline_args()
	var angle_requested: bool = "opengl3_angle" in engine_args or "--rendering-driver=opengl3_angle" in engine_args
	var parent: Node = get_parent()
	return {"schema": SCHEMA, "success": false, "hardware_verified": false,
		"headless": headless, "software_renderer": software, "rendered_frames": 0,
		"adapter": {"name": adapter_name, "vendor": vendor, "api_version": api,
			"device_type": RenderingServer.get_video_adapter_type()},
		"driver_info": Array(OS.get_video_adapter_driver_info()) if not headless else [],
		"display_server": DisplayServer.get_name(), "rendering_driver": driver,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"angle_detected": driver == "opengl3_angle" or "angle" in description,
		"angle_requested": angle_requested, "external_profile": GraphicsScript.launch_profile_name(),
		"neural_rendering_verified": false, "requested_frames": int(options.get("frames", 120)),
		"msaa_samples": _msaa_samples(get_viewport().msaa_3d), "render_scale": get_viewport().scaling_3d_scale,
		"viewport_size": [get_tree().root.size.x, get_tree().root.size.y], "draw_calls": 0,
		"elapsed_seconds": 0.0, "frame_validation": _validate_frames(null, null), "limits": _device_limits(),
		"campaign_loaded": is_instance_valid(parent.get("current_level")),
		"media_loaded": not parent.get("media").is_empty(),
		"save_loaded": parent.get("state") != null,
		"engine": Engine.get_version_info().string, "failure_reason": ""}


func _build_fixture() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("102b40")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.8
	add_child(environment)
	var camera := Camera3D.new()
	camera.position = Vector3(4.0, 3.0, 6.0)
	add_child(camera)
	camera.look_at(Vector3(0.0, 0.6, 0.0))
	camera.current = true
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(12.0, 12.0)
	_add_mesh(floor_mesh, Vector3.ZERO, Color("366654"))
	var box := BoxMesh.new()
	box.size = Vector3(1.7, 1.7, 1.7)
	_moving_mesh = _add_mesh(box, Vector3(0.0, 1.35, 0.0), Color("f5a331"))
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	_add_mesh(sphere, Vector3(-2.0, 0.5, 0.4), Color("45bed8"))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -20.0, 0.0)
	light.light_energy = 0.7
	add_child(light)


func _add_mesh(mesh: Mesh, location: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = location
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	node.material_override = material
	add_child(node)
	return node


static func _validate_frames(first_image: Image, last_image: Image) -> Dictionary:
	var result: Dictionary = {"valid": false, "width": 0, "height": 0, "sample_colors": 0,
		"changed_samples": 0, "first_sha256": "", "last_sha256": ""}
	if first_image == null or last_image == null or first_image.is_empty() or last_image.is_empty():
		return result
	result.width = last_image.get_width()
	result.height = last_image.get_height()
	var first: Image = first_image.duplicate()
	var last: Image = last_image.duplicate()
	first.convert(Image.FORMAT_RGB8)
	last.convert(Image.FORMAT_RGB8)
	first.resize(SAMPLE_SIZE.x, SAMPLE_SIZE.y, Image.INTERPOLATE_NEAREST)
	last.resize(SAMPLE_SIZE.x, SAMPLE_SIZE.y, Image.INTERPOLATE_NEAREST)
	var first_bytes: PackedByteArray = first.get_data()
	var last_bytes: PackedByteArray = last.get_data()
	result.first_sha256 = _sha256(first_bytes)
	result.last_sha256 = _sha256(last_bytes)
	var colors: Dictionary = {}
	for index: int in range(0, last_bytes.size(), 3):
		var color: int = int(last_bytes[index]) << 16 | int(last_bytes[index + 1]) << 8 | int(last_bytes[index + 2])
		colors[color] = true
		if first_bytes[index] != last_bytes[index] or first_bytes[index + 1] != last_bytes[index + 1] or first_bytes[index + 2] != last_bytes[index + 2]:
			result.changed_samples += 1
	result.sample_colors = colors.size()
	result.valid = result.width >= MIN_SIZE.x and result.height >= MIN_SIZE.y and result.sample_colors >= 4 and result.changed_samples >= 3
	return result


static func _sha256(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()


static func _device_limits() -> Dictionary:
	var device: RenderingDevice = RenderingServer.get_rendering_device()
	if device == null:
		return {"available": false, "reason": "rendering_device_limits_not_exposed_by_this_driver"}
	return {"available": true,
		"max_texture_2d": device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D),
		"max_framebuffer_width": device.limit_get(RenderingDevice.LIMIT_MAX_FRAMEBUFFER_WIDTH),
		"max_framebuffer_height": device.limit_get(RenderingDevice.LIMIT_MAX_FRAMEBUFFER_HEIGHT)}


static func _msaa_samples(mode: Viewport.MSAA) -> int:
	return {Viewport.MSAA_DISABLED: 0, Viewport.MSAA_2X: 2, Viewport.MSAA_4X: 4, Viewport.MSAA_8X: 8}.get(mode, 0)


func _finish(path: String, report: Dictionary) -> void:
	# Never replace an existing user file, and never emit a report without the flag.
	var write_error: String = _write_report(path, report)
	if not write_error.is_empty():
		print("GRAPHICS_PROBE success=false reason=", write_error)
		get_tree().quit(2)
		return
	print("GRAPHICS_PROBE success=", report.success, " hardware_verified=", report.hardware_verified,
		" driver=", report.rendering_driver, " frames=", report.rendered_frames)
	get_tree().quit(0 if report.success else 2)


static func _write_report(path: String, report: Dictionary) -> String:
	var error: String = output_path_error(path)
	if not error.is_empty():
		return error
	var temporary: String = path + ".tmp." + str(OS.get_process_id())
	if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary):
		return "graphics_probe_temporary_already_exists"
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return "graphics_probe_write_failed"
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.flush()
	var succeeded: bool = file.get_error() == OK
	file.close()
	if not succeeded or not output_path_error(path).is_empty():
		DirAccess.remove_absolute(temporary)
		return "graphics_probe_write_failed"
	if DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)
		return "graphics_probe_publish_failed"
	return ""
