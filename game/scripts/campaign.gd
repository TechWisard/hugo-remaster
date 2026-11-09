class_name HugoCampaign
extends Node3D

const LevelScript = preload("res://scripts/original_level.gd")
const MenuScript = preload("res://scripts/campaign_menu.gd")
const StateScript = preload("res://scripts/campaign_state.gd")
const MovieScript = preload("res://scripts/cinematic.gd")
const GraphicsScript = preload("res://scripts/native_graphics_settings.gd")
const GraphicsProbeScript = preload("res://scripts/native_graphics_probe.gd")
const Localizer = preload("res://scripts/native_localization.gd")
const TextBindings = preload("res://scripts/native_text_bindings.gd")
const VoiceLibrary = preload("res://scripts/native_voice_library.gd")
const SoundScript = preload("res://scripts/native_audio.gd")
const ResourceData = preload("res://scripts/native_resource_data.gd")
const PerformanceMonitor = preload("res://scripts/native_performance_monitor.gd")
const MOVIES_AFTER: Dictionary = {17: ["plan_on_track"], 36: ["more_power_1"],
	46: ["more_power_2"], 59: ["lost_juice"], 69: ["outro"]}
const MOVIES_BEFORE: Dictionary = {6: ["intro_b"], 27: ["plan_on_track"],
	46: ["more_power_1"], 55: ["more_power_2"], 69: ["lost_juice"]}

var state: CampaignState
var levels: Array[Dictionary] = []
var current_level: OriginalLevel
var current_index: int = -1
var menu: CampaignMenu
var media: Dictionary = {}
var gameplay: Dictionary = {}
var _music: AudioStreamPlayer
var _loading: CanvasLayer
var _transitioning: bool = false
var _capture_requested: String = ""
var _last_display_options: Dictionary = {}
var _display_preview_options: Dictionary = {}
var _display_dialog: ConfirmationDialog
var _display_confirmation_timer: Timer
var _window_resize_timer: Timer
var _ignore_window_resize_until: int = 0
var _keep_startup_window: bool = false
var _display_preview_window: Dictionary = {}
var _text_bindings := TextBindings.new()
var _locale_ready: bool = false
var _loading_label: Label
var _loading_group: int = -1


func _ready() -> void:
	# The launcher must inspect this renderer before any save, media or level loads.
	var probe_options: Dictionary = GraphicsProbeScript.parse_arguments(OS.get_cmdline_user_args())
	if probe_options.requested:
		set_process_unhandled_input(false)
		var probe := GraphicsProbeScript.new()
		probe.options = probe_options
		add_child(probe)
		return
	RemasterInput.configure()
	_configure_audio()
	_load_catalog()
	state = StateScript.new()
	var ids: Array[String] = []
	for entry: Dictionary in levels:
		ids.append(str(entry.id))
	state.read_save(ids)
	_apply_startup_settings()
	PerformanceMonitor.attach_if_requested(self)
	_setup_window_tracking()
	var selected: String = ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--level="):
			selected = argument.trim_prefix("--level=")
		elif argument.begins_with("--capture="):
			_capture_requested = argument.trim_prefix("--capture=")
	if "--test-course" in OS.get_cmdline_user_args():
		_start_demo.call_deferred()
	elif not selected.is_empty():
		_start_level.call_deferred(selected, false)
	elif not _capture_requested.is_empty():
		_show_menu()
		_capture.call_deferred()
	else:
		_boot.call_deferred()


func _boot() -> void:
	_transitioning = true
	await _play_movies(["logo", "intro_a"])
	_transitioning = false
	_show_menu()


func _load_catalog() -> void:
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	for raw: Variant in catalog.get("levels", []):
		if not raw is Dictionary:
			continue
		var entry: Dictionary = raw.duplicate(true)
		if not entry.has("id") or not entry.has("geometry_path") or not entry.has("manifest_path"):
			continue
		var main_group: int = int(entry.get("main_group", -1))
		entry["title"] = Localizer.chapter_title(main_group, str(entry.get("source_name", "")))
		levels.append(entry)
	media = _json("res://assets/generated/media_manifest.json")
	gameplay = _json("res://assets/generated/gameplay_manifest.json")
	SoundScript.configure_catalog(gameplay.get("audio", {}) as Dictionary)


