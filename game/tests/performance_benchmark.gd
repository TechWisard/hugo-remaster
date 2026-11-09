extends SceneTree
## Explicit benchmark, not a timing-sensitive pass/fail test.
## --headless --fixed-fps 60 --script ... -- --benchmark-out=... [--benchmark-level=g006]
## Headless results measure CPU-side work only. Rendered runs describe their adapter.

const Probe = preload("res://tests/performance_level_probe.gd")
const Graphics = preload("res://scripts/native_graphics_settings.gd")
const ResourceData = preload("res://scripts/native_resource_data.gd")
var output_path: String = "user://performance_benchmark.json"
var selected: String = ""
var sample_frames: int = 180
var rounds: int = 3
var rows: Array[Dictionary] = []
var failures: Array[String] = []


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--benchmark-out="):
			output_path = arg.trim_prefix("--benchmark-out=")
		elif arg.begins_with("--benchmark-level="):
			selected = arg.trim_prefix("--benchmark-level=")
		elif arg.begins_with("--benchmark-frames="):
			sample_frames = clampi(int(arg.trim_prefix("--benchmark-frames=")), 30, 3600)
		elif arg.begins_with("--benchmark-rounds="):
			rounds = clampi(int(arg.trim_prefix("--benchmark-rounds=")), 1, 5)
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("SKIP performance benchmark: import original campaign first")
		quit(0)
		return
	for bus: String in ["Music", "Effects"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	var options: Dictionary = Graphics.defaults()
	options.vsync = false
	Graphics.apply(root, options, false)
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	var gameplay: Dictionary = _json("res://assets/generated/gameplay_manifest.json")
	for round_index: int in range(rounds):
		for entry: Dictionary in catalog.get("levels", []):
			if not selected.is_empty() and str(entry.id) != selected:
				continue
			var level: OriginalLevel = Probe.new()
			level.entry = entry
			var json_start: int = Time.get_ticks_usec()
			level.data = _json("res://assets/generated/" + str(entry.manifest_path))
			var json_ms: float = float(Time.get_ticks_usec() - json_start) / 1000.0
			level.gameplay = gameplay.levels[entry.id]
			level.native_rules = gameplay.get("native_rules", {})
			var start: int = Time.get_ticks_usec()
			root.add_child(level)
			var load_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
			if not level._ready_ok:
				failures.append(str(entry.id) + " failed initialization")
			for tick: int in range(60):
				await process_frame
			var frame_times := PackedFloat64Array()
			var process_times := PackedFloat64Array()
			var physics_times := PackedFloat64Array()
			var previous: int = Time.get_ticks_usec()
			for tick: int in range(sample_frames):
				await process_frame
				var now: int = Time.get_ticks_usec()
				frame_times.append(float(now - previous) / 1000.0)
				previous = now
				process_times.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
				physics_times.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
			var row: Dictionary = {"chapter": entry.id, "round": round_index,
				"json_ms": json_ms, "ready_ms": load_ms, "stage_ms": level.get("stage_ms"),
				"frame_wall_ms": _summary(frame_times), "engine_process_ms": _summary(process_times),
				"engine_physics_ms": _summary(physics_times), "memory_static_bytes": OS.get_static_memory_usage(),
				"render_video_memory_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
				"render_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
				"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				"active_actors": level.state_actors.size(), "player_on_floor": level.player.is_on_floor()}
			rows.append(row)
			print("PERFORMANCE_CHAPTER ", JSON.stringify(row))
			level.queue_free()
			await process_frame
			await process_frame
	var report: Dictionary = {"schema_version": 1, "engine": Engine.get_version_info().string,
		"display_server": DisplayServer.get_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(), "headless_cpu_only": DisplayServer.get_name() == "headless",
		"window": [root.size.x, root.size.y], "msaa": root.msaa_3d, "render_scale": root.scaling_3d_scale,
		"samples_per_chapter": sample_frames, "warmup_frames": 60, "rounds": rounds,
		"scene": "normal spawn, idle physics, no teleport, fixed 60 Hz simulation",
		"frame_metric": "wall intervals; includes scheduling/rendering; not a hardware-independent FPS promise",
		"engine_monitor_warning": "Godot monitor snapshots update periodically and can include preceding loading; use wall samples for interval comparisons",
		"binary_cache_hits": ResourceData.cache_hits, "json_fallback_reads": ResourceData.json_reads,
		"round_zero": "first load in this process; OS file cache is not flushed", "rows": rows, "failures": failures}
	var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write benchmark report")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PERFORMANCE_BENCHMARK ", JSON.stringify({"rows": rows.size(), "failures": failures, "output": output_path}))
	quit(0 if failures.is_empty() else 1)


func _summary(values: PackedFloat64Array) -> Dictionary:
	values.sort()
	var total: float = 0.0
	for value: float in values:
		total += value
	return {"p50": values[int(values.size() * 0.5)], "p95": values[mini(values.size() - 1, int(values.size() * 0.95))],
		"max": values[-1], "mean": total / maxi(values.size(), 1)}


func _json(path: String) -> Dictionary:
	return ResourceData.read(path)
