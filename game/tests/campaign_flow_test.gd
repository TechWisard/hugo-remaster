extends SceneTree
## Exercise the real campaign controller with imported chapters and a movie recorder.
## Video decoding is verified separately by media_smoke.gd. This is not a playthrough.

const TEST_PATH: String = "user://campaign_flow_test.json"
var checks: int = 0
var failures: Array[String] = []


class Harness:
	extends HugoCampaign
	var movie_requests: Array[String] = []
	var credits_shown: bool = false

	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		_load_catalog()
		state = CampaignState.new()
		state.path = "user://campaign_flow_test.json"

	func _play_movies(keys: Array) -> void:
		for key: String in keys:
			movie_requests.append(key)
		await get_tree().process_frame

	func _show_credits() -> void:
		credits_shown = true
		_show_menu()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists("res://assets/generated/campaign.json"):
		print("SKIP imported campaign unavailable")
		quit(0)
		return
	_cleanup()
	var game := Harness.new()
	root.add_child(game)
	await game._boot()
	_check(game.movie_requests == ["logo", "intro_a"] and is_instance_valid(game.menu), "original logo and intro A precede the main menu")
	game._new_game()
	await _wait_for_chapter(game, 0)
	_check(game.movie_requests == ["logo", "intro_a", "intro_b"], "new game requests intro B after the boot introduction")
	_check(game.current_index == 0 and game.current_level._ready_ok, "new game enters the beach")
	# Qualification is rewritten by a fresh replay, but a finished resume must
	# preserve the previously awarded result and never grant another life.
	_finish_with_all_rewards(game)
	var first_lives: int = game.current_level.lives
	_check(first_lives == 5 and game.state.qualified_levels.has("g006"), "native finish rewards apply once")
	game._show_menu()
	await game._start_level("g006", true)
	await _ticks(3)
	_check(game.current_level.completed and game.current_level.hud.modal.visible, "continue restores a completed chapter and its continuation")
	_check(game.current_level.lives == first_lives and game.current_level.finish_rewards_applied, "continue cannot repeat the finish life reward")
	_check(game.state.qualified_levels.has("g006"), "completed resume preserves qualification")
	await game._start_level("g006", false)
	await _ticks(2)
	game.current_level.scopes.suspended = true
	game.current_level.diamonds = 0
	game.current_level.finish_level()
	_check(not game.state.qualified_levels.has("g006"), "fresh low-score replay rewrites native qualification")
	for index: int in range(8):
		if index > 0:
			_finish_with_all_rewards(game)
		var level: OriginalLevel = game.current_level
		_check(level.completed and game.state.completed_levels.has(str(game.levels[index].id)), "chapter %d records completion" % (index + 1))
		_check(level.finish_rewards_applied and game.state.runs[str(game.levels[index].id)].finish_rewards_applied, "chapter %d saves its finish reward marker" % (index + 1))
		var before: int = level.lives
		level.finish_level()
		_check(level.lives == before, "chapter %d ignores duplicate exit" % (index + 1))
		if index == 7:
			_check(not game.state.qualified_levels.has("g069"), "Getaway does not grant a qualification health bonus")
			_check(level.hud.next_button.visible and level.hud.next_button.text == "Финал", "last chapter offers the original ending")
		game._next_level()
		if index < 7:
			await _wait_for_chapter(game, index + 1)
			_check(game.current_index == index + 1 and game.current_level._ready_ok, "transition loads chapter %d" % (index + 2))
		else:
			await _ticks(4)
	_check(game.credits_shown and is_instance_valid(game.menu), "ending returns to credits and main menu")
	_check(game.state.completed_levels.size() == 8, "all eight completion flags persist")
	_check(game.movie_requests == ["logo", "intro_a", "intro_b", "plan_on_track", "more_power_1", "more_power_2", "lost_juice", "outro"], "campaign requests all original cutscenes in order")
	var saved := CampaignState.new()
	saved.path = TEST_PATH
	var ids: Array[String] = []
	for entry: Dictionary in game.levels:
		ids.append(str(entry.id))
	_check(saved.read_save(ids) and saved.completed_levels.size() == 8 and saved.runs.g069.completed, "full campaign completion survives a save reload")
	game._select_chapter("g027", false)
	await _wait_for_chapter(game, 2)
	_check(game.movie_requests[-1] == "plan_on_track" and game.current_index == 2, "chapter selection plays its source preceding movie")
	var movie_count: int = game.movie_requests.size()
	game._show_menu()
	game._select_chapter("g027", true)
	await _wait_for_chapter(game, 2)
	_check(game.movie_requests.size() == movie_count, "continue resumes without replaying a preceding movie")
	var requested: Array[String] = game.movie_requests.duplicate()
	game.queue_free()
	await _ticks(2)
	_cleanup()
	print("CAMPAIGN_FLOW checks=", checks, " failures=", JSON.stringify(failures), " movies=", JSON.stringify(requested))
	quit(0 if failures.is_empty() else 1)


func _finish_with_all_rewards(game: Harness) -> void:
	var level: OriginalLevel = game.current_level
	level.scopes.suspended = true
	level.diamonds = level.total_diamonds
	for id: String in level.gameplay.get("checkpoints", []):
		level.activated[id] = true
	level.finish_level()


func _wait_for_chapter(game: Harness, index: int) -> void:
	for i: int in range(240):
		await process_frame
		if game.current_index == index and not game._transitioning and is_instance_valid(game.current_level) and game.current_level._ready_ok:
			return
	_check(false, "chapter load timed out: " + str(index))


func _ticks(count: int) -> void:
	for i: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
