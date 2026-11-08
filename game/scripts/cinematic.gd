class_name CampaignCinematic
extends CanvasLayer

signal finished
var stream_path: String
var aspect_ratio: float = 2.0
var _video: VideoStreamPlayer
var _closed: bool = false


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(black)
	var frame := AspectRatioContainer.new()
	frame.ratio = aspect_ratio
	frame.stretch_mode = AspectRatioContainer.STRETCH_FIT
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(frame)
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video.bus = "Effects"
	frame.add_child(_video)
	var hint := Label.new()
	hint.text = "ПРОБЕЛ / ESC — пропустить"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_left = 24
	hint.offset_right = -24
	hint.offset_top = -40
	hint.offset_bottom = -12
	hint.add_theme_color_override("font_color", Color("fff1cd"))
	screen.add_child(hint)
	if not ResourceLoader.exists(stream_path):
		_finish.call_deferred()
		return
	_video.stream = load(stream_path) as VideoStream
	if _video.stream == null:
		_finish.call_deferred()
		return
	_video.finished.connect(_finish)
	_video.play()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("jump") or event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_finish()


func _finish() -> void:
	if _closed:
		return
	_closed = true
	if _video:
		_video.stop()
	finished.emit()
	queue_free()
