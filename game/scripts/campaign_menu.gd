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


func focus_default() -> void:
	if is_instance_valid(_first_button):
		_first_button.grab_focus()


func _build_home() -> void:
	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.size_flags_stretch_ratio = 1.05
	brand.add_theme_constant_override("separation", 16)
	_menu.add_child(brand)
	brand.add_child(_label("КУЗЯ", 64, GOLD))
	brand.add_child(_label("АЛМАЗНАЯ\nЛИХОРАДКА", 32, CREAM))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brand.add_child(spacer)
	if not entries.is_empty():
		var resume_id: String = state.level_id
		if not resume_id.is_empty():
			_first_button = _button("Продолжить", func() -> void: start_requested.emit(resume_id, true))
			brand.add_child(_first_button)
		var new_button := _button("Новая игра", _confirm_new_game)
		brand.add_child(new_button)
		if _first_button == null:
			_first_button = new_button
	else:
		var missing := _label("Оригинальные ресурсы не подключены.\nИмпортируйте HUGO4.CD по инструкции README.", 17, CREAM)
		missing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		brand.add_child(missing)
		_first_button = _button("Тестовый маршрут", func() -> void: demo_requested.emit())
		brand.add_child(_first_button)
	brand.add_child(_button("Настройки", _show_options))
	brand.add_child(_button("Выйти", func() -> void: get_tree().quit()))
	brand.add_child(_label("WASD · ПРОБЕЛ · E — АТАКА · CTRL — ПОЛЗТИ", 12, Color("abbdb8")))
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)
	_menu.add_child(column)
	_chapters = VBoxContainer.new()
	_chapters.add_theme_constant_override("separation", 9)
	column.add_child(_chapters)
	_chapters.add_child(_label("ГЛАВЫ", 15, GOLD))
	for index: int in range(entries.size()):
		var entry: Dictionary = entries[index]
		var id: String = str(entry.id)
		var mark: String = "   ✓" if state.completed_levels.get(id, false) else ""
		var button := _button("%02d   %s%s" % [index + 1, entry.title, mark],
			func() -> void: start_requested.emit(id, false))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_chapters.add_child(button)
	if entries.is_empty():
		_chapters.add_child(_label("Пляж → тропа Кику → шахты →\nтранспортная линия → нефтепровод →\nфабрика → авария → побег", 20, CREAM))
	else:
		var progress := _label("Пройдено глав: %d / %d" % [state.completed_levels.size(), entries.size()], 15, Color("abbdb8"))
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
	_options.add_child(_label("НАСТРОЙКИ", 22, GOLD))
	_add_slider("Музыка", "music_volume")
	_add_slider("Эффекты", "effects_volume")
	_options.add_child(_label("Сложность новой игры", 18, CREAM))
	var difficulty := OptionButton.new()
	for title: String in ["Легко", "Обычно", "Сложно"]:
		difficulty.add_item(title)
	difficulty.selected = int(state.settings.get("new_game_difficulty", 1))
	difficulty.custom_minimum_size.y = 36
	difficulty.item_selected.connect(func(index: int) -> void:
		state.settings.new_game_difficulty = index
		settings_changed.emit())
	_options.add_child(difficulty)
	_build_graphics_options()
	_options.add_child(_button("Назад к главам", func() -> void:
		_options_scroll.hide()
		_chapters.show()
		focus_default()))
	focus_default.call_deferred()


func _confirm_new_game() -> void:
	if state.runs.is_empty() and state.completed_levels.is_empty():
		new_game_requested.emit()
		return
	var confirmation := ConfirmationDialog.new()
	confirmation.title = "Новая игра"
	confirmation.dialog_text = "Начать с первой главы и сбросить текущее прохождение?"
	confirmation.ok_button_text = "Начать заново"
	confirmation.cancel_button_text = "Отмена"
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


