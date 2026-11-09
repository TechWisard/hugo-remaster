class_name CampaignCinematic
extends CanvasLayer

signal finished
const Localizer = preload("res://scripts/native_localization.gd")
var stream_path: String
var movie_key: String
var voice_info: Dictionary = {}
var aspect_ratio: float = 2.0
var _video: VideoStreamPlayer
var _hint: Label
var _voice_label: Label
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
	_video.bus = "Effects" if AudioServer.get_bus_index("Effects") >= 0 else "Master"
	frame.add_child(_video)
	_hint = Label.new()
	_hint.name = "SkipHint"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_left = 24
	_hint.offset_right = -24
	_hint.offset_top = -40
	_hint.offset_bottom = -12
	_hint.add_theme_color_override("font_color", Color("fff1cd"))
	screen.add_child(_hint)
	_voice_label = Label.new()
	_voice_label.name = "ActualVoice"
	_voice_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_voice_label.offset_left = 24
	_voice_label.offset_right = -24
	_voice_label.offset_top = -70
	_voice_label.offset_bottom = -42
	_voice_label.add_theme_color_override("font_color", Color("fff1cd"))
	screen.add_child(_voice_label)
	Localizer.events().language_changed.connect(_refresh_language)
	_refresh_language(Localizer.get_text_locale())
	if stream_path.is_empty() or not ResourceLoader.exists(stream_path, "VideoStream"):
		_finish.call_deferred()
		return
	_video.stream = load(stream_path) as VideoStream
	if _video.stream == null:
		_finish.call_deferred()
		return
	_video.finished.connect(_finish)
	_video.play()


func _refresh_language(_locale: String) -> void:
	_hint.text = Localizer.text("cinematic.skip")
	var actual: String = str(voice_info.get("effective_locale", ""))
	var requested: String = str(voice_info.get("requested_locale", ""))
	var actual_name: String = Localizer.text("voice.original") if actual.is_empty() else Localizer.language_name(actual)
	if bool(voice_info.get("is_fallback", false)):
		_voice_label.text = Localizer.text("voice.fallback", {"actual": actual_name, "requested": Localizer.language_name(requested)})
	else:
		_voice_label.text = Localizer.text("language.voice") + ": " + actual_name


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
