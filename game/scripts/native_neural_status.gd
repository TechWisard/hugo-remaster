class_name NativeNeuralStatus
extends Label
## Read-only, session-bound evidence from the external Windows launcher.
## A backend message never proves final presentation or visual improvement.

const Localizer = preload("res://scripts/native_localization.gd")
const MAX_REPORT_BYTES: int = 65536
const HEARTBEAT_SECONDS: float = 10.0
const STATES: Array[String] = ["probing", "backend_reported", "inactive", "failed"]
var _elapsed: float = 0.0
static var _last_read_msec: int = -2000
static var _cached: Dictionary = {}


static func parse_arguments(arguments: PackedStringArray) -> Dictionary:
	var request := {"requested": false, "path": "", "session": "", "error": ""}
	for argument: String in arguments:
		if argument in ["--dlss5-profile", "--dlss5-feeder-profile"]:
			request.requested = true
		elif argument.begins_with("--nr-status-file="):
			request.requested = true
			if not str(request.path).is_empty(): request.error = "duplicate_path"
			request.path = argument.trim_prefix("--nr-status-file=")
		elif argument.begins_with("--nr-session="):
			request.requested = true
			if not str(request.session).is_empty(): request.error = "duplicate_session"
			request.session = argument.trim_prefix("--nr-session=")
	if request.requested:
		var path: String = request.path
		if path.is_empty() or not path.is_absolute_path() or path.begins_with("res://") or path.begins_with("user://") or path.get_extension().to_lower() != "json":
			request.error = "invalid_or_missing_report_path"
		if str(request.session).length() < 16 or str(request.session).length() > 128:
			request.error = "invalid_or_missing_session"
	return request


static func _unknown(reason: String) -> Dictionary:
	return {"requested": true, "state": "unverified", "reason_code": reason,
		"frames_processed": null, "display_verified": false, "provider": "none"}


static func validate_report(report: Variant, request: Dictionary, now: float, process_id: int) -> Dictionary:
	if not str(request.get("error", "")).is_empty():
		return _unknown(str(request.error))
	if not report is Dictionary or report.get("schema") != 1:
		return _unknown("invalid_schema")
	if report.get("session") != request.get("session"):
		return _unknown("different_session")
	var pid: Variant = report.get("process_id")
	if not (pid is int or pid is float) or not is_finite(float(pid)) or float(pid) != float(process_id):
		return _unknown("different_process")
	var state: String = str(report.get("state", ""))
	if state not in STATES:
		return _unknown("unknown_state")
	var provider: String = str(report.get("provider", ""))
	if provider not in ["gitc_uplift_opengl", "none"] or (state == "backend_reported" and provider != "gitc_uplift_opengl"):
		return _unknown("invalid_provider")
	var timestamp: String = str(report.get("updated_utc", ""))
	if timestamp.length() < 20 or timestamp.substr(10, 1) != "T" or not timestamp.ends_with("Z"):
		return _unknown("invalid_timestamp")
	var parsed: Dictionary = Time.get_datetime_dict_from_datetime_string(timestamp.substr(0, 19), false)
	if parsed.is_empty():
		return _unknown("invalid_timestamp")
	var updated: float = float(Time.get_unix_time_from_datetime_dict(parsed))
	if updated <= 0.0 or now - updated > HEARTBEAT_SECONDS or updated - now > 2.0:
		return _unknown("stale_report")
	var frames: Variant = report.get("frames_processed")
	if frames != null and (not (frames is int or frames is float) or not is_finite(float(frames)) or float(frames) < 0.0 or float(frames) != floorf(float(frames))):
		return _unknown("invalid_frame_counter")
	return {"requested": true, "state": state, "provider": provider,
		"reason_code": str(report.get("reason_code", "")), "frames_processed": frames,
		"display_verified": false, "updated_utc": timestamp}


static func current() -> Dictionary:
	var now_msec: int = Time.get_ticks_msec()
	if not _cached.is_empty() and now_msec - _last_read_msec < 1000:
		return _cached.duplicate()
	_last_read_msec = now_msec
	var request: Dictionary = parse_arguments(OS.get_cmdline_user_args())
	if not request.requested:
		_cached = {"requested": false, "state": "inactive", "display_verified": false}
		return _cached.duplicate()
	_cached = _unknown(str(request.error))
	if not str(request.error).is_empty(): return _cached.duplicate()
	var path: String = request.path
	if not FileAccess.file_exists(path):
		_cached = _unknown("report_missing")
		return _cached.duplicate()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_cached = _unknown("report_unreadable")
		return _cached.duplicate()
	if file.get_length() > MAX_REPORT_BYTES:
		file.close()
		_cached = _unknown("report_too_large")
		return _cached.duplicate()
	var text: String = file.get_as_text().trim_prefix("\ufeff")
	file.close()
	_cached = validate_report(JSON.parse_string(text), request, Time.get_unix_time_from_system(), OS.get_process_id())
	return _cached.duplicate()


static func attach(parent: Node) -> Label:
	if not bool(parse_arguments(OS.get_cmdline_user_args()).requested): return null
	var label: Label = load("res://scripts/native_neural_status.gd").new() as Label
	parent.add_child(label)
	return label


func _ready() -> void:
	name = "NeuralRenderingStatus"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_theme_font_size_override("font_size", 12)
	add_theme_color_override("font_outline_color", Color(0.02, 0.07, 0.08, 0.9))
	add_theme_constant_override("outline_size", 3)
	Localizer.events().language_changed.connect(_refresh)
	_refresh()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= 1.0:
		_elapsed = 0.0
		_refresh()


func _refresh(_locale: String = "") -> void:
	var status: Dictionary = current()
	var state: String = str(status.get("state", "unverified"))
	text = Localizer.text("nr." + state)
	tooltip_text = Localizer.text("nr.evidence_hint")
	var color := Color("c7d6cf")
	if state == "backend_reported": color = Color("efd08b")
	elif state == "failed": color = Color("f1b38a")
	add_theme_color_override("font_color", color)