func _show_menu() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(menu):
		menu.queue_free()
	if is_instance_valid(current_level):
		_store_run(current_level.run_state())
		current_level.process_mode = Node.PROCESS_MODE_DISABLED
		current_level.hud.hide()
		current_level.hud.process_mode = Node.PROCESS_MODE_DISABLED
	menu = MenuScript.new()
	menu.entries = levels
	menu.state = state
	menu.start_requested.connect(_select_chapter)
	menu.new_game_requested.connect(_new_game)
	menu.demo_requested.connect(_start_demo)
	menu.settings_changed.connect(_apply_settings)
	menu.display_preview_requested.connect(_preview_display)
	add_child(menu)
	_play_music_track(2)


func _new_game() -> void:
	if levels.is_empty() or _transitioning:
		return
	state.clear_campaign(str(levels[0].id))
	state.write_save()
	_transitioning = true
	if is_instance_valid(menu):
		menu.queue_free()
	await _play_movies(["intro_b"])
	_transitioning = false
	_start_level(str(levels[0].id), false)


func _select_chapter(id: String, resume: bool) -> void:
	if _transitioning:
		return
	if not resume:
		var group: int = -1
		for entry: Dictionary in levels:
			if str(entry.id) == id:
				group = int(entry.get("main_group", -1))
				break
		_transitioning = true
		if is_instance_valid(menu):
			menu.queue_free()
		await _play_movies(MOVIES_BEFORE.get(group, []))
		_transitioning = false
	_start_level(id, resume)


func _start_level(id: String, resume: bool) -> void:
	if _transitioning:
		return
	var index: int = -1
	for i: int in range(levels.size()):
		if str(levels[i].id) == id or str(levels[i].get("main_group", "")) == id:
			index = i
			break
	if index < 0:
		push_error("Unknown original chapter: " + id)
		_show_menu()
		return
	_transitioning = true
	get_tree().paused = false
	if is_instance_valid(menu):
		menu.queue_free()
	_loading_group = int(levels[index].get("main_group", -1))
	_show_loading(str(levels[index].title))
	await get_tree().process_frame
	if is_instance_valid(current_level):
		current_level.queue_free()
		await get_tree().process_frame
	current_index = index
	var entry: Dictionary = levels[index]
	current_level = LevelScript.new()
	current_level.name = "Original_" + str(entry.id)
	current_level.entry = entry
	current_level.data = _json("res://assets/generated/" + str(entry.manifest_path))
	current_level.gameplay = gameplay.get("levels", {}).get(str(entry.id), {})
	current_level.native_rules = gameplay.get("native_rules", {})
	current_level.difficulty = state.difficulty
	current_level.qualified_level_count = state.qualified_levels.size()
	current_level.starting_lives = state.total_lives if state.total_lives > 0 else 4
	current_level.chapter_number = index + 1
	current_level.has_next = index + 1 < levels.size()
	if resume:
		current_level.restored_run = state.runs.get(str(entry.id), {})
	else:
		state.runs.erase(str(entry.id))
	current_level.progress_changed.connect(_store_run)
	current_level.menu_requested.connect(_show_menu.call_deferred)
	current_level.restart_requested.connect(func() -> void: _start_level.call_deferred(str(entry.id), false))
	current_level.next_requested.connect(_next_level)
	current_level.level_finished.connect(_on_level_finished)
	add_child(current_level)
	state.set_run(str(entry.id), current_level.run_state())
	state.write_save()
	_play_level_music()
	if is_instance_valid(_loading):
		_loading.queue_free()
	_transitioning = false
	if not _capture_requested.is_empty():
		_capture.call_deferred()


func _next_level() -> void:
	if _transitioning or current_index < 0:
		return
	_transitioning = true
	get_tree().paused = false
	current_level.process_mode = Node.PROCESS_MODE_DISABLED
	current_level.hud.hide()
	var group: int = int(levels[current_index].get("main_group", -1))
	await _play_movies(MOVIES_AFTER.get(group, []))
	_transitioning = false
	if current_index + 1 < levels.size():
		_start_level(str(levels[current_index + 1].id), false)
	else:
		_show_credits()


