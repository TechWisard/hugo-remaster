extends SceneTree
## Real source player: damage, lethal cooldown bypass and interrupted-death saves.

const LevelScript = preload("res://scripts/original_level.gd")
var checks: int = 0
var failures: Array[String] = []
var entry: Dictionary
var level_data: Dictionary
var gameplay: Dictionary


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("SKIP imported source assets unavailable")
		quit(0)
		return
	entry = _json("res://assets/generated/campaign.json").levels[0]
	level_data = _json("res://assets/generated/" + str(entry.manifest_path))
	gameplay = _json("res://assets/generated/gameplay_manifest.json")
	var level := _level()
	await _ticks(40)
	_check(level.player.is_on_floor() and level.health == 10 and level.lives == 4, "source player starts alive on the native floor")
	_check(level.damage_player(1, level.player.global_position + Vector3.RIGHT, 0.0), "ordinary native damage applies")
	_check(level.health == 8, "event03 adds the normal-difficulty damage point")
	_check(not level.damage_player(1, level.player.global_position, 0.0), "ordinary damage respects invulnerability")
	_check(level.damage_player(1000, level.player.global_position, 0.0), "lethal source damage bypasses both cooldowns")
	var save := CampaignState.new()
	save.set_run(str(entry.id), level.run_state())
	var interrupted: Dictionary = save.runs[entry.id].duplicate(true)
	_check(interrupted.death_pending and interrupted.lives == 3, "save commits the life before the deferred death starts")
	await _ticks(2)
	_check(level._death_in_progress and level.lives == 3, "death animation spends exactly one life")
	_check(level.run_state().lives == 3, "saving during the animation does not spend a second life")
	for i: int in range(300):
		if not level._death_in_progress:
			break
		await _ticks(1)
	_check(not level._death_in_progress and level.health == level.max_health and level.lives == 3, "native death duration ends with checkpoint recovery")
	_check(not level.run_state().death_pending and level.player.controls_enabled, "recovered run is playable and no longer death-pending")
	level.queue_free()
	await _ticks(2)
	level = _level(interrupted)
	await _ticks(8)
	_check(level.health == level.max_health and level.lives == 3, "resume during a death restores the checkpoint with the committed life count")
	_check(level.player.global_position.distance_to(level.spawn_point) < 1.0 and level.player.controls_enabled, "interrupted death never resumes in the lethal location")
	_check(not level.run_state().death_pending, "resumed death clears its transient marker")
	# A fatal hit on the last life must remain game over after restart.
	level.lives = 1
	level.health = level.max_health
	_check(level.damage_player(1000, level.player.global_position, 0.0), "last-life lethal source damage applies")
	save.set_run(str(entry.id), level.run_state())
	var game_over: Dictionary = save.runs[entry.id].duplicate(true)
	_check(game_over.death_pending and game_over.lives == 0, "last-life save commits zero remaining lives")
	for i: int in range(300):
		await _ticks(1)
		if not level._death_in_progress and level.lives == 0:
			break
	level.queue_free()
	await _ticks(2)
	level = _level(game_over)
	await _ticks(3)
	_check(level.health == 0 and level.lives == 0 and level.hud.modal.visible, "zero-life resume remains game over")
	_check(not level.player.controls_enabled and not level.damage_player(1000, level.player.global_position), "game over cannot move or spend another life")
	level.queue_free()
	await _ticks(2)
	print("NATIVE_LIFE checks=", checks, " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _level(saved: Dictionary = {}) -> OriginalLevel:
	var level: OriginalLevel = LevelScript.new()
	level.entry = entry
	level.data = level_data
	level.gameplay = gameplay.levels[entry.id]
	level.native_rules = gameplay.native_rules
	level.restored_run = saved
	root.add_child(level)
	level.scopes.suspended = true
	return level


func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