func _build_graphics_options() -> void:
	state.settings["graphics"] = GraphicsScript.sanitize(state.settings.get("graphics", {}))
	_options.add_child(_label("ГРАФИКА", 18, GOLD))
	_build_display_options()
	if GraphicsScript.launch_profile_requested():
		var caption: String = "Профиль DLSS 5: MSAA 4×, разрешение 3D 100%."
		if GraphicsScript.feeder_profile_requested():
			caption = "Профиль Feeder: MSAA выкл., разрешение 3D 100%."
		if GraphicsScript.safe_profile_requested():
			caption = "Совместимый профиль: MSAA 2×, разрешение 3D 100%."
		var profile := _label(caption, 13, Color("abbdb8"))
		profile.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_options.add_child(profile)
	_graphics_choice("Сглаживание", "msaa", [0, 2, 4, 8], ["Выкл.", "MSAA 2×", "MSAA 4×", "MSAA 8×"], "GraphicsMSAA")
	_graphics_choice("Разрешение 3D", "render_scale", [1.0, 1.5, 2.0], ["100%", "150% · SSAA", "200% · SSAA"], "GraphicsRenderScale")
	var scale_hint := _label("Выше 100% — чётче изображение, выше нагрузка на видеокарту.", 13, Color("abbdb8"))
	scale_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options.add_child(scale_hint)
	var textures: OptionButton = _graphics_choice("Текстуры", "texture_quality", ["original", "enhanced"], ["Оригинал", "Улучшенные"], "GraphicsTextures")
	if not GraphicsScript.enhanced_textures_available():
		textures.set_item_disabled(1, true)
		textures.select(0)
		textures.tooltip_text = "Улучшенный набор текстур не установлен."
	else:
		textures.tooltip_text = "Улучшенный набор заменяет только входящие в него текстуры."
	var vsync := CheckButton.new()
	vsync.name = "GraphicsVSync"
	vsync.text = "Вертикальная синхронизация"
	vsync.button_pressed = bool(state.settings.graphics.vsync)
	vsync.toggled.connect(func(enabled: bool) -> void:
		state.settings.graphics.vsync = enabled
		settings_changed.emit())
	_options.add_child(vsync)


func _build_display_options() -> void:
	_display_draft = GraphicsScript.display_options(state.settings.graphics)
	_display_mode_choice = _display_choice_row("Режим экрана", "DisplayMode")
	for title: String in ["Окно", "Без рамок", "Полный экран"]:
		_display_mode_choice.add_item(title)
	_display_mode_choice.item_selected.connect(func(index: int) -> void:
		_display_draft.display_mode = GraphicsScript.DISPLAY_MODES[index]
		_update_display_draft())
	_resolution_choice = _display_choice_row("Размер окна", "DisplayResolution")
	_resolution_choice.add_item("Авто · рабочий стол")
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
	_resolution_choice.add_item("Свой размер…")
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
	var apply := _button("Применить режим экрана", func() -> void:
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
	_display_status.text = "Сейчас: %d × %d. Экран: %d × %d.\n" % [actual.x, actual.y, screen.size.x, screen.size.y]
	_display_status.text += "Окно ограничивается рабочей областью экрана. Новый режим можно отменить за 15 секунд." \
		if windowed else "Безрамочный и полный экран используют родное разрешение монитора."


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
		if effective.get(key) == values[index]:
			choice.select(index)
	if GraphicsScript.launch_profile_requested() and key in ["msaa", "render_scale"]:
		choice.disabled = true
	choice.item_selected.connect(func(index: int) -> void:
		state.settings.graphics[key] = values[index]
		settings_changed.emit())
	row.add_child(choice)
	_options.add_child(row)
	return choice


func _add_slider(title: String, key: String) -> void:
	var label := _label("%s · %d%%" % [title, roundi(float(state.settings[key]) * 100)], 18, CREAM)
	_options.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(state.settings[key])
	slider.custom_minimum_size.y = 28
	slider.value_changed.connect(func(value: float) -> void:
		state.settings[key] = value
		label.text = "%s · %d%%" % [title, roundi(value * 100)]
		settings_changed.emit())
	_options.add_child(slider)


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
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
