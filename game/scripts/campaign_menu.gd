class_name CampaignMenu
extends CanvasLayer

signal start_requested(level_id: String, resume: bool)
signal new_game_requested
signal demo_requested
signal settings_changed
signal display_preview_requested(options: Dictionary)

const GOLD := Color("f6cf80")
const CREAM := Color("f9f0da")
const GraphicsScript = preload("res://scripts/native_graphics_settings.gd")
const Localizer = preload("res://scripts/native_localization.gd")
const TextBindings = preload("res://scripts/native_text_bindings.gd")
const VoiceLibrary = preload("res://scripts/native_voice_library.gd")
const PerformanceProfiles = preload("res://scripts/performance_profile.gd")
var state: CampaignState
var entries: Array[Dictionary] = []
var _root: Control
var _menu: HBoxContainer
var _chapters: VBoxContainer
var _options: VBoxContainer
var _options_scroll: ScrollContainer
var _first_button: Button
var _display_mode_choice: OptionButton
var _resolution_choice: OptionButton
var _custom_resolution_row: HBoxContainer
var _custom_width: SpinBox
var _custom_height: SpinBox
var _display_status: Label
var _display_draft: Dictionary = {}
var _text_bindings := TextBindings.new()
var _chapter_buttons: Array[Button] = []
var _chapter_overview: Label
var _text_locale_choice: OptionButton
var _voice_locale_choice: OptionButton
var _quality_preset_choice: OptionButton
var _graphics_choices: Dictionary = {}
var _voice_placeholder_index: int = -1
var _unavailable_voice_request: String = ""
var _unavailable_voice_default: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 20
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.02, 0.07, 0.08, 0.86)
	_root.add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + edge, 64)
	for edge: String in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 42)
	_root.add_child(margin)
	_menu = HBoxContainer.new()
	_menu.add_theme_constant_override("separation", 58)
	margin.add_child(_menu)
	_build_home()
	Localizer.events().language_changed.connect(_refresh_language)
	_refresh_language(Localizer.get_text_locale())


func focus_default() -> void:
	if is_instance_valid(_first_button):
		_first_button.grab_focus()


func _build_home() -> void:
	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.size_flags_stretch_ratio = 1.05
	brand.add_theme_constant_override("separation", 16)
	_menu.add_child(brand)
	brand.add_child(_label("brand.name", 64, GOLD))
	brand.add_child(_label("brand.subtitle", 32, CREAM))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brand.add_child(spacer)
	if not entries.is_empty():
		var resume_id: String = state.level_id
		if not resume_id.is_empty():
			_first_button = _button("menu.continue", func() -> void: start_requested.emit(resume_id, true))
			brand.add_child(_first_button)
		var new_button := _button("menu.new_game", _confirm_new_game)
		brand.add_child(new_button)
		if _first_button == null:
			_first_button = new_button
	else:
		var missing := _label("menu.assets_missing", 17, CREAM)
		missing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		brand.add_child(missing)
		_first_button = _button("menu.test_route", func() -> void: demo_requested.emit())
		brand.add_child(_first_button)
	brand.add_child(_button("menu.settings", _show_options))
	brand.add_child(_button("menu.quit", func() -> void: get_tree().quit()))
	brand.add_child(_label("menu.controls", 12, Color("abbdb8")))
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)
	_menu.add_child(column)
	_chapters = VBoxContainer.new()
	_chapters.add_theme_constant_override("separation", 9)
	column.add_child(_chapters)
	_chapters.add_child(_label("menu.chapters", 15, GOLD))
	for index: int in range(entries.size()):
		var entry: Dictionary = entries[index]
		var id: String = str(entry.id)
		var mark: String = "   ✓" if state.completed_levels.get(id, false) else ""
		var button := _button("%02d   %s%s" % [index + 1, entry.title, mark],
			func() -> void: start_requested.emit(id, false))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_chapters.add_child(button)
		_chapter_buttons.append(button)
	if entries.is_empty():
		_chapter_overview = _label("", 20, CREAM)
		_chapter_overview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_chapters.add_child(_chapter_overview)
	else:
		var progress := _label("menu.progress", 15, Color("abbdb8"), {"done": state.completed_levels.size(), "total": entries.size()})
		_chapters.add_child(progress)
	_options_scroll = ScrollContainer.new()
	_options_scroll.name = "OptionsScroll"
	_options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll.visible = false
	column.add_child(_options_scroll)
	_options = VBoxContainer.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("separation", 12)
	_options_scroll.add_child(_options)
	_options.add_child(_label("options.heading", 22, GOLD))
	_build_language_options()
	_add_slider("audio.music", "music_volume")
	_add_slider("audio.effects", "effects_volume")
	_options.add_child(_label("difficulty.label", 18, CREAM))
	var difficulty := OptionButton.new()
	for title: String in ["difficulty.easy", "difficulty.normal", "difficulty.hard"]:
		difficulty.add_item("")
		_text_bindings.bind_item(difficulty, difficulty.item_count - 1, title)
	difficulty.selected = int(state.settings.get("new_game_difficulty", 1))
	difficulty.custom_minimum_size.y = 36
	difficulty.item_selected.connect(func(index: int) -> void:
		state.settings.new_game_difficulty = index
		settings_changed.emit())
	_options.add_child(difficulty)
	_build_graphics_options()
	_options.add_child(_button("options.back_chapters", func() -> void:
		_options_scroll.hide()
		_chapters.show()
		focus_default()))
	focus_default.call_deferred()


