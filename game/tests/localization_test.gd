extends SceneTree
## Real controls change persisted independent languages; existing dialogs, HUD
## states, draft display options and toast lifetimes survive a live text switch.

const Localizer = preload("res://scripts/native_localization.gd")
const VoiceLibrary = preload("res://scripts/native_voice_library.gd")
const TEST_PATH: String = "user://localization_test.json"
var checks: int = 0
var failures: Array[String] = []
var _placeholder := RegEx.new()


class Harness extends HugoCampaign:
	var initial_voice: String = "ru"
	func _ready() -> void:
		RemasterInput.configure()
		_configure_audio()
		state = CampaignState.new()
		state.path = TEST_PATH
		state.settings.voice_locale = initial_voice
		state.set_run("first", {"diamonds": 3, "health": 8, "lives": 4, "elapsed": 42.0})
		levels = [{"id": "first", "main_group": 6, "source_name": "Beach", "title": "Beach"}]
		_apply_settings(false, false)
		_show_menu()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	_placeholder.compile("\\{([A-Za-z_]+)\\}")
	Localizer.set_text_locale("ru")
	var catalog: Dictionary = Localizer.catalog_snapshot()
	_check(Localizer.available_text_locales().size() == 16, "all sixteen supported text languages have authored catalogs")
	var english: Dictionary = catalog.get("en", {}).get("messages", {})
	var expected_keys: Array = english.keys()
	expected_keys.sort()
	var glyphs: Dictionary = {}
	for code: String in Localizer.LOCALES:
		_check(catalog.has(code), "authored catalog exists for " + code)
		if not catalog.has(code):
			continue
		var messages: Dictionary = catalog[code].messages
		var keys: Array = messages.keys()
		keys.sort()
		_check(keys == expected_keys, "all settings/help/dialog/HUD keys are covered in " + code)
		var valid: bool = true
		for key: String in expected_keys:
			var value: Variant = messages.get(key)
			if not value is String or value.is_empty() or _tokens(value) != _tokens(str(english[key])):
				valid = false
				continue
			for index: int in range(value.length()):
				var character: int = value.unicode_at(index)
				if character >= 32:
					glyphs[character] = true
		_check(valid, "translated placeholders and nonempty values are valid in " + code)
	for symbol: String in ["♥", "♡", "◇", "◆", "→"]:
		glyphs[symbol.unicode_at(0)] = true
	var missing: Array[int] = []
	for character: int in glyphs:
		if not ThemeDB.fallback_font.has_char(character):
			missing.append(character)
	_check(missing.is_empty(), "the bundled font and symbol fallback cover all authored text glyphs: " + str(missing))
	var strings: Array[String] = []
	strings.resize(205)
	strings.fill("")
	strings[51] = "A source chapter"
	_check(Localizer.validate_native_strings({"schema_version": 1, "locale": "en", "strings": strings}, "en").size() == 205,
		"native text preserves the original205 positional IDs, including empty slots")
	_check(Localizer.validate_native_strings({"schema_version": 1, "locale": "ru", "strings": strings}, "en").is_empty(),
		"a native table cannot be silently relabelled as another language")
	var native_bytes: PackedByteArray = JSON.stringify({"schema_version": 1, "locale": "en", "strings": strings}).to_utf8_buffer()
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(native_bytes)
	var correct_hash: String = digest.finish().hex_encode()
	_check(Localizer.decode_native_bytes(native_bytes, "en", {"sha256": correct_hash}).size() == 205,
		"a native text file with its actual SHA256 is accepted")
	var changed_bytes: PackedByteArray = native_bytes.duplicate()
	changed_bytes.append(32)
	_check(Localizer.decode_native_bytes(changed_bytes, "en", {"sha256": correct_hash}).is_empty(),
		"even a still-valid JSON change with a stale hash falls back to authored UI")
	_check(Localizer.decode_native_bytes(native_bytes, "en", {"sha256": "invalid"}).is_empty(),
		"a malformed native-text checksum is not treated as verified content")
	strings.pop_back()
	_check(Localizer.validate_native_strings({"schema_version": 1, "locale": "en", "strings": strings}, "en").is_empty(),
		"a truncated native text table falls back to authored UI")
	var native_count: int = 0
	var native_valid: bool = true
	for code: String in Localizer.LOCALES:
		if not VoiceLibrary.native_text_metadata(code).is_empty():
			native_count += 1
			native_valid = native_valid and not Localizer.native_text(23, "", code).is_empty()
	if native_count > 0:
		_check(native_valid, "every installed native205 table supplies its original brand text")
		_check(Localizer.chapter_title(27) == Localizer.native_text(56, "") and not Localizer.native_text(56, "").is_empty(),
			"a real imported chapter title overrides the authored fallback using original text ID56")
	else:
		_check(Localizer.chapter_title(27) == str(catalog.ru.messages["chapter.27"]),
			"without private original tables the complete authored chapter caption remains usable")
	# A partial installed catalog must not show its first language as the saved
	# selection. Only fixture metadata changes; no original files are modified.
	var live_manifest: Dictionary = VoiceLibrary.get_manifest()
	var complete_manifest: Dictionary = live_manifest.duplicate(true)
	live_manifest["voices"] = {"en": {"native_name": "English"}, "ru": {"native_name": "Русский"}}
	live_manifest["default_voice_locale"] = "ru"
	var partial_game := Harness.new()
	partial_game.initial_voice = "fr"
	root.add_child(partial_game)
	await process_frame
	var partial_voice: OptionButton = partial_game.menu.find_child("VoiceLocale", true, false) as OptionButton
	_check(partial_voice.is_item_disabled(partial_voice.selected) and partial_voice.get_item_text(partial_voice.selected) == "Français → Русский",
		"an unavailable saved voice shows requested-to-default fallback instead of the first unrelated installed language")
	_check(partial_game.state.settings.voice_locale == "fr" and VoiceLibrary.get_locale() == "fr" and "Français" in partial_voice.tooltip_text,
		"displaying voice fallback retains the independent saved request and explains it")
	_select_locale(partial_voice, "en")
	_check(partial_game.state.settings.voice_locale == "en" and VoiceLibrary.get_locale() == "en" and partial_voice.item_count == 2,
		"an explicit installed-voice choice applies normally and removes the stale fallback placeholder")
	partial_game.free()
	await process_frame
	live_manifest.clear()
	live_manifest.merge(complete_manifest, true)
	var game := Harness.new()
	root.add_child(game)
	await process_frame
	game.menu._show_options()
	var menu: CampaignMenu = game.menu
	var text_choice: OptionButton = menu.find_child("TextLocale", true, false) as OptionButton
	var voice_choice: OptionButton = menu.find_child("VoiceLocale", true, false) as OptionButton
	_check(text_choice != null and voice_choice != null, "the real menu offers separate text and voice controls")
	var installed: Array[String] = VoiceLibrary.available_locales()
	_check(voice_choice.disabled if installed.is_empty() else voice_choice.item_count == installed.size(),
		"voice choices expose only installed original packs, or a disabled original-track fallback")
	var resolution: OptionButton = menu.find_child("DisplayResolution", true, false) as OptionButton
	_select(resolution, resolution.item_count - 1)
	var width: SpinBox = menu.find_child("DisplayWidth", true, false) as SpinBox
	var height: SpinBox = menu.find_child("DisplayHeight", true, false) as SpinBox
	width.value = 3000
	height.value = 1250
	menu._options_scroll.scroll_vertical = 40
	width.get_line_edit().grab_focus()
	await process_frame
	var old_focus: Control = root.gui_get_focus_owner()
	var old_scroll: int = menu._options_scroll.scroll_vertical
	var old_voice: String = str(game.state.settings.voice_locale)
	_select_locale(text_choice, "en")
	_check(game.state.settings.text_locale == "en" and game.state.settings.voice_locale == old_voice,
		"a text selection updates text alone through the real settings signal")
	_check(menu == game.menu and text_choice == menu.find_child("TextLocale", true, false),
		"a live language switch retains the existing menu/control instances")
	_check(menu._display_draft.window_width == 3000 and menu._display_draft.window_height == 1250 and game.state.settings.graphics.window_width == 0,
		"a pending custom display draft survives without being committed")
	_check(root.gui_get_focus_owner() == old_focus and menu._options_scroll.scroll_vertical == old_scroll,
		"live text replacement preserves focus and scroll")
	_check((menu.find_child("ApplyDisplay", true, false) as Button).text == Localizer.text("display.apply"),
		"existing graphics controls refresh their displayed language")
	if "fr" in installed:
		_select_locale(voice_choice, "fr")
		_check(game.state.settings.text_locale == "en" and game.state.settings.voice_locale == "fr" and VoiceLibrary.get_locale() == "fr",
			"the real voice selector changes audio preference independently")
	else:
		game.state.settings.voice_locale = "fr"
		game._apply_settings()
		_check(game.state.settings.text_locale == "en" and game.state.settings.voice_locale == "fr",
			"an unavailable saved voice remains a request, separate from text and actual fallback")
	var loaded := CampaignState.new()
	loaded.path = TEST_PATH
	_check(loaded.read_save(["first"]) and loaded.settings.text_locale == "en" and loaded.settings.voice_locale == "fr",
		"independent text and voice choices survive disk serialization")
	_check(loaded.level_id == "first" and loaded.runs.first.diamonds == 3 and loaded.runs.first.health == 8,
		"language changes retain existing chapter progress")
	menu._confirm_new_game()
	var confirmation: ConfirmationDialog
	for child: Node in menu._root.get_children():
		if child is ConfirmationDialog:
			confirmation = child as ConfirmationDialog
	_check(confirmation != null, "the existing new-game confirmation is opened")
	_select_locale(text_choice, "ru")
	_check(confirmation.dialog_text == Localizer.text("dialog.new_game_body") and confirmation.cancel_button_text == Localizer.text("dialog.cancel"),
		"an already-open destructive-action dialog changes language without being recreated")
	confirmation.canceled.emit()
	await process_frame
	game._preview_display(menu._display_draft)
	await process_frame
	var display_dialog: ConfirmationDialog = game._display_dialog
	var remaining: float = game._display_confirmation_timer.time_left
	_select_locale(text_choice, "en")
	_check(display_dialog == game._display_dialog and display_dialog.title == Localizer.text("display.confirm_title"),
		"the live display-preview dialog translates in place")
	_check(game._display_confirmation_timer.time_left <= remaining + 0.01 and game._display_confirmation_timer.time_left > remaining - 0.2,
		"translation does not restart the safety countdown")
	_check(game.state.settings.graphics.window_width == 0, "a settings save during translation does not commit the display preview")
	display_dialog.canceled.emit()
	await process_frame
	var hud := RemasterHUD.new()
	root.add_child(hud)
	hud.set_chapter("Beach", 1, true, 6)
	hud.set_progress(3, 12, 0.1)
	for index: int in range(120):
		hud.set_progress(3, 12, 0.5)
		hud.set_vitals(8, 10, 4)
	_check(hud.counter.text == "◆  3 / 12" and hud.clock_label.text == "00:00" and hud.health_label.text == "♥ 8 / 10    × 4",
		"repeated unchanged simulation updates retain correct cached HUD values")
	hud.set_progress(4, 12, 61.0)
	hud.set_vitals(7, 10, 3)
	_check(hud.counter.text == "◆  4 / 12" and hud.clock_label.text == "01:01" and hud.health_label.text == "♥ 7 / 10    × 3",
		"changed counters, whole seconds and vitals still reach the HUD")
	hud.toast_key("toast.diamonds_remaining", {"count": 8}, 4.0)
	hud.toggle_pause()
	remaining = hud._toast_remaining
	old_focus = root.gui_get_focus_owner()
	_select_locale(text_choice, "ru")
	_check(paused and hud.modal_title.text == Localizer.text("pause.title") and root.gui_get_focus_owner() == old_focus,
		"pause state and modal focus survive a language switch")
	_check(hud.message_label.text == Localizer.text("toast.diamonds_remaining", {"count": 8}) and hud._toast_remaining == remaining,
		"an active parameterized toast translates without extending its lifetime")
	_check(hud.chapter_title == Localizer.chapter_title(6) and hud.footer_label.text == Localizer.text("controls.chapter"),
		"the current chapter title and input help update together")
	hud.toggle_pause()
	hud.finish(65.0)
	hud.set_finish_stats(9, 12, 2, 3)
	hud.set_finale(true)
	_select_locale(text_choice, "en")
	_check(hud._completed and hud.modal_title.text == Localizer.text("finish.chapter") and hud.next_button.text == Localizer.text("hud.finale"),
		"completion and finale captions stay correct after translation")
	_check(Localizer.text("finish.stats", {"diamonds": 9, "total": 12, "visited": 2, "checkpoints": 3}) in hud.modal_detail.text and "01:05" in hud.modal_detail.text,
		"translated completion text retains rewards/checkpoint statistics and elapsed time")
	hud.game_over()
	_select_locale(text_choice, "ru")
	_check(hud.modal_detail.text == Localizer.text("game_over.body") and hud._completed,
		"game-over details translate without resetting the run")
	hud.free()
	game.free()
	await process_frame
	paused = false
	var emitted: Array[int] = [0]
	var callback := func(_code: String) -> void: emitted[0] += 1
	Localizer.events().language_changed.connect(callback)
	Localizer.set_text_locale("en")
	var before: Dictionary = Localizer.cache_stats()
	for index: int in range(2000):
		Localizer.text("menu.settings")
		Localizer.text("finish.time", {"time": "01:05"})
		Localizer.set_text_locale("en")
	_check(emitted[0] == 1, "unchanged locale requests do not emit refresh signals")
	_check(Localizer.cache_stats() == before, "thousands of lookups/unchanged requests do no further JSON or filesystem reads")
	Localizer.events().language_changed.disconnect(callback)
	var legacy := CampaignState.new()
	legacy.path = TEST_PATH
	legacy.settings.erase("text_locale")
	legacy.settings.erase("voice_locale")
	_check(legacy.write_save() and loaded.read_save([]) and loaded.settings.text_locale == "ru" and loaded.settings.voice_locale == "ru",
		"existing v2 saves without locale fields retain the original Russian defaults")
	legacy.settings.text_locale = ["en"]
	legacy.settings.voice_locale = "../../fr"
	_check(legacy.write_save() and loaded.read_save([]) and loaded.settings.text_locale == "ru" and loaded.settings.voice_locale == "ru",
		"malformed locale values recover without becoming resource paths")
	_check(Localizer.sanitize_locale("de_DE") == "de" and Localizer.sanitize_locale("pt_PT") == "pt-PT" and Localizer.sanitize_locale("pt-BR") == "ru",
		"supported locale aliases normalize without inventing a separate Brazilian voice")
	_check(Localizer.sanitize_voice_locale("pt_BR") == "pt-BR" and Localizer.sanitize_voice_locale("tr") == "tr" and Localizer.sanitize_voice_locale("../en") == "ru",
		"future installed voice IDs remain selectable while malformed path-like values are refused")
	Localizer.set_text_locale("ru")
	VoiceLibrary.set_locale("ru")
	_cleanup()
	print("LOCALIZATION checks=", checks, " languages=", catalog.size(), " native_tables=", native_count, " keys=", english.size(), " failures=", JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)


func _tokens(value: String) -> Array[String]:
	var result: Array[String] = []
	for found: RegExMatch in _placeholder.search_all(value):
		var name: String = found.get_string(1)
		if name not in result:
			result.append(name)
	result.sort()
	return result


func _select_locale(control: OptionButton, code: String) -> void:
	for index: int in range(control.item_count):
		if control.get_item_metadata(index) == code:
			_select(control, index)
			return
	_check(false, "the real language selector contains " + code)


func _select(control: OptionButton, index: int) -> void:
	control.select(index)
	control.item_selected.emit(index)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".invalid"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
