class_name NativePerformanceMonitor
extends Node
## Optional real-session measurements. No monitoring node exists without the flag.
## --performance-report=PATH [--performance-frames=1800]; never exits the game.

var output_path: String = ""
var sample_limit: int = 1800
var warmup: int = 60
var _previous_tick: int = 0
var _samples := PackedFloat64Array()
var _draw_calls := PackedFloat64Array()
var _memory_peak: int = 0
var _video_memory_peak: int = 0
var _chapter: String = ""
var _saved: bool = false
var _metadata: Dictionary = {}


static func attach_if_requested(campaign: Node) -> Node:
	var path: String = ""
	var frames: int = 1800
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--performance-report="):
			path = arg.trim_prefix("--performance-report=")
		elif arg.begins_with("--performance-frames="):
			frames = clampi(int(arg.trim_prefix("--performance-frames=")), 120, 36000)
	if path.is_empty():
		return null
	var monitor := NativePerformanceMonitor.new()
	monitor.output_path = path
	monitor.sample_limit = frames
	campaign.add_child(monitor)
	return monitor


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_metadata = {"schema_version": 1, "engine": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(), "vendor": RenderingServer.get_video_adapter_vendor(),
		"renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name(),
		"display_server": DisplayServer.get_name(), "platform": OS.get_name(),
		"headless_cpu_only": DisplayServer.get_name() == "headless",
		"neural_rendering_verified": false,
		"method": "Godot frame intervals during active gameplay; loading, pause and first 60 frames excluded; no generated-frame FPS claim"}


func _process(_delta: float) -> void:
	if _saved:
		return
	var now: int = Time.get_ticks_usec()
	var candidate: Variant = get_parent().get("current_level")
	if not is_instance_valid(candidate):
		_previous_tick = 0
		return
	var level: OriginalLevel = candidate as OriginalLevel
	if get_tree().paused or level == null or not level._ready_ok or level.process_mode == Node.PROCESS_MODE_DISABLED:
		_previous_tick = 0
		return
	if _chapter != str(level.entry.get("id", "")):
		_chapter = str(level.entry.get("id", ""))
		_previous_tick = 0
		warmup = 60
	if warmup > 0:
		warmup -= 1
		_previous_tick = now
		return
	if _previous_tick > 0:
		_samples.append(float(now - _previous_tick) / 1000.0)
	_previous_tick = now
	if _samples.size() % 30 == 0:
		_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_memory_peak = maxi(_memory_peak, OS.get_static_memory_usage())
		_video_memory_peak = maxi(_video_memory_peak, int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)))
	if _samples.size() >= sample_limit:
		_save()


func _exit_tree() -> void:
	if not _saved and not _samples.is_empty():
		_save()


func _save() -> void:
	if _saved or _samples.is_empty():
		return
	_saved = true
	var report: Dictionary = _metadata.duplicate()
	report["frames"] = _samples.size()
	report["frame_ms"] = summarize(_samples)
	report["draw_call_snapshots"] = summarize(_draw_calls)
	report["memory_static_peak_bytes"] = _memory_peak
	report["video_memory_peak_bytes"] = _video_memory_peak
	report["last_chapter"] = _chapter
	var viewport: Viewport = get_viewport()
	if is_instance_valid(viewport):
		report["output_size"] = [viewport.get_visible_rect().size.x, viewport.get_visible_rect().size.y]
		report["render_scale"] = viewport.scaling_3d_scale
		report["msaa_mode"] = viewport.msaa_3d
	var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_warning("Cannot write performance report: " + output_path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PERFORMANCE_REPORT ", output_path)


static func summarize(input: PackedFloat64Array) -> Dictionary:
	if input.is_empty():
		return {}
	var values: PackedFloat64Array = input.duplicate()
	values.sort()
	var total: float = 0.0
	for value: float in values:
		total += value
	return {"mean": total / values.size(), "p50": values[int(values.size() * 0.5)],
		"p95": values[mini(values.size() - 1, int(values.size() * 0.95))],
		"p99": values[mini(values.size() - 1, int(values.size() * 0.99))], "max": values[-1]}
