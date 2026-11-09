class_name NativeGraphicsSettings
extends RefCounted
## Live options supported by the Compatibility renderer; save values are portable.

const TexturePackScript = preload("res://scripts/hd_texture_pack.gd")
const DEFAULTS: Dictionary = {"msaa": 4, "render_scale": 1.0, "vsync": true, "texture_quality": "enhanced",
	"display_mode": "windowed", "window_width": 0, "window_height": 0}
const MSAA_MODES: Dictionary = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X,
	4: Viewport.MSAA_4X, 8: Viewport.MSAA_8X}
const RENDER_SCALES: Array[float] = [0.5, 0.67, 0.75, 1.0, 1.5, 2.0]
const DISPLAY_MODES: Array[String] = ["windowed", "borderless", "fullscreen"]
const DISPLAY_KEYS: Array[String] = ["display_mode", "window_width", "window_height"]
const UI_BASE_SIZE := Vector2i(1280, 720)
const MIN_WINDOW_SIZE := Vector2i(640, 360)
const WINDOW_PRESETS: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1920, 1200), Vector2i(2560, 1600),
	Vector2i(3440, 1440), Vector2i(5120, 1440)]


static func defaults() -> Dictionary:
	return DEFAULTS.duplicate()


static func sanitize(raw: Variant) -> Dictionary:
	var result: Dictionary = defaults()
	if not raw is Dictionary:
		return result
	var samples: Variant = raw.get("msaa")
	if (samples is int or samples is float) and is_finite(float(samples)) and float(samples) == floorf(float(samples)) and MSAA_MODES.has(int(samples)):
		result.msaa = int(samples)
	var scale: Variant = raw.get("render_scale")
	if (scale is int or scale is float) and is_finite(float(scale)) and float(scale) in RENDER_SCALES:
		result.render_scale = float(scale)
	if raw.get("vsync") is bool:
		result.vsync = raw.vsync
	if raw.get("texture_quality") in ["original", "enhanced"]:
		result.texture_quality = raw.texture_quality
	if raw.get("display_mode") is String and str(raw.display_mode) in DISPLAY_MODES:
		result.display_mode = raw.display_mode
	var width: Variant = raw.get("window_width", 0)
	var height: Variant = raw.get("window_height", 0)
	if _valid_dimension(width, MIN_WINDOW_SIZE.x) and _valid_dimension(height, MIN_WINDOW_SIZE.y):
		result.window_width = int(width)
		result.window_height = int(height)
	return result


static func apply(viewport: Viewport, raw: Dictionary, manage_window: bool = true) -> Dictionary:
	var options: Dictionary = sanitize(raw)
	var effective: Dictionary = effective_options(options)
	if is_instance_valid(viewport):
		viewport.msaa_3d = MSAA_MODES[int(effective.msaa)]
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = float(effective.render_scale)
		if viewport is Window:
			configure_canvas(viewport as Window)
			if manage_window:
				apply_window(viewport as Window, options)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if options.vsync else DisplayServer.VSYNC_DISABLED)
	TexturePackScript.set_enabled(options.texture_quality == "enhanced" and TexturePackScript.is_available())
	return options


static func display_options(raw: Dictionary) -> Dictionary:
	var options: Dictionary = sanitize(raw)
	var result: Dictionary = {}
	for key: String in DISPLAY_KEYS:
		result[key] = options[key]
	return result


static func keep_startup_window_requested() -> bool:
	# Godot consumes its own window arguments before exposing get_cmdline_args().
	# An explicit user argument also covers --resolution equal to project defaults.
	return "--keep-window" in OS.get_cmdline_user_args()


static func configure_canvas(window: Window) -> void:
	# UI scales uniformly; 3D still renders directly at the actual window size.
	window.content_scale_size = UI_BASE_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_factor = 1.0
	window.gui_embed_subwindows = true
	window.unresizable = false


static func screen_geometry(window: Window) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return {"size": UI_BASE_SIZE, "position": Vector2i.ZERO, "usable": Rect2i(Vector2i.ZERO, UI_BASE_SIZE), "headless": true}
	var screen: int = window.current_screen
	var size: Vector2i = DisplayServer.screen_get_size(screen)
	var position: Vector2i = DisplayServer.screen_get_position(screen)
	if size.x < 1 or size.y < 1:
		size = UI_BASE_SIZE
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x < 1 or usable.size.y < 1:
		usable = Rect2i(position, size)
	return {"size": size, "position": position, "usable": usable, "headless": false}


static func fit_window_size(requested: Vector2i, available: Vector2i) -> Vector2i:
	var bounds := Vector2i(maxi(1, available.x), maxi(1, available.y))
	if requested.x < 1 or requested.y < 1:
		return bounds
	var scale: float = minf(1.0, minf(float(bounds.x) / requested.x, float(bounds.y) / requested.y))
	return Vector2i(maxi(1, floori(requested.x * scale)), maxi(1, floori(requested.y * scale)))


static func apply_window(window: Window, raw: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var options: Dictionary = sanitize(raw)
	var screen: Dictionary = screen_geometry(window)
	window.min_size = Vector2i(mini(MIN_WINDOW_SIZE.x, screen.size.x), mini(MIN_WINDOW_SIZE.y, screen.size.y))
	if options.display_mode == "fullscreen":
		window.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		return
	if options.display_mode == "borderless":
		window.mode = Window.MODE_FULLSCREEN
		return
	window.mode = Window.MODE_WINDOWED
	window.borderless = false
	var usable: Rect2i = screen.usable
	var decorations: Vector2i = window.get_size_with_decorations() - window.size
	decorations = Vector2i(maxi(decorations.x, 0), maxi(decorations.y, 0))
	if decorations == Vector2i.ZERO and OS.get_name() == "Windows":
		# A mode transition can report old fullscreen decorations until the next event.
		decorations = Vector2i(16, 40)
	var available := Vector2i(maxi(1, usable.size.x - decorations.x), maxi(1, usable.size.y - decorations.y))
	var requested := Vector2i(int(options.window_width), int(options.window_height))
	if requested == Vector2i.ZERO:
		requested = screen.size
	window.size = fit_window_size(requested, available)
	window.position = usable.position + (usable.size - window.size) / 2


static func _valid_dimension(value: Variant, minimum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) \
		and float(value) >= minimum and float(value) <= 8192


static func external_profile_requested() -> bool:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	return "--dlss5-profile" in arguments or "--dlss5-feeder-profile" in arguments


static func feeder_profile_requested() -> bool:
	return "--dlss5-feeder-profile" in OS.get_cmdline_user_args()


static func safe_profile_requested() -> bool:
	return "--graphics-safe-profile" in OS.get_cmdline_user_args()


static func launch_profile_requested() -> bool:
	return external_profile_requested() or safe_profile_requested()


static func launch_profile_name() -> String:
	if safe_profile_requested():
		return "safe"
	if feeder_profile_requested():
		return "dlss5_feeder"
	return "dlss5_uplift" if external_profile_requested() else "standard"


static func effective_options(raw: Dictionary) -> Dictionary:
	var options: Dictionary = sanitize(raw)
	if external_profile_requested():
		# GITC-Uplift's enabled ReShade technique uses the resolved MSAA copy.
		# Its initial profile keeps 4x AA; the separate Feeder profile needs AA off.
		# Neither launch flag proves that the external neural pass is active.
		options.msaa = 0 if feeder_profile_requested() else 4
		options.render_scale = 1.0
	if safe_profile_requested():
		options.msaa = 2
		options.render_scale = 1.0
	return options


static func enhanced_textures_available() -> bool:
	return TexturePackScript.is_available()
