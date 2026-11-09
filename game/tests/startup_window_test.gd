extends SceneTree
## Run with -- --keep-window. GPU runs also pass engine --resolution/--windowed.
## Production startup/preview methods use a separate save; the real PCK is a
## separate integration gate, since headless checks cannot validate a window.

const TEST_PATH: String = "user://startup_window_test.json"
var checks: int = 0
var failures: Array[String] = []


class Harness extends HugoCampaign:
	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		state = CampaignState.new()
		state.path = TEST_PATH
		state.settings.graphics.window_width = 960
		state.settings.graphics.window_height = 540
		_apply_startup_settings()
		_setup_window_tracking()
		_show_menu()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	var initial_size: Vector2i = root.size
	var initial_mode: int = root.mode
	_check(NativeGraphicsSettings.keep_startup_window_requested(), "the explicit user flag survives engine argument consumption")
	var game := Harness.new()
	root.add_child(game)
	await process_frame
	_check(game._keep_startup_window, "production startup enables the temporary window override")
	_check(root.size == initial_size and root.mode == initial_mode, "startup preserves the actual engine-initialized window")
	_check(game.state.settings.graphics.window_width == 960 and game.state.settings.graphics.window_height == 540,
		"temporary startup does not replace committed display preferences")
	_check(game.state.write_save(), "the regression uses its own valid save")
	var original_save: String = FileAccess.get_file_as_string(TEST_PATH)
	game.state.settings.graphics.msaa = 2
	game._apply_settings(false)
	await process_frame
	_check(root.size == initial_size and root.mode == initial_mode, "changing AA leaves the temporary window intact")
	_check(root.msaa_3d == Viewport.MSAA_2X, "ordinary graphics settings still apply")
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_WINDOWED
		root.size = Vector2i(1000, 562)
		game._ignore_window_resize_until = 0
		game._on_window_size_changed()
		await create_timer(0.65).timeout
		_check(FileAccess.get_file_as_string(TEST_PATH) == original_save,
			"resizing a temporary window does not silently persist it")
		_check(game.state.settings.graphics.window_width == 960,
			"temporary resize leaves in-memory committed preferences unchanged")
	var before_preview_size: Vector2i = root.size
	var before_preview_mode: int = root.mode
	var request: Dictionary = NativeGraphicsSettings.display_options(game.state.settings.graphics)
	request.window_width = 1920
	request.window_height = 1080
	game._preview_display(request)
	await process_frame
	_check(game._display_dialog != null, "the actual display preview still opens")
	game._display_dialog.canceled.emit()
	await process_frame
	_check(game._keep_startup_window and game._display_preview_options.is_empty(), "cancel retains the startup override")
	_check(root.size == before_preview_size and root.mode == before_preview_mode,
		"cancel restores the actual temporary window rather than saved dimensions")
	_check(FileAccess.get_file_as_string(TEST_PATH) == original_save, "cancel does not rewrite the user's display choice")
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_FULLSCREEN
		await process_frame
		await process_frame
		var fullscreen_mode: int = root.mode
		var event := InputEventKey.new()
		event.pressed = true
		event.keycode = KEY_F11
		game._unhandled_input(event)
		await process_frame
		_check(game._display_preview_options.display_mode == "windowed",
			"first F11 exits actual fullscreen even when saved preferences are windowed")
		game._display_dialog.canceled.emit()
		await process_frame
		_check(root.mode == fullscreen_mode, "cancelling F11 restores the actual startup fullscreen mode")
	request.window_width = 1280
	request.window_height = 720
	game._preview_display(request)
	await process_frame
	game._display_dialog.confirmed.emit()
	await process_frame
	_check(not game._keep_startup_window, "explicit confirmation ends the temporary override")
	var saved := CampaignState.new()
	saved.path = TEST_PATH
	_check(saved.read_save([]) and saved.settings.graphics.window_width == 1280 and saved.settings.graphics.window_height == 720,
		"the confirmed mode, not the temporary launch size, reaches disk")
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(1100, 620)
		game._ignore_window_resize_until = 0
		game._on_window_size_changed()
		await create_timer(0.65).timeout
		_check(saved.read_save([]) and saved.settings.graphics.window_width == root.size.x and saved.settings.graphics.window_height == root.size.y,
			"normal resize persistence resumes after explicit confirmation")
	game.free()
	await process_frame
	_cleanup()
	print("STARTUP_WINDOW checks=", checks, " failures=", JSON.stringify(failures), " display=", DisplayServer.get_name())
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
