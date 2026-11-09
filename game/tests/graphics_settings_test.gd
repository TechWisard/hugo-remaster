extends SceneTree
## Actual menu signals -> campaign apply -> disk save -> recreated menu/Viewport.

const TEST_PATH: String = "user://graphics_settings_test.json"
var checks: int = 0
var failures: Array[String] = []


class Harness extends HugoCampaign:
	var loaded_state: CampaignState

	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		_load_catalog()
		state = loaded_state if loaded_state != null else CampaignState.new()
		state.path = TEST_PATH
		_apply_settings(false)
		_show_menu()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	var game := Harness.new()
	root.add_child(game)
	await process_frame
	game.menu._show_options()
	var msaa: OptionButton = game.menu.find_child("GraphicsMSAA", true, false) as OptionButton
	var scale: OptionButton = game.menu.find_child("GraphicsRenderScale", true, false) as OptionButton
	var textures: OptionButton = game.menu.find_child("GraphicsTextures", true, false) as OptionButton
	var vsync: CheckButton = game.menu.find_child("GraphicsVSync", true, false) as CheckButton
	_check(msaa != null and scale != null and textures != null and vsync != null, "real settings menu exposes the supported graphics controls")
	_check(game.menu._options_scroll.visible, "graphics controls live in the visible scrollable options panel")
	var external_profile: bool = NativeGraphicsSettings.launch_profile_requested()
	var profile_options: Dictionary = NativeGraphicsSettings.effective_options(NativeGraphicsSettings.defaults())
	var profile_msaa: Viewport.MSAA = NativeGraphicsSettings.MSAA_MODES[int(profile_options.msaa)]
	var profile_selection: int = [0, 2, 4, 8].find(int(profile_options.msaa))
	if external_profile:
		game.state.settings.graphics.msaa = 8
		game.state.settings.graphics.render_scale = 2.0
		game._apply_settings()
		_check(root.msaa_3d == profile_msaa and is_equal_approx(root.scaling_3d_scale, 1.0), "external profile applies its native-resolution resolved input")
		_check(msaa.disabled and scale.disabled and msaa.selected == profile_selection and scale.selected == 0,
			"profile menu shows the effective AA and resolution without claiming neural activation")
		_check(game.state.settings.graphics.msaa == 8 and game.state.settings.graphics.render_scale == 2.0,
			"external launch profile preserves the ordinary saved quality preferences")
	else:
		_check(not msaa.disabled and not scale.disabled, "ordinary launch leaves graphics choices editable")
		for index: int in range(4):
			_select(msaa, index)
			await process_frame
			_check(root.msaa_3d == [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_8X][index],
				"menu choice %d applies the actual Viewport MSAA mode" % index)
		for index: int in range(3):
			_select(scale, index)
			await process_frame
			_check(is_equal_approx(root.scaling_3d_scale, [1.0, 1.5, 2.0][index]) and root.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR,
				"menu choice %d applies actual bilinear supersampling scale" % index)
	vsync.button_pressed = false
	await process_frame
	_check(not game.state.settings.graphics.vsync, "VSync toggle reaches persisted settings")
	if DisplayServer.get_name() != "headless":
		_check(DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, "VSync toggle reaches the display server")
	_select(textures, 0)
	_check(game.state.settings.graphics.texture_quality == "original", "original texture choice reaches the campaign setting")
	_check(not HugoTexturePack.get_status().enabled, "original texture choice disables the live replacement manager")
	if NativeGraphicsSettings.enhanced_textures_available():
		_select(textures, 1)
		_check(game.state.settings.graphics.texture_quality == "enhanced" and HugoTexturePack.get_status().enabled,
			"installed enhanced texture choice enables the live replacement manager")
	else:
		_check(textures.is_item_disabled(1), "an absent enhanced pack is disabled honestly")
	var loaded := CampaignState.new()
	loaded.path = TEST_PATH
	_check(loaded.read_save([]), "menu settings write a valid campaign save")
	_check(loaded.settings.graphics.msaa == 8 and loaded.settings.graphics.render_scale == 2.0 and not loaded.settings.graphics.vsync,
		"graphics preferences survive disk serialization")
	game.free()
	await process_frame
	root.msaa_3d = Viewport.MSAA_2X
	root.scaling_3d_scale = 1.5
	game = Harness.new()
	game.loaded_state = loaded
	root.add_child(game)
	await process_frame
	_check(root.msaa_3d == (profile_msaa if external_profile else Viewport.MSAA_8X), "recreated campaign reapplies the effective MSAA mode")
	_check(is_equal_approx(root.scaling_3d_scale, 1.0 if external_profile else 2.0), "recreated campaign reapplies the effective 3D resolution")
	game.menu._show_options()
	msaa = game.menu.find_child("GraphicsMSAA", true, false) as OptionButton
	_check(msaa.selected == (profile_selection if external_profile else 3), "recreated settings menu reflects the applied rendering mode")
	await _capture_if_requested(game.menu)
	game.free()
	await process_frame
	var legacy := CampaignState.new()
	legacy.path = TEST_PATH
	legacy.settings.erase("graphics")
	_check(legacy.write_save() and loaded.read_save([]), "legacy v2 saves without graphics still load")
	_check(loaded.settings.graphics == NativeGraphicsSettings.defaults(), "legacy graphics preferences use safe supported defaults")
	var invalid: Dictionary = NativeGraphicsSettings.sanitize({"msaa": 3, "render_scale": INF, "vsync": "yes", "texture_quality": "unknown"})
	_check(invalid == NativeGraphicsSettings.defaults(), "unsupported and non-finite graphics settings are rejected")
	NativeGraphicsSettings.apply(root, NativeGraphicsSettings.defaults())
	_cleanup()
	print("GRAPHICS_SETTINGS checks=", checks, " profile=", external_profile, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _select(control: OptionButton, index: int) -> void:
	control.select(index)
	control.item_selected.emit(index)


func _capture_if_requested(menu: CampaignMenu) -> void:
	if DisplayServer.get_name() == "headless":
		return
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--graphics-capture="):
			menu._options_scroll.scroll_vertical = 180
			await process_frame
			await RenderingServer.frame_post_draw
			var path: String = argument.trim_prefix("--graphics-capture=")
			_check(root.get_texture().get_image().save_png(path) == OK, "settings screenshot is saved from the real renderer")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
