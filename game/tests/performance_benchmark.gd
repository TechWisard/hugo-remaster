extends SceneTree
## Explicit benchmark, not a timing-sensitive pass/fail test.
## --headless --fixed-fps 60 --script ... -- --benchmark-out=... [--benchmark-level=g006]
## Headless results measure CPU-side work only. Rendered runs describe their adapter.

const Probe = preload("res://tests/performance_level_probe.gd")
const Graphics = preload("res://scripts/native_graphics_settings.gd")
const ResourceData = preload("res://scripts/native_resource_data.gd")
const Graph = preload("res://scripts/native_graph_colliders.gd")
const Materials = preload("res://scripts/native_materials.gd")
const Geometry = preload("res://scripts/native_geometry_quality.gd")
var output_path: String = "user://performance_benchmark.json"
var selected: String = ""
var sample_frames: int = 180
var rounds: int = 3
var random_seed: int = 24680
var quality: String = "enhanced"
var texture_limit: int = 0
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
		elif arg.begins_with("--benchmark-seed="):
			random_seed = int(arg.trim_prefix("--benchmark-seed="))
		elif arg.begins_with("--benchmark-quality="):
			quality = arg.trim_prefix("--benchmark-quality=")
		elif arg.begins_with("--benchmark-texture-limit="):
			texture_limit = int(arg.trim_prefix("--benchmark-texture-limit="))
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
	if not quality in ["original","enhanced"] or not texture_limit in [0,512,1024,2048]:
		push_error("Benchmark quality must be original/enhanced and texture limit 0/512/1024/2048")
		quit(1)
		return
	options.texture_quality = quality
	options.texture_limit = texture_limit
	Graphics.apply(root, options, false)
	var catalog: Dictionary = _json("res://assets/generated/campaign.json")
	var gameplay: Dictionary = _json("res://assets/generated/gameplay_manifest.json")
	for round_index: int in range(rounds):
		for entry: Dictionary in catalog.get("levels", []):
			if not selected.is_empty() and str(entry.id) != selected:
				continue
			# Reset each scene so repeated rounds compare the same authored RNG
			# state. This does not control operating-system scheduling or GPU work.
			seed(random_seed)
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
			var collider_before: Dictionary = _collider_counters(level)
			var frame_times := PackedFloat64Array()
			var process_times := PackedFloat64Array()
			var physics_times := PackedFloat64Array()
			var previous: int = Time.get_ticks_usec()
			Materials.reset_animation_profile()
			for tick: int in range(sample_frames):
				await process_frame
				var now: int = Time.get_ticks_usec()
				frame_times.append(float(now - previous) / 1000.0)
				previous = now
				process_times.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
				physics_times.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
			var material_profile: Dictionary = Materials.stop_animation_profile()
			var row: Dictionary = {"chapter": entry.id, "round": round_index,
				"json_ms": json_ms, "ready_ms": load_ms, "stage_ms": level.get("stage_ms"),
				"frame_wall_ms": _summary(frame_times), "frame_samples_ms": frame_times,
				"engine_process_ms": _summary(process_times),
				"engine_physics_ms": _summary(physics_times), "memory_static_bytes": OS.get_static_memory_usage(),
				"render_video_memory_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
				"render_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
				"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				"active_actors": level.state_actors.size(), "player_on_floor": level.player.is_on_floor(),
				"geometry": Geometry.get_status(), "material_animation_cpu": material_profile,
				"collider_before": collider_before, "collider_after": _collider_counters(level)}
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
		"rng_seed_per_chapter": random_seed,
		"quality": quality, "texture_limit": texture_limit,
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
	values = values.duplicate()
	values.sort()
	var total: float = 0.0
	for value: float in values:
		total += value
	return {"p50": values[int(values.size() * 0.5)], "p95": values[mini(values.size() - 1, int(values.size() * 0.95))],
		"max": values[-1], "mean": total / maxi(values.size(), 1)}


func _json(path: String) -> Dictionary:
	return ResourceData.read(path)


func _collider_counters(level: OriginalLevel) -> Dictionary:
	# Snapshots are outside the timed frame loop. Older exported builds expose
	# fewer counters; report only fields actually present on that class.
	var peers: Array = Graph._spaces.get(level.get_instance_id(), [])
	var result: Dictionary = {"peers": peers.size(), "active": 0,
		"animated_active": 0, "physical_active": 0, "active_states": []}
	if peers.is_empty():
		return result
	var names: Array[String] = []
	var wanted: Array[String] = ["refreshed_poses", "reused_poses", "sampled_local_poses",
		"reused_local_poses", "physical_layer_changes"]
	for property: Dictionary in (peers[0] as Node).get_property_list():
		var name: String = str(property.name)
		if name in wanted:
			names.append(name)
			result[name] = 0
	for peer: NativeGraphColliders in peers:
		for name: String in names:
			result[name] = int(result[name]) + int(peer.get(name))
		if peer.active_boxes.is_empty():
			continue
		result.active += 1
		var animated: bool = false
		for item: Dictionary in peer._actions.get(peer.active_action, []):
			for track: Dictionary in item.chain:
				animated = animated or (track.get("translation_keys", []) as Array).size() > 1 or (track.get("rotation_keys", []) as Array).size() > 1
		var physical: bool = is_instance_valid(peer.physical_body) and peer.physical_body.collision_layer != 0
		result.animated_active += int(animated)
		result.physical_active += int(physical)
		result.active_states.append({"id": str(peer.source.get("id", "player")),
			"action": peer.active_action, "phase": peer.sampled_phase, "animated": animated,
			"physical": physical, "boxes": peer.active_boxes.size()})
	return result
