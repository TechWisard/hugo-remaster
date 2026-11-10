extends SceneTree
const Status = preload("res://scripts/native_neural_status.gd")
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, description: String) -> void:
	checks += 1
	if not value: failures.append(description)

func _run() -> void:
	var session := "e744fb21a7e7444a88190b873f4fc9f7"
	var request := Status.parse_arguments(PackedStringArray([
		"--dlss5-profile", "--nr-status-file=C:/Hugo/status.json", "--nr-session="+session]))
	_check(request.requested and request.error.is_empty(), "Absolute Windows status path and current nonce")
	_check(not Status.parse_arguments(PackedStringArray()).requested, "Standard launch does not claim a neural provider")
	_check(not Status.parse_arguments(PackedStringArray(["--dlss5-profile"])).error.is_empty(), "Profile flag alone is not evidence")
	_check(not Status.parse_arguments(PackedStringArray(["--nr-status-file=res://status.json", "--nr-session="+session])).error.is_empty(), "Packaged data cannot serve as a current runtime report")
	_check(not Status.parse_arguments(PackedStringArray(["--nr-status-file=C:/first.json", "--nr-status-file=C:/second.json", "--nr-session="+session])).error.is_empty(), "Ambiguous status paths fail closed")
	var stamp := "2026-11-09T12:00:00.0000000Z"
	var now := float(Time.get_unix_time_from_datetime_string(stamp.substr(0,19)))
	var report := {"schema":1,"session":session,"provider":"gitc_uplift_opengl",
		"state":"backend_reported","reason_code":"current_game_markers", "frames_processed":null,
		"updated_utc":stamp,"process_id":4242,"display_verified":true}
	var checked: Dictionary = Status.validate_report(report, request, now, 4242)
	_check(checked.state == "backend_reported", "Current process/session backend report is recognized")
	_check(not checked.display_verified, "Backend markers cannot elevate to verified screen presentation")
	_check(checked.frames_processed == null, "No invented frame count from a once-per-enable message")
	_check(Status.validate_report(report, request, now + 11, 4242).state == "unverified", "Stale heartbeat is not shown as active evidence")
	_check(Status.validate_report(report, request, now - 3, 4242).state == "unverified", "Future timestamp is not current evidence")
	_check(Status.validate_report(report, request, now, 9999).state == "unverified", "Another game process cannot supply this process evidence")
	for field: String in ["session", "provider", "state", "schema", "updated_utc", "frames_processed"]:
		var changed: Dictionary = report.duplicate(true)
		changed[field] = {"session":"different-run-000000", "provider":"none", "state":"display_verified", "schema":0, "updated_utc":"bad", "frames_processed":-1}[field]
		_check(Status.validate_report(changed, request, now, 4242).state == "unverified", "Reject invalid " + field)
	for state: String in ["probing", "inactive", "failed"]:
		var changed: Dictionary = report.duplicate(true)
		changed.state = state
		changed.provider = "none" if state == "inactive" else "gitc_uplift_opengl"
		var result: Dictionary = Status.validate_report(changed, request, now, 4242)
		_check(result.state == state and not result.display_verified, "Explicit " + state + " survives without a neural-success claim")
	_check(Status.validate_report({"schema":1,"neural_frame_reported":true}, request, now, 4242).state == "unverified", "An old aggregate Verify report is not a live session report")
	_check(Status.validate_report(null, request, now, 4242).state == "unverified", "Truncated JSON cannot become success")
	print("NEURAL_STATUS checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)
