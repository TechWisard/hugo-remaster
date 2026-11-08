extends SceneTree
## Decode a real imported cutscene, preserve its aspect ratio and skip once.
## A rendering driver is required for the video texture check.

const MovieScript = preload("res://scripts/cinematic.gd")
var finished_count: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	RemasterInput.configure()
	if not FileAccess.file_exists("res://assets/generated/media_manifest.json"):
		print("SKIP imported media unavailable")
		quit(0)
		return
	if AudioServer.get_bus_index("Effects") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "Effects")
	var media: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/media_manifest.json"))
	var info: Dictionary = media.get("movies", {}).get("intro_a", {})
	if info.is_empty():
		print("SKIP intro movie unavailable")
		quit(0)
		return
	var movie: CampaignCinematic = MovieScript.new()
	movie.stream_path = "res://assets/generated/" + str(info.path)
	movie.aspect_ratio = float(info.width) / float(info.height)
	movie.finished.connect(func() -> void: finished_count += 1)
	root.add_child(movie)
	for i: int in range(90):
		await process_frame
	var result: Dictionary = {"playing": movie._video.is_playing(), "position": movie._video.stream_position,
		"aspect": movie.aspect_ratio, "texture_width": 0, "texture_height": 0}
	var texture: Texture2D = movie._video.get_video_texture()
	if texture:
		result.texture_width = texture.get_width()
		result.texture_height = texture.get_height()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture=") and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(argument.trim_prefix("--capture="))
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_SPACE
	event.physical_keycode = KEY_SPACE
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	result["finished_count"] = finished_count
	result["closed"] = not is_instance_valid(movie)
	var good: bool = result.playing and result.position > 0.0 and finished_count == 1 and result.closed
	if DisplayServer.get_name() != "headless":
		good = good and result.texture_width == int(info.width) and result.texture_height == int(info.height)
	print("MEDIA_SMOKE ", JSON.stringify(result), " PASS=", good)
	quit(0 if good else 1)
