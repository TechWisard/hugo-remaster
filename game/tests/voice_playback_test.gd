extends SceneTree
## Exercise installed original-language cues through the production cinematic.
## Dummy audio still mixes decoded samples; this is not a hardware audio test.

const Voice = preload("res://scripts/native_voice_library.gd")
const Cinema = preload("res://scripts/cinematic.gd")
const Localizer = preload("res://scripts/native_localization.gd")
const CUES: Array[String] = ["logo", "intro_a", "intro_b", "plan_on_track", "more_power_1", "more_power_2", "lost_juice", "outro"]
var checks: int = 0
var failures: Array[String] = []
var entries: Array[Dictionary] = []
var report_path: String
var capture_dir: String
var expected_voices: int = 0
var capture: AudioEffectCapture


func _initialize() -> void:
	_run.call_deferred()


func _expect(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--voice-report="):
			report_path = argument.trim_prefix("--voice-report=")
		if argument.begins_with("--voice-captures="):
			capture_dir = argument.trim_prefix("--voice-captures=")
		if argument.begins_with("--expected-voices="):
			expected_voices = int(argument.trim_prefix("--expected-voices="))
	var locales: Array[String] = Voice.available_locales()
	if locales.is_empty() and expected_voices == 0:
		print("VOICE_PLAYBACK SKIP optional original language pack unavailable")
		quit(0)
		return
	if expected_voices > 0:
		_expect(locales.size() == expected_voices, "The expected original voice count is installed")
	_expect(int(Voice.cache_stats().hash_reads) == 0, "Listing voice choices does not open every movie")
	var manifest: Dictionary = Voice.get_manifest()
	for locale: String in locales:
		Voice.set_locale(locale)
		for key: String in CUES:
			var resolved: Dictionary = Voice.resolve_movie(key, {})
			var source: Dictionary = manifest.voices[locale].movies.get(key, {})
			_expect(bool(resolved.get("available", false)) and resolved.get("effective_locale") == locale and not bool(resolved.get("is_fallback", true)),
				"%s/%s resolves its actual installed voice" % [locale, key])
			_expect(resolved.get("source_sha256") == source.get("source_sha256") and resolved.get("frame_count") == source.get("frame_count")
				and resolved.get("frame_rate_numerator") == source.get("frame_rate_numerator") and resolved.get("frame_rate_denominator") == source.get("frame_rate_denominator"),
				"%s/%s preserves the complete source cue and its timing" % [locale, key])
	RemasterInput.configure()
	Localizer.set_text_locale("en")
	var bus_index: int = AudioServer.get_bus_index("Effects")
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, "Effects")
	AudioServer.set_bus_mute(bus_index, false)
	AudioServer.set_bus_volume_db(bus_index, 0.0)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus_index, capture)
	if not capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(capture_dir)
	for locale: String in locales:
		await _play(locale)
	await create_timer(0.12).timeout
	AudioServer.remove_bus_effect(bus_index, AudioServer.get_bus_effect_count(bus_index) - 1)
	var report: Dictionary = {"checks": checks, "passed": checks - failures.size(), "failures": failures,
		"locales": locales, "entries": entries, "cache": Voice.cache_stats(),
		"renderer": RenderingServer.get_current_rendering_method(), "display": DisplayServer.get_name(),
		"audio_driver": AudioServer.get_driver_name(), "software_test": true,
		"scope": "Each installed cue resolves as a complete A/V file; one real cue per locale is decoded, mixed and skipped through production input."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
	print("VOICE_PLAYBACK ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func _play(locale: String) -> void:
	Voice.set_locale(locale)
	var resolved: Dictionary = Voice.resolve_movie("outro", {})
	if not bool(resolved.get("available", false)):
		return
	var movie: CampaignCinematic = Cinema.new()
	movie.movie_key = "outro"
	movie.voice_info = resolved
	movie.stream_path = str(resolved.path)
	movie.aspect_ratio = float(resolved.width) / float(resolved.height)
	var closes: Array[int] = [0]
	movie.finished.connect(func() -> void: closes[0] += 1)
	capture.clear_buffer()
	root.add_child(movie)
	var started: int = Time.get_ticks_msec()
	var peak: float = 0.0
	var sample_count: int = 0
	var sum_squares: float = 0.0
	while is_instance_valid(movie) and Time.get_ticks_msec() - started < 6000:
		await process_frame
		var frames: int = capture.get_frames_available()
		if frames > 0:
			var samples: PackedVector2Array = capture.get_buffer(frames)
			for sample: Vector2 in samples:
				peak = maxf(peak, maxf(absf(sample.x), absf(sample.y)))
				sum_squares += sample.length_squared()
			sample_count += samples.size() * 2
		if movie._video.stream_position >= 1.2 and peak > 0.001:
			break
	_expect(is_instance_valid(movie) and movie._video.is_playing(), "%s movie starts through production Cinematic" % locale)
	if not is_instance_valid(movie):
		return
	var position: float = movie._video.stream_position
	var texture: Texture2D = movie._video.get_video_texture()
	var dimensions := Vector2i(texture.get_width(), texture.get_height()) if texture != null else Vector2i.ZERO
	_expect(position >= 1.0, "%s video timeline actually advances" % locale)
	_expect(sample_count > 1000 and peak > 0.001, "%s decoded audio reaches its actual mixing bus" % locale)
	if DisplayServer.get_name() != "headless":
		_expect(dimensions == Vector2i(int(resolved.width), int(resolved.height)), "%s decoded frame keeps its source dimensions" % locale)
	_expect(Localizer.language_name(locale) in movie._voice_label.text and movie._hint.text == Localizer.text("cinematic.skip"),
		"%s current voice is explicit while UI text stays independently English" % locale)
	var screen_path: String = ""
	if not capture_dir.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		screen_path = capture_dir.path_join("voice_%s.png" % locale)
		root.get_texture().get_image().save_png(screen_path)
	var row: Dictionary = {"locale": locale, "effective_locale": resolved.effective_locale, "movie_key": "outro",
		"path": resolved.path, "source_sha256": resolved.source_sha256, "sha256": resolved.sha256,
		"position_seconds": position, "texture_width": dimensions.x, "texture_height": dimensions.y,
		"mixed_samples": sample_count, "audio_peak": peak, "audio_rms": sqrt(sum_squares / maxf(sample_count, 1)),
		"text_locale": Localizer.get_text_locale(), "voice_label": movie._voice_label.text, "screenshot": screen_path}
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_SPACE
	event.physical_keycode = KEY_SPACE
	Input.parse_input_event(event)
	await process_frame
	var release := InputEventKey.new()
	release.keycode = KEY_SPACE
	release.physical_keycode = KEY_SPACE
	Input.parse_input_event(release)
	await process_frame
	await process_frame
	_expect(closes[0] == 1 and not is_instance_valid(movie), "%s source cue closes once through real skip input" % locale)
	row.finished_count = closes[0]
	row.closed = not is_instance_valid(movie)
	entries.append(row)
	print("VOICE_CUE ", JSON.stringify(row))
