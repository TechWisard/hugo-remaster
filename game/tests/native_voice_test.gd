extends SceneTree
## Isolated resolver and audio playback tests. Fixtures are authored resources;
## imported movies are exercised separately by voice_playback_test.gd.

const Voice = preload("res://scripts/native_voice_library.gd")
const Sound = preload("res://scripts/native_audio.gd")
const Cinema = preload("res://scripts/cinematic.gd")
const Localizer = preload("res://scripts/native_localization.gd")
const FIXTURE: String = "user://native_voice_test"
var checks: int = 0
var failures: Array[String] = []
var manifest: Dictionary
var wave_a: String
var wave_alias: String
var wave_b: String
var clip_a: Dictionary
var clip_b: Dictionary


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_prepare()
	_resolver()
	await _audio_playback()
	await _cinematic_text()
	# Let the audio thread release stopped playback references before shutdown.
	await create_timer(0.12).timeout
	Voice.configure_manifest()
	Voice.set_locale("ru")
	Localizer.set_text_locale("ru")
	Sound.configure_catalog({})
	print("NATIVE_VOICE ", JSON.stringify({"checks": checks, "passed": checks - failures.size(), "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _expect(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _prepare() -> void:
	DirAccess.make_dir_recursive_absolute(FIXTURE)
	var first := VideoStreamTheora.new()
	first.resource_name = "Resolver fixture A"
	ResourceSaver.save(first, FIXTURE.path_join("a.tres"))
	var second := VideoStreamTheora.new()
	second.resource_name = "Resolver fixture B"
	ResourceSaver.save(second, FIXTURE.path_join("b.tres"))
	clip_a = {"path": "a.tres", "sha256": FileAccess.get_sha256(FIXTURE.path_join("a.tres")),
		"source_sha256": "a".repeat(64), "width": 320, "height": 160, "frame_count": 111,
		"frame_rate_numerator": 25, "frame_rate_denominator": 1}
	clip_b = {"path": "b.tres", "sha256": FileAccess.get_sha256(FIXTURE.path_join("b.tres")),
		"source_sha256": "b".repeat(64), "width": 640, "height": 320, "frame_count": 222,
		"frame_rate_numerator": 30, "frame_rate_denominator": 1}
	wave_a = FIXTURE.path_join("wave_a.tres")
	wave_alias = FIXTURE.path_join("wave_alias.tres")
	wave_b = FIXTURE.path_join("wave_b.tres")
	_make_wave(wave_a, 220.0)
	DirAccess.copy_absolute(wave_a, wave_alias)
	_make_wave(wave_b, 440.0)
	manifest = {"schema_version": 1, "default_voice_locale": "ru",
		"voices": {"ru": {"movies": {"intro_a": clip_a}, "audio_overrides": {}},
			"en": {"movies": {"intro_a": clip_b}, "audio_overrides": {}},
			"pt-PT": {"movies": {"intro_a": clip_b}, "audio_overrides": {}}},
		"native_texts": {"pt-PT": {"path": "text/pt-PT.json"}}}
	_write_manifest()


func _make_wave(path: String, frequency: float) -> void:
	var wave := AudioStreamWAV.new()
	wave.format = AudioStreamWAV.FORMAT_16_BITS
	wave.mix_rate = 11025
	var samples := PackedByteArray()
	samples.resize(22050 * 2)
	for index: int in range(22050):
		samples.encode_s16(index * 2, int(sin(float(index) * TAU * frequency / 11025.0) * 12000.0))
	wave.data = samples
	ResourceSaver.save(wave, path)


func _write_manifest() -> void:
	var path: String = FIXTURE.path_join("localization_manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest))
	file.close()
	Voice.configure_manifest(path)


func _resolver() -> void:
	Voice.set_locale(" PT_pt ")
	_expect(Voice.get_locale() == "pt-PT", "Portuguese BCP47 region retains its canonical spelling")
	_expect(Voice.available_locales() == ["en", "pt-PT", "ru"], "Only installed catalog locales are offered")
	_expect(int(Voice.cache_stats().manifest_reads) == 1 and int(Voice.cache_stats().hash_reads) == 0,
		"Listing languages reads metadata once and no movie bytes")
	var metadata: Dictionary = Voice.native_text_metadata("pt-pt")
	_expect(str(metadata.get("path", "")) == "text/pt-PT.json", "Text metadata resolves locale casing and stays relative")
	metadata.path = "modified"
	_expect(str(Voice.native_text_metadata("pt-PT").path) == "text/pt-PT.json", "Returned native text metadata cannot mutate the catalog")
	var fallback: Dictionary = clip_a.duplicate(true)
	fallback.path = FIXTURE.path_join("a.tres")
	var selected: Dictionary = Voice.resolve_movie("intro_a", fallback)
	_expect(bool(selected.available) and selected.effective_locale == "pt-PT" and not bool(selected.is_fallback),
		"Portuguese resolves its installed cue without falling back to Russian")
	_expect(selected.path == FIXTURE.path_join("b.tres") and int(selected.frame_count) == 222 and int(selected.width) == 640,
		"The complete selected cue keeps its own video, geometry and timing")
	var first_reads: int = int(Voice.cache_stats().hash_reads)
	Voice.resolve_movie("intro_a", fallback)
	_expect(first_reads == 1 and int(Voice.cache_stats().hash_reads) == first_reads, "Repeated cue resolution reuses its integrity check")
	Voice.set_locale("pt-BR")
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(Voice.get_locale() == "pt-BR" and selected.effective_locale == "ru" and bool(selected.is_fallback),
		"An unverified Brazilian dub is not relabelled as European Portuguese")
	_expect(selected.requested_locale == "pt-BR" and selected.path == FIXTURE.path_join("a.tres") and int(selected.frame_count) == 111,
		"Fallback reports the requested and actual language and replaces the whole cue")
	Voice.set_locale("en")
	manifest.voices.en.movies.intro_a = clip_b.duplicate(true)
	manifest.voices.en.movies.intro_a.sha256 = "0".repeat(64)
	_write_manifest()
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(bool(selected.available) and selected.effective_locale == "ru" and selected.fallback_reason == "asset_hash_mismatch",
		"A corrupt selected cue falls back atomically to a verified default cue")
	manifest.voices.en.movies.intro_a.path = "../a.tres"
	_write_manifest()
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(selected.effective_locale == "ru" and selected.fallback_reason == "invalid_asset_path", "A pack cannot resolve a parent path")
	manifest.voices.en.movies.intro_a.path = "res://scripts/campaign.gd"
	_write_manifest()
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(selected.effective_locale == "ru" and selected.fallback_reason == "invalid_asset_path", "Pack paths cannot target absolute project resources")
	manifest.voices.en.movies.intro_a = {"path": "missing.tres"}
	manifest.voices.ru.movies.intro_a = {"path": "missing_default.tres"}
	_write_manifest()
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(bool(selected.available) and selected.path == fallback.path and selected.effective_locale == "", "The base import remains usable with explicit unknown original language")
	selected = Voice.resolve_movie("unknown", {})
	_expect(not bool(selected.available) and selected.fallback_reason == "no_available_cue", "Missing optional data returns a safe unavailable result")
	manifest.voices.ru.movies.intro_a = clip_a
	manifest.voices.en.movies.intro_a = clip_b
	_write_manifest()
	Voice.set_locale("en")
	var source: Dictionary = {"group": 1, "resource_id": 2, "path": wave_a, "flags": 12, "volume": 0.3, "native_loop": true}
	var audio: Dictionary = Voice.resolve_audio(source)
	_expect(bool(audio.available) and audio.path == wave_a and audio.effective_locale == "" and not bool(audio.is_fallback),
		"Shared gameplay WAVs keep their original alias without claiming a selected spoken language")
	manifest.voices.en.audio_overrides.g001_r0002 = {"path": "wave_b.tres", "sha256": FileAccess.get_sha256(wave_b), "volume": 99, "flags": 0}
	_write_manifest()
	audio = Voice.resolve_audio(source)
	_expect(audio.path == wave_b and audio.effective_locale == "en" and audio.asset_source == "voice_pack", "A sample override resolves by source group and resource ID")
	_expect(audio.flags == 12 and is_equal_approx(float(audio.volume), 0.3) and bool(audio.native_loop), "A voice sample override cannot replace native sound rules")
	manifest.voices.en.audio_overrides.clear()
	_write_manifest()
	Voice.configure_manifest(FIXTURE.path_join("absent.json"))
	_expect(Voice.available_locales().is_empty(), "A missing optional pack does not invent available voices")
	selected = Voice.resolve_movie("intro_a", fallback)
	_expect(bool(selected.available) and selected.path == fallback.path, "A missing voice pack does not break the base movie")
	_write_manifest()


func _audio_playback() -> void:
	var catalog: Dictionary = {"g001_r0000": {"group": 1, "resource_id": 0, "path": wave_a, "sha256": FileAccess.get_sha256(wave_a)},
		"g001_r0001": {"group": 1, "resource_id": 1, "path": wave_alias, "sha256": FileAccess.get_sha256(wave_alias)},
		"g001_r0002": {"group": 1, "resource_id": 2, "path": wave_b, "sha256": FileAccess.get_sha256(wave_b)}}
	Sound.configure_catalog(catalog)
	_expect(int(Sound.cache_stats().resident_streams) == 0 and int(Sound.cache_stats().source_ids) == 3,
		"Configuring the sample catalog preserves aliases and eagerly loads no streams")
	var a: AudioStream = Sound.cached_stream(catalog.g001_r0000)
	var alias: AudioStream = Sound.cached_stream(catalog.g001_r0001)
	var b: AudioStream = Sound.cached_stream(catalog.g001_r0002)
	_expect(a != null and a == alias and a != b, "Only byte-identical source hashes share one immutable stream")
	_expect(int(Sound.cache_stats().resident_streams) == 2 and int(Sound.cache_stats().loads) == 2 and int(Sound.cache_stats().hits) == 1,
		"The cache loads two payloads for three native aliases")
	var stage := Node3D.new()
	root.add_child(stage)
	var ear := Node3D.new()
	stage.add_child(ear)
	var looping: NativeSound = Sound.new()
	var single: NativeSound = Sound.new()
	looping.listener = ear
	single.listener = ear
	stage.add_child(looping)
	stage.add_child(single)
	var loop_info: Dictionary = catalog.g001_r0000.duplicate()
	loop_info.merge({"native_loop": true, "volume": 0.75, "flags": 0, "exclusive_group": 7, "suppress_same_group": false}, true)
	var once_info: Dictionary = catalog.g001_r0001.duplicate()
	once_info.merge({"native_loop": false, "volume": 0.5, "flags": 0, "exclusive_group": 7, "suppress_same_group": false}, true)
	_expect(looping.play_source(loop_info, 1.25) and single.play_source(once_info, 0.8), "Aliased loop and one-shot both start through real AudioStreamPlayer3D")
	await process_frame
	_expect(looping.playing and single.playing, "Both independent players remain active")
	_expect(looping.stream != single.stream and looping.stream != a, "Playback has independent resource wrappers")
	_expect((looping.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_FORWARD and (single.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED,
		"Native loop flags stay independent on aliased samples")
	_expect((a as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED, "A looping player never mutates the cached sample")
	_expect(is_equal_approx(looping.pitch_scale, 1.25) and is_equal_approx(single.pitch_scale, 0.8), "Playback pitch remains per player")
	_expect(is_equal_approx(looping.volume_db, Sound.native_volume_db(0.75)) and is_equal_approx(single.volume_db, Sound.native_volume_db(0.5)),
		"Native gain remains per player")
	looping.stop_source()
	_expect(not looping.playing and single.playing, "Stopping one alias does not stop another")
	single.stop_source()
	loop_info.suppress_same_group = true
	once_info.suppress_same_group = true
	_expect(looping.play_source(loop_info) and not single.play_source(once_info), "Native exclusive-group suppression survives stream sharing")
	looping.stop_source()
	_expect(single.play_source(once_info), "Unregistering a completed group permits its next cue")
	single.stop_source()
	looping.stream = null
	single.stream = null
	stage.queue_free()
	await process_frame
	await process_frame
	_expect(Sound._active_groups.is_empty(), "Freed players leave no stale exclusive-group entries")
	Sound.clear_stream_cache()
	_expect(int(Sound.cache_stats().resident_streams) == 0 and int(Sound.cache_stats().source_ids) == 3, "Cache eviction does not erase source aliases")


func _cinematic_text() -> void:
	Localizer.set_text_locale("en")
	var movie: CampaignCinematic = Cinema.new()
	movie.stream_path = ""
	movie.movie_key = "intro_a"
	movie.voice_info = {"requested_locale": "pt-PT", "effective_locale": "ru", "is_fallback": true}
	var closes: Array[int] = [0]
	movie.finished.connect(func() -> void: closes[0] += 1)
	root.add_child(movie)
	_expect(movie._hint.text == Localizer.text("cinematic.skip"), "Cinematic skip hint uses the selected text locale")
	_expect("Русский" in movie._voice_label.text and "Português" in movie._voice_label.text, "Cinematic fallback label identifies actual and requested voices")
	var before: Dictionary = movie.voice_info.duplicate(true)
	Localizer.set_text_locale("ru")
	_expect(movie._hint.text == Localizer.text("cinematic.skip") and movie.voice_info == before, "Changing UI text updates the hint without switching the active audiovisual cue")
	movie._finish()
	movie._finish()
	await process_frame
	await process_frame
	_expect(closes[0] == 1 and not is_instance_valid(movie), "Missing media and repeated close requests emit finished exactly once")