func _on_level_finished() -> void:
	if current_index < 0:
		return
	state.completed_levels[str(levels[current_index].id)] = true
	var total: int = current_level.total_diamonds
	var rules: Dictionary = gameplay.get("native_rules", {})
	var eligible: Array = rules.get("health_bonus_eligible_level_indices", [0, 1, 2, 3, 4, 5, 6])
	var health_bonus_eligible: bool = false
	# JSON numbers are floats; Array.has/in compares their Variant types.
	for value: Variant in eligible:
		if int(value) == current_index:
			health_bonus_eligible = true
			break
	var checkpoints: Array = current_level.gameplay.get("checkpoints", [])
	var visited: int = 0
	for id: String in checkpoints:
		if current_level.activated.has(id):
			visited += 1
	if not current_level.finish_rewards_applied:
		if health_bonus_eligible:
			var chapter_id: String = str(levels[current_index].id)
			if total > 0 and floori(float(current_level.diamonds) * 100.0 / float(total)) >= 90:
				state.qualified_levels[chapter_id] = true
			else:
				state.qualified_levels.erase(chapter_id)
		if visited == checkpoints.size():
			current_level.lives = mini(current_level.lives + int(rules.get("all_checkpoints_finish_life_bonus", 1)), 20)
		current_level.finish_rewards_applied = true
	current_level.hud.set_finish_stats(current_level.diamonds, total, visited, checkpoints.size())
	current_level._update_hud()
	_store_run(current_level.run_state())
	if current_index == levels.size() - 1:
		# The final chapter still has a real continuation: the original outro.
		current_level.hud.has_next_chapter = true
		current_level.hud.set_finale(true)
		current_level.hud.next_button.show()
		current_level.hud.next_button.grab_focus()


func _store_run(run: Dictionary) -> void:
	if current_index < 0 or current_index >= levels.size():
		return
	state.set_run(str(levels[current_index].id), run)
	if not state.write_save() and is_instance_valid(current_level) and current_level.hud:
		current_level.hud.toast_key(state.last_error_key, state.last_error_arguments, 5.0)


func _play_movies(keys: Array) -> void:
	_music.stop()
	for key: String in keys:
		var movie_info: Dictionary = VoiceLibrary.resolve_movie(key, media.get("movies", {}).get(key, {}))
		if not bool(movie_info.get("available", false)):
			continue
		var movie := MovieScript.new()
		movie.movie_key = key
		movie.voice_info = movie_info
		movie.stream_path = str(movie_info.path)
		movie.aspect_ratio = float(movie_info.get("width", 320)) / maxf(float(movie_info.get("height", 160)), 1.0)
		add_child(movie)
		await movie.finished


func _play_level_music() -> void:
	if current_level == null:
		return
	var track: int = int(current_level.gameplay.get("music", {}).get("track", -1))
	_play_music_track(track)


func _play_music_track(track: int) -> void:
	_music.stop()
	var info: Dictionary = media.get("music", {}).get(str(track), {})
	if info.is_empty():
		return
	var path: String = "res://assets/generated/" + str(info.path)
	if ResourceLoader.exists(path):
		_music.stream = load(path) as AudioStream
		if _music.stream is AudioStreamOggVorbis:
			(_music.stream as AudioStreamOggVorbis).loop = true
		_music.play()


func _configure_audio() -> void:
	for title: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(title) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, title)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_music)


func _apply_startup_settings() -> void:
	_keep_startup_window = GraphicsScript.keep_startup_window_requested()
	_apply_settings(false, not _keep_startup_window)


