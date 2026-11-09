extends SceneTree
## Launch the real campaign entry point; no test subclass bypasses its startup.

const ProbeScript = preload("res://scripts/native_graphics_probe.gd")
var checks: int = 0
var failures: Array[String] = []
var _directory: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_directory = OS.get_temp_dir().path_join("hugo_graphics_probe_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(_directory) == OK, "the integration test has its own temporary directory")
	var path: String = _directory.path_join("headless.json")
	var run: Dictionary = _launch(["--graphics-probe=" + path, "--graphics-probe-frames=1", "--level=not_a_chapter"])
	_check(run.exit_code == 2, "a headless probe cannot claim a successful rendered window")
	_check(FileAccess.file_exists(path), "the real campaign preflight writes its requested report")
	var report: Dictionary = _read_report(path)
	_check(report.get("schema") == 1 and report.get("headless") == true, "the report has a stable version and identifies headless")
	_check(report.get("hardware_verified") == false and report.get("success") == false and report.get("rendered_frames") == 0,
		"headless startup never manufactures GPU or framebuffer evidence")
	_check(report.get("neural_rendering_verified") == false, "Godot does not claim an external neural pass")
	_check(report.get("requested_frames") == 3, "an undersized frame request is bounded to three frames")
	_check(report.get("campaign_loaded") == false and report.get("media_loaded") == false and report.get("save_loaded") == false,
		"probe startup bypasses levels, movies and the user's save even with a level argument")
	_check(report.get("msaa_samples") == 4 and report.get("render_scale") == 1.0, "ordinary preflight applies the standard renderer settings")
	_check("SCRIPT ERROR" not in run.output and "Unknown original chapter" not in run.output, "the real startup takes only the preflight branch")
	var original: String = FileAccess.get_file_as_string(path)
	run = _launch(["--graphics-probe=" + path, "--graphics-probe-frames=3"])
	_check(run.exit_code == 2 and FileAccess.get_file_as_string(path) == original, "an existing report is refused without overwriting its contents")
	var safe_path: String = _directory.path_join("safe.json")
	run = _launch(["--graphics-probe=" + safe_path, "--graphics-probe-frames=3", "--graphics-safe-profile"])
	var safe: Dictionary = _read_report(safe_path)
	_check(run.exit_code == 2 and safe.get("msaa_samples") == 2 and safe.get("render_scale") == 1.0,
		"the actual compatible launch uses two-sample AA at native resolution")
	_check(safe.get("external_profile") == "safe" and safe.get("save_loaded") == false, "safe preflight leaves campaign preferences untouched")
	var invalid_path: String = _directory.path_join("invalid.json")
	run = _launch(["--graphics-probe=" + invalid_path, "--graphics-probe-frames=invalid"])
	var invalid: Dictionary = _read_report(invalid_path)
	_check(run.exit_code == 2 and invalid.get("failure_reason") == "invalid_graphics_probe_frames", "invalid duration produces a bounded explicit failure")
	_check(invalid.get("success") == false and invalid.get("hardware_verified") == false, "an invalid request cannot become hardware evidence")
	_check(not ProbeScript.output_path_error("relative.json").is_empty(), "relative report paths are refused")
	_check(not ProbeScript.output_path_error("res://report.json").is_empty(), "resource paths cannot be overwritten by preflight")
	_check(not ProbeScript.output_path_error("user://report.json").is_empty(), "implicit save paths cannot be overwritten by preflight")
	_check(not ProbeScript.output_path_error(_directory.path_join("report.txt")).is_empty(), "only an explicit JSON report target is accepted")
	_check(not ProbeScript.output_path_error(_directory.path_join("missing/report.json")).is_empty(), "preflight does not create unrequested directory trees")
	var parsed: Dictionary = ProbeScript.parse_arguments(PackedStringArray(["--graphics-probe=" + path, "--graphics-probe-frames=999999"]))
	_check(parsed.frames == 3600, "frame requests have a finite upper bound")
	var files: PackedStringArray = DirAccess.get_files_at(_directory)
	_check(files.size() == 3 and not Array(files).any(func(name: String) -> bool: return ".tmp." in name), "atomic report writes leave no temporary files")
	for file: String in files:
		DirAccess.remove_absolute(_directory.path_join(file))
	DirAccess.remove_absolute(_directory)
	print("GRAPHICS_PROBE_TEST checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _launch(arguments: Array[String]) -> Dictionary:
	var output: Array = []
	var command: PackedStringArray = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--"]
	command.append_array(arguments)
	var exit_code: int = OS.execute(OS.get_executable_path(), command, output, true)
	return {"exit_code": exit_code, "output": "\n".join(output)}


func _read_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)
