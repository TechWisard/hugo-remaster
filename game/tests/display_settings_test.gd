extends SceneTree
## Real menu preview -> cancel/timed rollback/confirm -> save -> reconstructed UI.

const TEST_PATH: String = "user://display_settings_test.json"
var checks: int = 0
var failures: Array[String] = []


class Harness extends HugoCampaign:
	var loaded: CampaignState
	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		state = loaded if loaded != null else CampaignState.new()
		state.path = TEST_PATH
		_apply_settings(false)
		_setup_window_tracking()
		_show_menu()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	var game := Harness.new()
	root.add_child(game)
	await process_frame
	game.menu._show_options()
	var mode: OptionButton = game.menu.find_child("DisplayMode", true, false) as OptionButton
	var resolution: OptionButton = game.menu.find_child("DisplayResolution", true, false) as OptionButton
	var apply: Button = game.menu.find_child("ApplyDisplay", true, false) as Button
	_check(mode != null and resolution != null and apply != null, "the real settings menu exposes window mode, size and preview")
	_check(mode.item_count == 3, "window, borderless and exclusive fullscreen are selectable")
	for size: Vector2i in [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(3440, 1440), Vector2i(1920, 1200)]:
		_check(_find_resolution(resolution, size) >= 0, "the menu includes %d x %d" % [size.x, size.y])
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND,
		"the actual root uses native 3D and uniform expanding UI scaling")
	_check(root.content_scale_size == Vector2i(1280, 720) and root.gui_embed_subwindows and not root.unresizable,
		"UI keeps its logical baseline, embeds dialogs and allows resizing")
	_check(game.state.write_save(), "baseline display preferences are written to the isolated save")
	var baseline: String = FileAccess.get_file_as_string(TEST_PATH)
	_select(resolution, _find_resolution(resolution, Vector2i(3840, 2160)))
	_check(game.state.settings.graphics.window_width == 0, "editing the picker changes only its draft")
	apply.pressed.emit()
	await process_frame
	_check(game._display_dialog != null and not game._display_preview_options.is_empty(), "Apply opens a live preview confirmation")
	_check(game._display_confirmation_timer.wait_time == 15.0 and game._display_confirmation_timer.ignore_time_scale,
		"the real preview timeout is fifteen wall-clock seconds")
	_check(game.state.settings.graphics.window_width == 0 and FileAccess.get_file_as_string(TEST_PATH) == baseline,
		"an unconfirmed mode does not reach campaign settings or the save")
	game.state.write_save()
	var during := CampaignState.new()
	during.path = TEST_PATH
	_check(during.read_save([]) and during.settings.graphics.window_width == 0, "an autosave during preview retains the committed mode")
	game._display_dialog.canceled.emit()
	await process_frame
	_check(game._display_preview_options.is_empty() and game.state.settings.graphics.window_width == 0,
		"Cancel restores the committed settings and ends preview")
	_check(resolution.selected == 0, "cancelled UI returns to its committed automatic size")
	_select(mode, 2)
	_check(resolution.disabled, "fullscreen honestly uses the monitor rather than an ignored window size")
	apply.pressed.emit()
	await process_frame
	game._display_confirmation_timer.start(0.05)
	paused = true
	Engine.time_scale = 0.0
	await create_timer(0.12, true, false, true).timeout
	Engine.time_scale = 1.0
	paused = false
	_check(game._display_preview_options.is_empty() and game._display_dialog == null,
		"preview automatically reverts while the game is paused with time_scale zero")
	_check(game.state.settings.graphics.display_mode == "windowed" and not game.state.settings.fullscreen,
		"timed rollback never commits the temporary fullscreen mode")
	_select(resolution, resolution.item_count - 1)
	var width: SpinBox = game.menu.find_child("DisplayWidth", true, false) as SpinBox
	var height: SpinBox = game.menu.find_child("DisplayHeight", true, false) as SpinBox
	width.value = 3000
	height.value = 1250
	apply.pressed.emit()
	await process_frame
	_check(game._display_preview_options.window_width == 3000 and game._display_preview_options.window_height == 1250,
		"arbitrary ultrawide dimensions travel through the actual UI")
	game._display_dialog.confirmed.emit()
	await process_frame
	var loaded := CampaignState.new()
	loaded.path = TEST_PATH
	_check(loaded.read_save([]), "confirmed display preferences make a valid save")
	_check(loaded.settings.graphics.window_width == 3000 and loaded.settings.graphics.window_height == 1250 and loaded.settings.graphics.display_mode == "windowed",
		"confirmed custom size survives disk serialization")
	game.free()
	await process_frame
	game = Harness.new()
	game.loaded = loaded
	root.add_child(game)
	await process_frame
	game.menu._show_options()
	resolution = game.menu.find_child("DisplayResolution", true, false) as OptionButton
	width = game.menu.find_child("DisplayWidth", true, false) as SpinBox
	height = game.menu.find_child("DisplayHeight", true, false) as SpinBox
	_check(resolution.selected == resolution.item_count - 1 and width.value == 3000 and height.value == 1250,
		"a recreated campaign shows its persisted custom size")
	if DisplayServer.get_name() != "headless":
		await create_timer(0.55).timeout
		root.size = Vector2i(960, 540)
		await create_timer(0.7).timeout
		_check(loaded.read_save([]) and loaded.settings.graphics.window_width == root.size.x and loaded.settings.graphics.window_height == root.size.y,
			"manual window resizing is debounced and persisted from the actual display")
		var resized: Vector2i = root.size
		game._apply_settings(false)
		await process_frame
		_check(root.size == resized, "changing unrelated graphics settings does not reset a manually resized window")
	game.free()
	await process_frame
	var legacy := CampaignState.new()
	legacy.path = TEST_PATH
	legacy.settings.graphics.erase("display_mode")
	legacy.settings.fullscreen = true
	_check(legacy.write_save() and loaded.read_save([]), "legacy v2 fullscreen preferences still load")
	_check(loaded.settings.graphics.display_mode == "fullscreen" and loaded.settings.fullscreen, "legacy fullscreen migrates to the new display setting")
	var invalid: Dictionary = NativeGraphicsSettings.sanitize({"display_mode": "invalid", "window_width": INF, "window_height": -42})
	_check(invalid.display_mode == "windowed" and invalid.window_width == 0 and invalid.window_height == 0,
		"invalid dimensions and modes recover to automatic windowed settings")
	for pair: Array in [[Vector2i(3840, 2160), Vector2i(1920, 1040)], [Vector2i(3440, 1440), Vector2i(2560, 1400)],
			[Vector2i(1920, 1200), Vector2i(1920, 1200)], [Vector2i(3840, 2160), Vector2i(1080, 1920)]]:
		var wanted: Vector2i = pair[0]
		var available: Vector2i = pair[1]
		var fitted: Vector2i = NativeGraphicsSettings.fit_window_size(wanted, available)
		_check(fitted.x <= available.x and fitted.y <= available.y and fitted.x > 0 and fitted.y > 0,
			"window fitting keeps %s accessible inside %s" % [wanted, available])
		_check(absf(float(fitted.x) / fitted.y - float(wanted.x) / wanted.y) < 0.003,
			"window fitting preserves the requested aspect ratio for %s" % wanted)
	_cleanup()
	print("DISPLAY_SETTINGS checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _find_resolution(control: OptionButton, size: Vector2i) -> int:
	for index: int in range(control.item_count):
		if control.get_item_metadata(index) == size:
			return index
	return -1


func _select(control: OptionButton, index: int) -> void:
	control.select(index)
	control.item_selected.emit(index)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