func _apply_settings(persist: bool = true, manage_window: bool = true) -> void:
	if not Localizer.events().language_changed.is_connected(_refresh_language):
		Localizer.events().language_changed.connect(_refresh_language)
	state.settings.text_locale = Localizer.sanitize_locale(state.settings.get("text_locale", "ru"))
	state.settings.voice_locale = Localizer.sanitize_voice_locale(state.settings.get("voice_locale", "ru"))
	Localizer.set_text_locale(str(state.settings.text_locale))
	VoiceLibrary.set_locale(str(state.settings.voice_locale))
	if not _locale_ready:
		_refresh_language(Localizer.get_text_locale())
		_locale_ready = true
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(float(state.settings.music_volume), 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Effects"), linear_to_db(maxf(float(state.settings.effects_volume), 0.0001)))
	var options: Dictionary = GraphicsScript.sanitize(state.settings.get("graphics", {}))
	var display: Dictionary = GraphicsScript.display_options(options)
	var display_changed: bool = display != _last_display_options
	if display_changed:
		_ignore_window_resize_until = Time.get_ticks_msec() + 500
	state.settings["graphics"] = GraphicsScript.apply(get_viewport(), options, manage_window and display_changed)
	state.settings.fullscreen = options.display_mode != "windowed"
	_last_display_options = display
	if persist:
		state.write_save()


func _setup_window_tracking() -> void:
	if _window_resize_timer != null:
		return
	_window_resize_timer = Timer.new()
	_window_resize_timer.one_shot = true
	_window_resize_timer.wait_time = 0.5
	_window_resize_timer.ignore_time_scale = true
	_window_resize_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_window_resize_timer.timeout.connect(_remember_window_size)
	add_child(_window_resize_timer)
	get_tree().root.size_changed.connect(_on_window_size_changed)


func _on_window_size_changed() -> void:
	if _window_resize_timer != null and Time.get_ticks_msec() >= _ignore_window_resize_until:
		_window_resize_timer.start()


func _remember_window_size() -> void:
	if state == null or not _display_preview_options.is_empty() or DisplayServer.get_name() == "headless" \
			or Time.get_ticks_msec() < _ignore_window_resize_until:
		return
	# A temporary launcher/capture window must not silently replace saved choices.
	# Explicitly confirming a display change below ends this temporary override.
	if _keep_startup_window:
		return
	var window: Window = get_tree().root
	if state.settings.graphics.display_mode != "windowed" or window.mode != Window.MODE_WINDOWED:
		return
	if window.size.x < GraphicsScript.MIN_WINDOW_SIZE.x or window.size.y < GraphicsScript.MIN_WINDOW_SIZE.y:
		return
	state.settings.graphics.window_width = window.size.x
	state.settings.graphics.window_height = window.size.y
	_last_display_options = GraphicsScript.display_options(state.settings.graphics)
	state.write_save()
	if is_instance_valid(menu):
		menu.refresh_display_controls()


func _preview_display(requested: Dictionary) -> void:
	if not _display_preview_options.is_empty():
		_finish_display_preview(false)
	if _keep_startup_window:
		var window: Window = get_tree().root
		_display_preview_window = {"mode": window.mode, "size": window.size,
			"position": window.position, "borderless": window.borderless}
	var options: Dictionary = GraphicsScript.sanitize(state.settings.graphics)
	var display: Dictionary = GraphicsScript.display_options(requested)
	options.merge(display, true)
	_display_preview_options = display
	_ignore_window_resize_until = Time.get_ticks_msec() + 500
	GraphicsScript.apply(get_viewport(), options)
	# Committed preferences remain unchanged throughout preview. A gameplay
	# autosave or closing the process therefore cannot persist an unseen mode.
	_display_dialog = ConfirmationDialog.new()
	_display_dialog.name = "DisplayConfirmation"
	_display_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_text_bindings.bind_property(_display_dialog, "title", "display.confirm_title")
	_text_bindings.bind_property(_display_dialog, "ok_button_text", "display.keep")
	_text_bindings.bind_property(_display_dialog, "cancel_button_text", "display.revert")
	_text_bindings.bind_property(_display_dialog, "dialog_text", "display.confirm")
	_display_dialog.confirmed.connect(_finish_display_preview.bind(true))
	_display_dialog.canceled.connect(_finish_display_preview.bind(false))
	add_child(_display_dialog)
	_display_dialog.popup_centered(Vector2i(510, 180))
	_display_confirmation_timer = Timer.new()
	_display_confirmation_timer.name = "DisplayConfirmationTimer"
	_display_confirmation_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_display_confirmation_timer.one_shot = true
	_display_confirmation_timer.wait_time = 15.0
	_display_confirmation_timer.ignore_time_scale = true
	_display_confirmation_timer.timeout.connect(_finish_display_preview.bind(false))
	add_child(_display_confirmation_timer)
	_display_confirmation_timer.start()
	_update_display_confirmation.call_deferred()


func _update_display_confirmation() -> void:
	await get_tree().process_frame
	if not is_instance_valid(_display_dialog) or _display_preview_options.is_empty():
		return
	var size: Vector2i = get_tree().root.size
	_text_bindings.bind_property(_display_dialog, "dialog_text", "display.confirm_actual", {"width": size.x, "height": size.y})


func _finish_display_preview(accepted: bool) -> void:
	if _display_preview_options.is_empty():
		return
	if accepted:
		state.settings.graphics.merge(_display_preview_options, true)
		state.settings.fullscreen = state.settings.graphics.display_mode != "windowed"
		state.write_save()
		_keep_startup_window = false
	_display_preview_options = {}
	_ignore_window_resize_until = Time.get_ticks_msec() + 500
	var restore_startup: bool = _keep_startup_window and not _display_preview_window.is_empty()
	GraphicsScript.apply(get_viewport(), state.settings.graphics, not restore_startup)
	if restore_startup and DisplayServer.get_name() != "headless":
		var window: Window = get_tree().root
		var previous_mode: int = int(_display_preview_window.mode)
		window.mode = previous_mode
		if previous_mode == Window.MODE_WINDOWED:
			window.borderless = bool(_display_preview_window.borderless)
			window.size = _display_preview_window.size
			window.position = _display_preview_window.position
	_display_preview_window = {}
	_last_display_options = GraphicsScript.display_options(state.settings.graphics)
	if is_instance_valid(_display_confirmation_timer):
		_display_confirmation_timer.stop()
		_display_confirmation_timer.queue_free()
		_display_confirmation_timer = null
	if is_instance_valid(_display_dialog):
		_display_dialog.hide()
		_display_dialog.queue_free()
		_display_dialog = null
	if is_instance_valid(menu):
		menu.refresh_display_controls()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		var display: Dictionary = GraphicsScript.display_options(state.settings.graphics)
		var is_fullscreen: bool = display.display_mode != "windowed"
		if DisplayServer.get_name() != "headless":
			is_fullscreen = get_tree().root.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]
		display.display_mode = "windowed" if is_fullscreen else "fullscreen"
		_preview_display(display)
		get_viewport().set_input_as_handled()


