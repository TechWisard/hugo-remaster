class_name RemasterHUD
extends CanvasLayer

signal restart_requested

var counter: Label
var clock_label: Label
var message_label: Label
var progress_bar: ProgressBar
var modal: PanelContainer
var modal_title: Label
var modal_detail: Label
var continue_button: Button
var restart_button: Button
var _toast_remaining: float = 0.0
var _completed: bool = false
var _audio: AudioStreamPlayer

const INK := Color("142d39")
const CREAM := Color("fff2ce")
const GOLD := Color("f7cf73")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)
	var brand := VBoxContainer.new()
	brand.position = Vector2(32, 26)
	brand.add_theme_constant_override("separation", 0)
	screen.add_child(brand)
	brand.add_child(_label("КУЗЯ", 34, GOLD))
	brand.add_child(_label("АЛМАЗНАЯ ЛИХОРАДКА", 12, CREAM))
	var chapter := _label("01  /  БЕРЕГ", 16, CREAM)
	chapter.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	chapter.position = Vector2(-64, 34)
	screen.add_child(chapter)
	var stats := PanelContainer.new()
	stats.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	stats.position = Vector2(-206, 24)
	stats.custom_minimum_size = Vector2(178, 88)
	stats.add_theme_stylebox_override("panel", _panel_style())
	screen.add_child(stats)
	var stats_stack := VBoxContainer.new()
	stats_stack.add_theme_constant_override("separation", 2)
	stats.add_child(stats_stack)
	counter = _label("◆  0 / 12", 25, GOLD)
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_stack.add_child(counter)
	clock_label = _label("00:00", 14, CREAM)
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_stack.add_child(clock_label)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(140, 4)
	progress_bar.show_percentage = false
	progress_bar.add_theme_stylebox_override("background", _flat(Color(0.1, 0.2, 0.24, 0.8), 2))
	progress_bar.add_theme_stylebox_override("fill", _flat(GOLD, 2))
	stats_stack.add_child(progress_bar)
	var footer := _label("WASD / стрелки — движение    ПРОБЕЛ — прыжок    SHIFT — бег    ПКМ — камера    ESC — пауза", 13, CREAM)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -34
	footer.offset_bottom = -8
	screen.add_child(footer)
	message_label = _label("", 20, CREAM)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	message_label.offset_top = -92
	message_label.offset_bottom = -60
	screen.add_child(message_label)
	_build_modal(screen)
	_audio = AudioStreamPlayer.new()
	_audio.volume_db = -15.0
	_audio.stream = _pickup_sound()
	add_child(_audio)


func _process(delta: float) -> void:
	if _toast_remaining > 0.0:
		_toast_remaining -= delta
		message_label.modulate.a = clampf(_toast_remaining, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	# This HUD keeps processing while paused, so Escape/Start can resume too.
	if event.is_action_pressed("pause"):
		toggle_pause()
		get_viewport().set_input_as_handled()


func set_progress(current: int, total: int, elapsed: float) -> void:
	counter.text = "◆  %d / %d" % [current, total]
	clock_label.text = "%02d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	progress_bar.max_value = total
	progress_bar.value = current


func toast(message: String, seconds: float = 3.5) -> void:
	message_label.text = message
	message_label.modulate.a = 1.0
	_toast_remaining = seconds


func play_pickup() -> void:
	_audio.pitch_scale = randf_range(0.96, 1.08)
	_audio.play()


func toggle_pause() -> void:
	if _completed:
		return
	var will_pause: bool = not get_tree().paused
	get_tree().paused = will_pause
	modal.visible = will_pause
	modal_title.text = "Пауза"
	modal_detail.text = "Соберите все алмазы и доберитесь до каменной арки.\nR — вернуться к последней контрольной точке."
	continue_button.visible = true
	if will_pause:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		continue_button.grab_focus()


func finish(elapsed: float) -> void:
	_completed = true
	modal.visible = true
	modal_title.text = "Берег пройден"
	modal_detail.text = "Все алмазы собраны.\nВремя: %02d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	continue_button.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	restart_button.grab_focus()


func reset_hud() -> void:
	_completed = false
	get_tree().paused = false
	modal.hide()


func _build_modal(screen: Control) -> void:
	modal = PanelContainer.new()
	modal.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	modal.position = Vector2(-250, -175)
	modal.custom_minimum_size = Vector2(500, 350)
	modal.add_theme_stylebox_override("panel", _panel_style(28))
	screen.add_child(modal)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 16)
	modal.add_child(stack)
	modal_title = _label("Пауза", 32, GOLD)
	modal_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(modal_title)
	modal_detail = _label("", 16, CREAM)
	modal_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	modal_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_detail.custom_minimum_size.y = 58
	stack.add_child(modal_detail)
	continue_button = _button("Продолжить")
	continue_button.pressed.connect(toggle_pause)
	stack.add_child(continue_button)
	restart_button = _button("Начать заново")
	restart_button.pressed.connect(func() -> void: restart_requested.emit())
	stack.add_child(restart_button)
	var quit_button := _button("Выйти")
	quit_button.pressed.connect(func() -> void: get_tree().quit())
	stack.add_child(quit_button)
	modal.hide()


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 40
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_stylebox_override("normal", _flat(Color("254b55"), 8))
	button.add_theme_stylebox_override("hover", _flat(Color("35646b"), 8))
	button.add_theme_stylebox_override("pressed", _flat(Color("163840"), 8))
	button.add_theme_stylebox_override("focus", _flat(Color(0.7, 0.65, 0.4, 0.18), 8))
	return button


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0.02, 0.08, 0.1, 0.65))
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


func _flat(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	return style


func _panel_style(margin: int = 12) -> StyleBoxFlat:
	var style := _flat(Color(0.045, 0.12, 0.16, 0.94), 14)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	style.border_color = Color(0.9, 0.77, 0.47, 0.3)
	style.set_border_width_all(1)
	return style


func _pickup_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var count: int = int(sample_rate * 0.22)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in range(count):
		var t: float = float(i) / sample_rate
		var envelope: float = exp(-t * 20.0) * minf(t * 160.0, 1.0)
		var value: float = (sin(TAU * 1046.5 * t) + 0.4 * sin(TAU * 1568.0 * t)) * envelope
		bytes.encode_s16(i * 2, int(value * 12000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes
	return stream
