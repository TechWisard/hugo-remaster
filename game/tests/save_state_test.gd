extends SceneTree
## Save round-trip, checkpoint isolation, validation and interrupted-write recovery.

const SaveScript = preload("res://scripts/campaign_state.gd")
const TEST_PATH: String = "user://save_integrity_test.json"
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	var state: CampaignState = SaveScript.new()
	state.path = TEST_PATH
	state.difficulty = 2
	state.qualified_levels["g006"] = true
	state.completed_levels["g006"] = true
	state.set_run("g017", {"collected": ["diamond", "diamond", 99], "health": 7, "lives": 3,
		"completed": true, "finish_rewards_applied": true, "death_pending": true,
		"diamonds": 12, "elapsed": 48.5, "player_position": [4.0, 2.0, -9.0], "player_facing": 1.2,
		"actors": {"enemy": {"state": 2, "previous_state": 1, "health": 3, "visual_phase": 2.5,
			"path_phase": 1.8, "elapsed": 1.5, "removed": false,
			"transform": [1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 5, 6]}},
		"scopes": {"resident_groups": [18, 19]}, "scope_removed_actors": ["unloaded_enemy"],
		"camera": {"native_phase": 0.45, "camera_position": [3, 8, 9], "camera_basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]},
		"checkpoint_state": {"collected": ["earlier"], "removed_actors": ["old_enemy"],
			"resident_groups": [18], "camera": {"native_phase": 0.2, "camera_position": [1, 5, 7], "camera_basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]},
			"diamonds": 8, "checkpoint_position": [1, 2, 3], "checkpoint_facing": 0.7}})
	_check(state.write_save(), "write an original campaign snapshot")
	var read: CampaignState = SaveScript.new()
	read.path = TEST_PATH
	_check(read.read_save(["g006", "g017"]), "read a valid snapshot")
	_check(read.difficulty == 2 and read.total_lives == 3, "native global stats round trip")
	_check(read.qualified_levels.has("g006"), "qualified-level health bonus persists")
	var run: Dictionary = read.runs.g017
	_check(run.collected == ["diamond"], "IDs are deduplicated and numeric junk removed")
	_check(run.actors.enemy.state == 2 and is_equal_approx(run.actors.enemy.visual_phase, 2.5), "actor state and phase persist")
	_check(run.actors.enemy.transform[11] == 6.0, "actor world transform persists")
	_check(run.player_position == [4.0, 2.0, -9.0], "resume position persists")
	_check(run.checkpoint_state.diamonds == 8 and run.diamonds == 12, "checkpoint and current counters stay distinct")
	_check(run.checkpoint_state.removed_actors == ["old_enemy"], "native removed-actor snapshot persists")
	_check(run.scopes.resident_groups == [18, 19] and run.checkpoint_state.resident_groups == [18], "current and checkpoint segment membership stay distinct")
	_check(run.scope_removed_actors == ["unloaded_enemy"], "removed actors survive unloaded segments")
	_check(is_equal_approx(run.camera.native_phase, 0.45) and is_equal_approx(run.checkpoint_state.camera.native_phase, 0.2), "current and checkpoint native camera trackers persist")
	_check(run.camera.camera_position == [3.0, 8.0, 9.0] and run.camera.camera_basis[2] == [0.0, 0.0, 1.0], "native camera pose persists")
	_check(run.completed and run.finish_rewards_applied, "completed run and one-time finish reward persist")
	_check(run.death_pending, "interrupted native death state persists")
	state.set_run("g017", {"diamonds": 23, "health": 8, "lives": 2})
	_check(state.write_save(), "second write retains a backup")
	var corrupt := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	corrupt.store_string("{interrupted save")
	corrupt.close()
	var recovery: CampaignState = SaveScript.new()
	recovery.path = TEST_PATH
	_check(recovery.read_save(["g006", "g017"]), "recover after an interrupted primary write")
	_check(recovery.recovered_backup and recovery.runs.g017.diamonds == 12, "recover last complete backup contents")
	_check(recovery.write_save(), "can save after recovery")
	_check(FileAccess.file_exists(TEST_PATH + ".invalid"), "retain corrupt primary while replacing it")
	var whitelist: CampaignState = SaveScript.new()
	whitelist.path = TEST_PATH
	_check(whitelist.read_save(["g006"]), "read with changed chapter catalog")
	_check(whitelist.level_id.is_empty() and whitelist.runs.is_empty(), "reject progress for unknown chapters")
	state.set_run("g006", {"player_position": [NAN, 0, 0], "moved": {"bad": [INF, 0, 0]},
		"actors": {"bad": "not an actor"}, "health": "not a number",
		"scopes": {"resident_groups": [18, 18, -2, "junk", 19.5, 19, 20]},
		"camera": {"native_phase": 0.5, "camera_position": [1, 2, INF], "camera_basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]}})
	_check(not state.runs.g006.has("player_position") and state.runs.g006.moved.is_empty(), "reject non-finite coordinates")
	_check(state.runs.g006.actors.is_empty() and state.runs.g006.health == 0, "sanitize malformed actor and stat fields")
	_check(state.runs.g006.scopes.resident_groups == [18, 19], "sanitize and bound resident segment membership")
	_check(not state.runs.g006.has("camera"), "reject non-finite native camera pose")
	_cleanup()
	print("SAVE_STATE_TEST checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