func _start_demo() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _show_loading(title: String) -> void:
	_loading = CanvasLayer.new()
	_loading.layer = 40
	add_child(_loading)
	var panel := ColorRect.new()
	panel.color = Color("10242c")
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_loading.add_child(panel)
	var label := Label.new()
	_loading_label = label
	_text_bindings.bind_property(label, "text", "loading.chapter", {"chapter": title})
	label.add_theme_font_size_override("font_size", 34)
	label.add_theme_color_override("font_color", Color("f6cf80"))
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)


func _show_credits() -> void:
	_show_menu()
	var info: Dictionary = media.get("credits", {})
	if info.is_empty():
		return
	var path: String = "res://assets/generated/" + str(info.path)
	if not FileAccess.file_exists(path):
		return
	var dialog := AcceptDialog.new()
	_text_bindings.bind_property(dialog, "title", "credits.title")
	_text_bindings.bind_property(dialog, "ok_button_text", "credits.menu")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(620, 430)
	dialog.add_child(scroll)
	var text := Label.new()
	text.text = FileAccess.get_file_as_string(path)
	text.add_theme_font_size_override("font_size", 16)
	scroll.add_child(text)
	add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.popup_centered()


func _refresh_language(_locale: String) -> void:
	get_tree().root.title = Localizer.text("app.title")
	for entry: Dictionary in levels:
		entry["title"] = Localizer.chapter_title(int(entry.get("main_group", -1)), str(entry.get("source_name", "")))
	_text_bindings.refresh()
	if is_instance_valid(_loading_label):
		_text_bindings.bind_property(_loading_label, "text", "loading.chapter", {"chapter": Localizer.chapter_title(_loading_group)})


func _json(path: String) -> Dictionary:
	return ResourceData.read(path)

func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if is_instance_valid(current_level) and "--overview" in OS.get_cmdline_user_args():
		var overview := Camera3D.new()
		add_child(overview)
		var bounds: AABB = current_level.scene_bounds
		var center: Vector3 = bounds.get_center()
		var distance: float = maxf(bounds.size.x, bounds.size.z) * 0.7
		overview.position = center + Vector3(distance * 0.2, distance * 0.8, distance * 0.7)
		overview.look_at(center)
		overview.far = distance * 10.0
		overview.current = true
	for i: int in range(25):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var picture: Image = get_viewport().get_texture().get_image()
	var error: Error = picture.save_png(_capture_requested)
	print("CAPTURE ", _capture_requested, " status=", error)
	get_tree().quit(0 if error == OK else 1)
