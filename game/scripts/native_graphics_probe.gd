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
	var result: Dictionary = {"requested": false, "path": "", "frames": 120, "error": "", "visual_control": "", "visual_session": ""}
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
		elif argument.begins_with("--graphics-visual-control="):
			result.visual_control = argument.trim_prefix("--graphics-visual-control=")
		elif argument.begins_with("--graphics-visual-session="):
			result.visual_session = argument.trim_prefix("--graphics-visual-session=")
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
		window.title = "Hugo · GPU"
		window.mode = Window.MODE_WINDOWED
		window.size = Vector2i(maxi(window.size.x, MIN_SIZE.x), maxi(window.size.y, MIN_SIZE.y))
	# Probe resolution is diagnostic and must never restore or apply game display preferences.
	GraphicsScript.apply(window, GraphicsScript.defaults(), false)
	_build_fixture()
	if not str(options.get("visual_control", "")).is_empty():
		await _run_visual_handshake(path, report)
		return
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


func _run_visual_handshake(path: String, report: Dictionary) -> void:
	# The Godot image is BEFORE the external ReShade present. The Windows helper
	# independently captures the displayed client area; this hash only proves
	# that its off/on samples had identical native input and a frozen pose.
	var control_path: String = str(options.get("visual_control", ""))
	var session: String = str(options.get("visual_session", ""))
	report.probe_kind = "frozen_visual_handshake"
	report.max_duration_seconds = 180
	if report.headless:
		report.failure_reason = "headless_has_no_gpu_evidence"
		_finish(path, report)
		return
	if not control_path.is_absolute_path() or control_path.begins_with("res://") or control_path.begins_with("user://") or control_path.get_extension().to_lower() != "json" or not FileAccess.file_exists(control_path) or session.length() != 32 or not session.is_valid_hex_number(false):
		report.failure_reason = "invalid_visual_probe_handshake"
		_finish(path, report)
		return
	var window: Window = get_tree().root
	window.title = "Hugo NR image test · " + session.left(8)
	_moving_mesh.rotation = Vector3(0.58, 0.83, 0.1)
	_moving_mesh.position.x = 0.4
	var pose: String = str(_moving_mesh.transform)
	var started: int = Time.get_ticks_msec()
	var last_request: int = 0
	var first_hash: String = ""
	var all_same: bool = true
	var sampled: int = 0
	var frame: int = 0
	while Time.get_ticks_msec() - started < 180000:
		await get_tree().process_frame
		# A frozen scene may not request another draw. Explicitly present it so
		# ReShade keeps receiving identical frames and its temporal state settles.
		RenderingServer.force_draw(true)
		frame += 1
		if frame < 30 or frame % 6 != 0:
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(control_path))
		if not parsed is Dictionary:
			continue
		var control: Dictionary = parsed
		if int(control.get("schema", 0)) != 1 or str(control.get("session", "")) != session:
			continue
		if str(control.get("command", "")) == "finish":
			report.success = sampled >= 2 and all_same
			report.hardware_verified = report.success and not report.software_renderer
			report.failure_reason = "" if report.success else "visual_probe_native_input_not_verified"
			break
		var request: int = int(control.get("request", 0))
		if str(control.get("command", "")) != "sample" or request <= last_request or request > 32:
			continue
		var picture: Image = window.get_texture().get_image()
		if picture == null or picture.is_empty():
			continue
		var digest: String = _sha256(picture.get_data())
		if first_hash.is_empty():
			first_hash = digest
		all_same = all_same and digest == first_hash and str(_moving_mesh.transform) == pose
		var validation: Dictionary = _validate_frames(picture, picture)
		var native_valid: bool = validation.width >= MIN_SIZE.x and validation.height >= MIN_SIZE.y and validation.sample_colors >= 4
		all_same = all_same and native_valid
		var response_path: String = path.get_base_dir().path_join("native-frame-%03d.json" % request)
		var response: Dictionary = {"schema": 1, "session": session, "process_id": OS.get_process_id(), "request": request,
			"fixture": "frozen_renderer_v1", "pose": pose, "native_framebuffer_sha256": digest,
			"native_image_format": picture.get_format(), "native_size": [picture.get_width(), picture.get_height()],
			"native_framebuffer_valid": native_valid, "frame_serial": frame, "window_focused": window.has_focus(),
			"updated_utc": Time.get_datetime_string_from_system(true) + "Z", "capture_stage": "godot_viewport_before_external_present",
			"display_output_verified": false}
		var write_error: String = _write_report(response_path, response)
		if not write_error.is_empty():
			report.failure_reason = write_error
			break
		last_request = request
		sampled += 1
	if str(report.failure_reason).is_empty() and not report.success:
		report.failure_reason = "visual_probe_handshake_timeout"
	report.visual_session = session
	report.rendered_frames = frame
	report.frozen_pose = pose
	report.native_input_samples = sampled
	report.native_inputs_identical = all_same
	report.native_framebuffer_sha256 = first_hash
	report.elapsed_seconds = (Time.get_ticks_msec() - started) / 1000.0
	report.display_output_verified = false
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
