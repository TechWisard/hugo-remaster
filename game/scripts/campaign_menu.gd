class_name CampaignMenu
extends CanvasLayer

signal start_requested(level_id: String, resume: bool)
signal new_game_requested
signal demo_requested
signal settings_changed

const GOLD := Color("f6cf80")
const CREAM := Color("f9f0da")
var state: CampaignState
var entries: Array[Dictionary] = []
var _root: Control
var _menu: HBoxContainer
var _chapters: VBoxContainer
var _options: VBoxContainer
var _first_button: Button


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
	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 16)
	_options.visible = false
	column.add_child(_options)
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
	var fullscreen := CheckButton.new()
	fullscreen.text = "Полный экран"
	fullscreen.button_pressed = state.settings.fullscreen
	fullscreen.toggled.connect(func(enabled: bool) -> void:
		state.settings.fullscreen = enabled
		settings_changed.emit())
	_options.add_child(fullscreen)
	_options.add_child(_button("Назад к главам", func() -> void:
		_options.hide()
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
	_options.show()
	for child: Node in _options.get_children():
		if child is HSlider:
			(child as HSlider).grab_focus()
			break


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