func _confirm_new_game() -> void:
	if state.runs.is_empty() and state.completed_levels.is_empty():
		new_game_requested.emit()
		return
	var confirmation := ConfirmationDialog.new()
	_text_bindings.bind_property(confirmation, "title", "dialog.new_game_title")
	_text_bindings.bind_property(confirmation, "dialog_text", "dialog.new_game_body")
	_text_bindings.bind_property(confirmation, "ok_button_text", "dialog.restart")
	_text_bindings.bind_property(confirmation, "cancel_button_text", "dialog.cancel")
	confirmation.confirmed.connect(func() -> void:
		confirmation.queue_free()
		new_game_requested.emit())
	confirmation.canceled.connect(confirmation.queue_free)
	_root.add_child(confirmation)
	confirmation.popup_centered(Vector2i(460, 170))


func _show_options() -> void:
	_chapters.hide()
	_options_scroll.show()
	for child: Node in _options.get_children():
		if child is HSlider:
			(child as HSlider).grab_focus()
			break


func _build_language_options() -> void:
	_options.add_child(_label("language.heading", 18, GOLD))
	_text_locale_choice = _display_choice_row("language.text", "TextLocale")
	for code: String in Localizer.available_text_locales():
		_text_locale_choice.add_item(Localizer.language_name(code))
		var index: int = _text_locale_choice.item_count - 1
		_text_locale_choice.set_item_metadata(index, code)
		if code == state.settings.get("text_locale", "ru"):
			_text_locale_choice.select(index)
	_text_locale_choice.item_selected.connect(func(index: int) -> void:
		state.settings.text_locale = str(_text_locale_choice.get_item_metadata(index))
		settings_changed.emit())
	_voice_locale_choice = _display_choice_row("language.voice", "VoiceLocale")
	var installed: Array[String] = VoiceLibrary.available_locales()
	for code: String in installed:
		_voice_locale_choice.add_item(Localizer.language_name(code))
		var index: int = _voice_locale_choice.item_count - 1
		_voice_locale_choice.set_item_metadata(index, code)
		if code == state.settings.get("voice_locale", "ru"):
			_voice_locale_choice.select(index)
	var requested: String = str(state.settings.get("voice_locale", "ru"))
	if requested not in installed:
		# Retain the saved request without presenting the first unrelated locale
		# as selected. This can happen after removing or replacing a voice pack.
		_unavailable_voice_request = requested
		var default_locale: String = VoiceLibrary.normalize_locale(str(VoiceLibrary.get_manifest().get("default_voice_locale", "")))
		_unavailable_voice_default = default_locale if default_locale in installed else ""
		_voice_placeholder_index = _voice_locale_choice.item_count
		_voice_locale_choice.add_item("")
		_voice_locale_choice.set_item_metadata(_voice_placeholder_index, "")
		_voice_locale_choice.set_item_disabled(_voice_placeholder_index, true)
		_voice_locale_choice.select(_voice_placeholder_index)
		_refresh_voice_fallback()
	_voice_locale_choice.disabled = installed.is_empty()
	_voice_locale_choice.item_selected.connect(func(index: int) -> void:
		var code: Variant = _voice_locale_choice.get_item_metadata(index)
		if not code is String or code not in installed:
			return
		state.settings.voice_locale = code
		if _voice_placeholder_index >= 0:
			_voice_locale_choice.remove_item(_voice_placeholder_index)
			_voice_placeholder_index = -1
			_unavailable_voice_request = ""
			_unavailable_voice_default = ""
			_voice_locale_choice.tooltip_text = ""
		settings_changed.emit())
	var hint := _label("language.voice_hint", 13, Color("abbdb8"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options.add_child(hint)


func _refresh_voice_fallback() -> void:
	if _voice_locale_choice == null or _voice_placeholder_index < 0:
		return
	var requested: String = Localizer.language_name(_unavailable_voice_request)
	var actual: String = Localizer.language_name(_unavailable_voice_default) if not _unavailable_voice_default.is_empty() else Localizer.text("voice.original")
	_voice_locale_choice.set_item_text(_voice_placeholder_index, requested + " → " + actual)
	_voice_locale_choice.tooltip_text = Localizer.text("voice.fallback", {"actual": actual, "requested": requested})


func _refresh_language(_locale: String) -> void:
	_text_bindings.refresh()
	_refresh_voice_fallback()
	for index: int in range(_chapter_buttons.size()):
		var entry: Dictionary = entries[index]
		var mark: String = "   ✓" if state.completed_levels.get(str(entry.id), false) else ""
		_chapter_buttons[index].text = "%02d   %s%s" % [index + 1,
			Localizer.chapter_title(int(entry.get("main_group", -1)), str(entry.get("title", ""))), mark]
	if is_instance_valid(_chapter_overview):
		var chapters: Array[String] = []
		for group: int in [6, 17, 27, 36, 46, 55, 59, 69]:
			chapters.append(Localizer.chapter_title(group))
		_chapter_overview.text = " → ".join(chapters)
	# Only refresh text; do not reload committed settings over a pending draft,
	# rebuild controls, reset scroll/focus or restart a display-confirmation timer.
	_update_display_draft()


func _build_graphics_options() -> void:
	state.settings["graphics"] = GraphicsScript.sanitize(state.settings.get("graphics", {}))
	_options.add_child(_label("graphics.heading", 18, GOLD))
	_build_quality_presets()
	_build_display_options()
	if GraphicsScript.launch_profile_requested():
		var caption: String = "graphics.profile_dlss"
		if GraphicsScript.feeder_profile_requested():
			caption = "graphics.profile_feeder"
		if GraphicsScript.safe_profile_requested():
			caption = "graphics.profile_safe"
		var profile := _label(caption, 13, Color("abbdb8"))
		profile.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_options.add_child(profile)
	_graphics_choice("graphics.aa", "msaa", [0, 2, 4, 8], ["graphics.off", "MSAA 2×", "MSAA 4×", "MSAA 8×"], "GraphicsMSAA")
	_graphics_choice("graphics.scale", "render_scale", GraphicsScript.RENDER_SCALES, ["50%", "67%", "75%", "100%", "150% · SSAA", "200% · SSAA"], "GraphicsRenderScale")
	var scale_hint := _label("graphics.scale_hint", 13, Color("abbdb8"))
	scale_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options.add_child(scale_hint)
	var textures: OptionButton = _graphics_choice("graphics.textures", "texture_quality", ["original", "enhanced"], ["graphics.original", "graphics.enhanced"], "GraphicsTextures")
	if not GraphicsScript.enhanced_textures_available():
		textures.set_item_disabled(1, true)
		textures.select(0)
		_text_bindings.bind_property(textures, "tooltip_text", "graphics.pack_missing")
	else:
		_text_bindings.bind_property(textures, "tooltip_text", "graphics.pack_partial")
	var vsync := CheckButton.new()
	vsync.name = "GraphicsVSync"
	_text_bindings.bind_property(vsync, "text", "graphics.vsync")
	vsync.button_pressed = bool(state.settings.graphics.vsync)
	vsync.toggled.connect(func(enabled: bool) -> void:
		state.settings.graphics.vsync = enabled
		settings_changed.emit())
	_options.add_child(vsync)
	_refresh_graphics_controls()


func _build_quality_presets() -> void:
	_quality_preset_choice = _display_choice_row("graphics.preset", "GraphicsPreset")
	for name: String in PerformanceProfiles.ORDER + ["custom"]:
		_quality_preset_choice.add_item("")
		var index: int = _quality_preset_choice.item_count - 1
		_quality_preset_choice.set_item_metadata(index, name)
		_text_bindings.bind_item(_quality_preset_choice, index, "preset." + name)
	_quality_preset_choice.set_item_disabled(_quality_preset_choice.item_count - 1, true)
	_quality_preset_choice.disabled = GraphicsScript.launch_profile_requested()
	_quality_preset_choice.item_selected.connect(func(index: int) -> void:
		var name: String = str(_quality_preset_choice.get_item_metadata(index))
		state.settings.graphics = PerformanceProfiles.apply_preset(state.settings.graphics, name)
		_refresh_graphics_controls()
		settings_changed.emit())


func _refresh_graphics_controls() -> void:
	var effective: Dictionary = GraphicsScript.effective_options(state.settings.graphics)
	for key: String in _graphics_choices:
		var choice: OptionButton = _graphics_choices[key]
		for index: int in range(choice.item_count):
			if choice.get_item_metadata(index) == effective.get(key):
				choice.select(index)
		if key == "texture_quality" and not GraphicsScript.enhanced_textures_available():
			choice.select(0)
	if _quality_preset_choice != null:
		var preset: String = PerformanceProfiles.identify(effective)
		for index: int in range(_quality_preset_choice.item_count):
			if _quality_preset_choice.get_item_metadata(index) == preset:
				_quality_preset_choice.select(index)


func _build_display_options() -> void:
	_display_draft = GraphicsScript.display_options(state.settings.graphics)
	_display_mode_choice = _display_choice_row("display.mode", "DisplayMode")
	for title: String in ["display.windowed", "display.borderless", "display.fullscreen"]:
		_display_mode_choice.add_item("")
		_text_bindings.bind_item(_display_mode_choice, _display_mode_choice.item_count - 1, title)
	_display_mode_choice.item_selected.connect(func(index: int) -> void:
		_display_draft.display_mode = GraphicsScript.DISPLAY_MODES[index]
		_update_display_draft())
	_resolution_choice = _display_choice_row("display.window_size", "DisplayResolution")
	_resolution_choice.add_item("")
	_text_bindings.bind_item(_resolution_choice, 0, "display.auto")
	_resolution_choice.set_item_metadata(0, Vector2i.ZERO)
	for size: Vector2i in GraphicsScript.WINDOW_PRESETS:
		var label: String = "%d × %d" % [size.x, size.y]
		if size == Vector2i(1920, 1080):
			label += " · Full HD"
		elif size == Vector2i(2560, 1440):
			label += " · QHD"
		elif size == Vector2i(3840, 2160):
			label += " · 4K"
		_resolution_choice.add_item(label)
		_resolution_choice.set_item_metadata(_resolution_choice.item_count - 1, size)
	_resolution_choice.add_item("")
	_text_bindings.bind_item(_resolution_choice, _resolution_choice.item_count - 1, "display.custom")
	_resolution_choice.set_item_metadata(_resolution_choice.item_count - 1, Vector2i(-1, -1))
	_resolution_choice.item_selected.connect(func(_index: int) -> void: _update_display_draft())
	_custom_resolution_row = HBoxContainer.new()
	_custom_resolution_row.add_theme_constant_override("separation", 10)
	_options.add_child(_custom_resolution_row)
	_custom_width = _resolution_dimension("DisplayWidth", 640, 1280)
	_custom_resolution_row.add_child(_label("×", 18, CREAM))
	_custom_height = _resolution_dimension("DisplayHeight", 360, 720)
	_display_status = _label("", 13, Color("abbdb8"))
	_display_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options.add_child(_display_status)
	var apply := _button("display.apply", func() -> void:
		_update_display_draft()
		display_preview_requested.emit(_display_draft.duplicate()))
	apply.name = "ApplyDisplay"
	_options.add_child(apply)
	refresh_display_controls()


func _display_choice_row(title: String, node_name: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := _label(title, 17, CREAM)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var choice := OptionButton.new()
	choice.name = node_name
	choice.custom_minimum_size = Vector2(230, 38)
	row.add_child(choice)
	_options.add_child(row)
	return choice


func _resolution_dimension(node_name: String, minimum: int, initial: int) -> SpinBox:
	var field := SpinBox.new()
	field.name = node_name
	field.min_value = minimum
	field.max_value = 8192
	field.step = 1
	field.value = initial
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size = Vector2(100, 36)
	field.value_changed.connect(func(_value: float) -> void: _update_display_draft())
	_custom_resolution_row.add_child(field)
	return field


func refresh_display_controls() -> void:
	if _display_mode_choice == null:
		return
	_display_draft = GraphicsScript.display_options(state.settings.graphics)
	_display_mode_choice.select(GraphicsScript.DISPLAY_MODES.find(str(_display_draft.display_mode)))
	var size := Vector2i(int(_display_draft.window_width), int(_display_draft.window_height))
	var selected: int = _resolution_choice.item_count - 1
	for index: int in range(_resolution_choice.item_count - 1):
		if _resolution_choice.get_item_metadata(index) == size:
			selected = index
			break
	_resolution_choice.select(selected)
	if size.x > 0 and size.y > 0:
		_custom_width.set_value_no_signal(size.x)
		_custom_height.set_value_no_signal(size.y)
	_update_display_draft()


func _update_display_draft() -> void:
	if _resolution_choice == null or _custom_width == null or _custom_height == null:
		return
	var selected: Vector2i = _resolution_choice.get_item_metadata(_resolution_choice.selected)
	var custom: bool = selected.x == -1
	if custom:
		selected = Vector2i(int(_custom_width.value), int(_custom_height.value))
	_display_draft.window_width = selected.x
	_display_draft.window_height = selected.y
	var windowed: bool = _display_draft.display_mode == "windowed"
	_resolution_choice.disabled = not windowed
	_custom_resolution_row.visible = custom and windowed
	var screen: Dictionary = GraphicsScript.screen_geometry(get_tree().root)
	var actual: Vector2i = get_tree().root.size
	_display_status.text = Localizer.text("display.status", {"width": actual.x, "height": actual.y, "screen_width": screen.size.x, "screen_height": screen.size.y})
	_display_status.text += "\n" + Localizer.text("display.window_hint" if windowed else "display.fullscreen_hint")


func _graphics_choice(title: String, key: String, values: Array, labels: Array, node_name: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := _label(title, 17, CREAM)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var choice := OptionButton.new()
	choice.name = node_name
	choice.custom_minimum_size = Vector2(190, 38)
	var effective: Dictionary = GraphicsScript.effective_options(state.settings.graphics)
	for index: int in range(values.size()):
		choice.add_item(str(labels[index]))
		choice.set_item_metadata(index, values[index])
		if Localizer.has_key(str(labels[index])):
			_text_bindings.bind_item(choice, index, str(labels[index]))
		if effective.get(key) == values[index]:
			choice.select(index)
	if GraphicsScript.launch_profile_requested() and key in ["msaa", "render_scale"]:
		choice.disabled = true
	choice.item_selected.connect(func(index: int) -> void:
		state.settings.graphics[key] = values[index]
		_refresh_graphics_controls()
		settings_changed.emit())
	row.add_child(choice)
	_options.add_child(row)
	_graphics_choices[key] = choice
	return choice


func _add_slider(title: String, key: String) -> void:
	var label := _label(title, 18, CREAM, {"value": roundi(float(state.settings[key]) * 100)})
	_options.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(state.settings[key])
	slider.custom_minimum_size.y = 28
	slider.value_changed.connect(func(value: float) -> void:
		state.settings[key] = value
		_text_bindings.bind_property(label, "text", title, {"value": roundi(value * 100)})
		settings_changed.emit())
	_options.add_child(slider)


func _label(text: String, size: int, color: Color, arguments: Dictionary = {}) -> Label:
	var label := Label.new()
	if Localizer.has_key(text):
		_text_bindings.bind_property(label, "text", text, arguments)
	else:
		label.text = text
	if text in ["brand.subtitle", "menu.controls"]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	if Localizer.has_key(text):
		_text_bindings.bind_property(button, "text", text)
	else:
		button.text = text
	button.custom_minimum_size = Vector2(0, 48)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", CREAM)
	for appearance: String in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("203e43") if appearance == "normal" else Color("345b5e")
		if appearance == "focus":
			style.bg_color = Color(0, 0, 0, 0)
			style.border_color = GOLD
			style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		style.content_margin_left = 18
		style.content_margin_right = 18
		button.add_theme_stylebox_override(appearance, style)
	button.pressed.connect(action)
	return button
