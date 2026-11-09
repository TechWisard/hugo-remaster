extends SceneTree
## Finale routing fixture, not an eight-chapter playthrough. Only startup and
## the final chapter's completion are arranged by this test. The production
## finish handler, HUD signals, outro decoder, Input skip and credits dialog run
## unchanged. Headless playback position does not prove GPU picture or audio.

const TEST_PATH: String = "user://campaign_ending_test.json"
const Localizer = preload("res://scripts/native_localization.gd")
const VoiceLibrary = preload("res://scripts/native_voice_library.gd")


class Fixture extends HugoCampaign:
	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		_load_catalog()
		state = CampaignState.new()
		state.path = TEST_PATH
		_apply_settings(false, false)


var checks: int = 0
var failures: Array[String] = []
var evidence: Dictionary = {"fixture": "direct final-chapter finish", "continuous_playthrough": false,
	"gpu_picture_verified": false, "audio_output_verified": false}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var required: Array[String] = ["res://assets/generated/campaign.json", "res://assets/generated/media_manifest.json"]
	for path: String in required:
		if not FileAccess.file_exists(path):
			print("SKIP CAMPAIGN_ENDING imported campaign/media unavailable: ", path)
			quit(0)
			return
	var media: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(required[1]))
	var credits_path: String = "res://assets/generated/" + str(media.get("credits", {}).get("path", ""))
	var available: Dictionary = VoiceLibrary.resolve_movie("outro", media.get("movies", {}).get("outro", {}))
	if not FileAccess.file_exists(credits_path) or not bool(available.get("available", false)):
		print("SKIP CAMPAIGN_ENDING imported outro/credits unavailable")
		quit(0)
		return
	_cleanup()
	var game := Fixture.new()
	root.add_child(game)
	await game._start_level("g069", false)
	_check(game.current_index == 7 and is_instance_valid(game.current_level) and game.current_level._ready_ok,
		"fixture loads the real final chapter through the production campaign loader")
	if not is_instance_valid(game.current_level) or not game.current_level._ready_ok:
		await _finish(game)
		return
	var level: OriginalLevel = game.current_level
	# Avoid unrelated enemies while arranging the final exit. This is deliberately
	# a completion fixture; continuous normal-input routes have a separate gate.
	level.scopes.suspended = true
	level.finish_level()
	_check(level.completed and game.state.completed_levels.has("g069"),
		"real finish handler records the final chapter")
	_check(level.hud.modal.visible and level.hud.next_button.visible \
		and level.hud.next_button.text == Localizer.text("hud.finale"),
		"completed chapter exposes the localized Finale button")
	var lives_after_finish: int = level.lives
	level.finish_level()
	_check(level.lives == lives_after_finish, "duplicate final exit cannot award the finish reward twice")
	var requested: Dictionary = VoiceLibrary.resolve_movie("outro", game.media.get("movies", {}).get("outro", {}))
	# Use the actual UI signal chain HUD -> OriginalLevel -> HugoCampaign.
	level.hud.next_button.pressed.emit()
	await _ticks(2)
	var movie: CampaignCinematic = _find_movie(game)
	_check(is_instance_valid(movie) and game._transitioning,
		"Finale button creates the real outro and holds the campaign transition")
	if not is_instance_valid(movie):
		await _finish(game)
		return
	_check(movie.movie_key == "outro" and movie.stream_path == str(requested.get("path", "")),
		"the outro uses the complete movie selected by the production voice resolver")
	_check(movie._video != null and movie._video.stream != null and movie._video.is_playing(),
		"production VideoStreamPlayer opens and starts the imported outro")
	_check(level.process_mode == Node.PROCESS_MODE_DISABLED and not level.hud.visible and not paused,
		"movie playback suspends the completed world and releases the finish pause")
	var started: int = Time.get_ticks_msec()
	while is_instance_valid(movie) and movie._video.stream_position < 1.2 \
			and Time.get_ticks_msec() - started < 8000:
		await _ticks(1)
	var position: float = movie._video.stream_position if is_instance_valid(movie) else 0.0
	_check(is_instance_valid(movie) and position >= 1.2,
		"actual outro decoding advances playback by at least1.2seconds")
	evidence["outro_position_seconds"] = position
	evidence["outro_key"] = "outro"
	evidence["effective_voice_locale"] = str(requested.get("effective_locale", ""))
	evidence["source_sha256"] = str(requested.get("source_sha256", ""))
	# Input.parse_input_event enters Godot's normal event propagation. Do not call
	# Cinematic._finish or replace its handler with a test double.
	var skip := InputEventAction.new()
	skip.action = "jump"
	skip.pressed = true
	Input.parse_input_event(skip)
	await _ticks(2)
	skip = InputEventAction.new()
	skip.action = "jump"
	skip.pressed = false
	Input.parse_input_event(skip)
	await _ticks(2)
	_check(not is_instance_valid(movie), "normal jump input skips and frees the real cinematic")
	var credits: AcceptDialog = _find_credits(game)
	_check(is_instance_valid(credits) and credits.visible,
		"outro completion creates the production credits dialog")
	_check(is_instance_valid(game.menu) and not game._transitioning and not paused,
		"the main menu is available after the ending transition")
	if is_instance_valid(credits):
		_check(credits.title == Localizer.text("credits.title") \
			and credits.get_ok_button().text == Localizer.text("credits.menu"),
			"credits title and return button use the current UI language")
		var source_text: String = FileAccess.get_file_as_string(credits_path)
		var displayed: Label
		# Dialog-owned default labels can be empty; inspect the production scroll
		# content explicitly instead of accepting any label on the window.
		for child: Node in credits.get_children():
			if child is ScrollContainer:
				for item: Node in child.get_children():
					if item is Label:
						displayed = item as Label
		_check(displayed != null and not source_text.is_empty() and displayed.text == source_text,
			"credits scroll displays the actual imported source text")
		credits.get_ok_button().pressed.emit()
		await _ticks(2)
		_check(not is_instance_valid(credits) and is_instance_valid(game.menu),
			"the real credits return-button signal closes the dialog and leaves the menu")
	var saved := CampaignState.new()
	saved.path = TEST_PATH
	var ids: Array[String] = []
	for entry: Dictionary in game.levels:
		ids.append(str(entry.id))
	_check(saved.read_save(ids) and saved.completed_levels.has("g069") \
		and saved.runs.get("g069", {}).get("finish_rewards_applied", false),
		"return to menu preserves final completion and its single reward marker")
	evidence["display_server"] = DisplayServer.get_name()
	await _finish(game)


func _find_movie(game: HugoCampaign) -> CampaignCinematic:
	for child: Node in game.get_children():
		if child is CampaignCinematic:
			return child as CampaignCinematic
	return null


func _find_credits(game: HugoCampaign) -> AcceptDialog:
	for child: Node in game.get_children():
		if child is AcceptDialog and child.title == Localizer.text("credits.title"):
			return child as AcceptDialog
	return null


func _ticks(count: int) -> void:
	for index: int in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _finish(game: HugoCampaign) -> void:
	paused = false
	game.queue_free()
	await _ticks(2)
	_cleanup()
	print("CAMPAIGN_ENDING checks=", checks, " failures=", JSON.stringify(failures), " evidence=", JSON.stringify(evidence))
	quit(0 if failures.is_empty() else 1)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
