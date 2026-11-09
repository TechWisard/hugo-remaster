"""Import explicitly mapped, local language resources without running game code."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import tempfile
from typing import Callable

from .binary import FormatError, Reader, require
from .catalog import Catalog
from .importer import publish_directory, read_source
from .mdic import parse_mdic, sha256, write_json
from .media import CONVERSION_PROFILE, MOVIES
from .native_text import decode_native_texts

MANIFEST_NAME = "localization_manifest.json"
STORY_MOVIES = tuple(key for key in MOVIES if key != "logo")
MOVIE_GROUPS = {"logo": 1, "intro_a": 2, "intro_b": 5, "plan_on_track": 26,
                "more_power_1": 45, "more_power_2": 54, "lost_juice": 68, "outro": 78}
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_MOVIE_BYTES = 256 * 1024 * 1024
MAX_CONVERTED_BYTES = 512 * 1024 * 1024
LOCALE_RE = re.compile(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\Z")
SHA_RE = re.compile(r"[a-f0-9]{64}\Z")


def file_sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _json(path: Path) -> dict:
    require(path.is_file() and path.stat().st_size <= MAX_JSON_BYTES, f"Missing or oversized JSON: {path}")
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(data, dict), f"Expected a JSON object: {path}")
    return data


def _locale(value: object) -> str:
    require(isinstance(value, str) and len(value) <= 64 and LOCALE_RE.fullmatch(value) is not None,
            "Locale must be a BCP47-style identifier such as en, ru or pt-PT")
    return value


def _label(value: object, field: str, default: str = "") -> str:
    if value is None:
        value = default
    require(isinstance(value, str) and 0 < len(value) <= 256 and not any(ord(c) < 32 for c in value),
            f"Invalid {field}")
    return value


def _safe_output_path(root: Path, relative: object) -> Path:
    require(isinstance(relative, str) and "\\" not in relative and ":" not in relative,
            "Language resource path must be a relative portable path")
    pure = PurePosixPath(relative)
    require(bool(pure.parts) and not pure.is_absolute() and ".." not in pure.parts,
            "Language resource path escapes its root")
    path = root.joinpath(*pure.parts)
    require(path.resolve().is_relative_to(root.resolve()) and not path.is_symlink(),
            "Language resource path escapes its root or is a symlink")
    return path


def _input_file(spec_dir: Path, descriptor: dict, output: Path, maximum: int) -> tuple[Path, str]:
    require(isinstance(descriptor, dict) and isinstance(descriptor.get("source"), str),
            "Each local resource requires a source filename")
    value = descriptor["source"]
    require("://" not in value and "\0" not in value, "Only local files are accepted; URLs are not downloaded")
    path = (spec_dir / value).resolve()
    require(path.is_file() and 0 < path.stat().st_size <= maximum, f"Missing or oversized local resource: {path}")
    require(not path.is_relative_to(output.resolve()), "Language inputs must be outside the replaced output directory")
    digest = file_sha256(path)
    expected = descriptor.get("source_sha256")
    if expected is not None:
        require(isinstance(expected, str) and SHA_RE.fullmatch(expected) is not None and digest == expected,
                f"Source SHA-256 mismatch: {path.name}")
    return path, digest


def _bink_header(path: Path) -> dict:
    with path.open("rb") as stream:
        header = stream.read(44)
    require(len(header) == 44 and header[:3] == b"BIK", f"Expected a Bink movie, not an executable: {path.name}")
    size_minus_8, frames = struct.unpack_from("<2I", header, 4)
    width, height, numerator, denominator = struct.unpack_from("<4I", header, 20)
    tracks = struct.unpack_from("<I", header, 40)[0]
    require(size_minus_8 + 8 == path.stat().st_size and 0 < frames <= 1_000_000,
            f"Invalid Bink size or frame count: {path.name}")
    require(0 < width <= 8192 and 0 < height <= 8192 and numerator > 0 and denominator > 0 and 0 <= tracks <= 256,
            f"Invalid Bink dimensions, timing or track count: {path.name}")
    return {"width": width, "height": height, "frame_count": frames,
            "frame_rate_numerator": numerator, "frame_rate_denominator": denominator,
            "source_audio_track_count": tracks}


def _check_native_movie(catalog: Catalog, key: str, language_index: int, filename: str) -> dict:
    require(type(language_index) is int and 0 <= language_index < 50, "Invalid native movie language index")
    record = catalog.record(MOVIE_GROUPS[key], 0, 8001)
    reader = Reader(record.data, record.label)
    field = 8 + 4 * language_index
    require(field + 4 <= record.header_size, "Native filename slot exceeds movie header")
    offset = reader.u32(field)
    require(record.header_size <= offset < len(record.data), "Native movie filename points outside string data")
    source_name = reader.cstring(offset)
    require(source_name.casefold() == filename.casefold(), f"Native movie filename mismatch for {key}: {filename}")
    return {"source_group": record.group, "source_record": record.index, "source_record_kind": 8001,
            "source_language_index": language_index, "source_filename_pointer_field": field,
            "native_movie_filename_checked": True}


def _convert_movie(source: Path, destination: Path, converter: str, audio_track: int | None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [converter, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
               "-map", "0:v:0"]
    if audio_track is None:
        command += ["-an"]
    else:
        command += ["-map", f"0:a:{audio_track}"]
    command += ["-c:v", "libtheora", "-q:v", "8", "-pix_fmt", "yuv420p",
                "-c:a", "libvorbis", "-q:a", "5", "-map_metadata", "-1", str(destination)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=600, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FormatError(f"Could not convert local movie {source.name}: {exc}") from exc
    require(result.returncode == 0, f"Movie conversion failed for {source.name}: {result.stderr[-1000:]}")
    require(destination.is_file() and 1024 < destination.stat().st_size <= MAX_CONVERTED_BYTES,
            f"Converted movie is empty or unexpectedly large: {source.name}")
    with destination.open("rb") as stream:
        require(stream.read(4) == b"OggS", f"Converted movie lacks an Ogg signature: {source.name}")


@contextmanager
def _lock(output: Path):
    path = output.parent / f".{output.name}-import.lock"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise FormatError(f"A language import is already running or left an interrupted lock: {path}") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            stream.write(f"pid={os.getpid()}\n")
        yield
    finally:
        path.unlink(missing_ok=True)


def _previous_manifest(output: Path) -> dict:
    if not output.exists() or not any(output.iterdir()):
        return {"schema_version": 1, "voices": {}, "native_texts": {}}
    report = _json(output / MANIFEST_NAME)
    require(report.get("schema_version") == 1 and isinstance(report.get("voices"), dict)
            and isinstance(report.get("native_texts", {}), dict), "Unsupported existing language manifest")
    return report


def _entries(report: dict):
    for voice in report.get("voices", {}).values():
        require(isinstance(voice, dict) and isinstance(voice.get("movies", {}), dict), "Invalid existing voice record")
        yield from voice.get("movies", {}).values()
        require(not voice.get("audio_overrides", {}), "WAV override import is not implemented in schema1")
    yield from report.get("native_texts", {}).values()


def import_languages(spec_path: Path, output: Path, *, ffmpeg: str = "ffmpeg", jobs: int = 2,
                     replace: bool = False, progress: Callable[[str], None] | None = None) -> dict:
    """Validate every source, convert whole localized cues, then publish atomically.

    Existing locales are retained by default. ``replace=True`` deliberately
    publishes only this specification. Failed conversion never exposes a half
    pack. The importer neither downloads files nor executes supplied game code.
    """
    say = progress or (lambda message: None)
    require(type(jobs) is int and 1 <= jobs <= 8, "Conversion jobs must be between 1 and 8")
    spec_path = spec_path.resolve()
    output = output.absolute()
    require(not output.is_symlink() and (not output.exists() or output.is_dir()), "Language output is not a plain directory")
    require(not spec_path.is_relative_to(output.resolve()), "Language specification must be outside the output directory")
    spec = _json(spec_path)
    require(spec.get("schema_version") == 1, "Language specification must use schema_version1")
    voices = spec.get("voices", {})
    native_specs = spec.get("native_texts", {})
    require(isinstance(voices, dict) and isinstance(native_specs, dict) and (voices or native_specs),
            "Language specification has no voice or native text resources")
    require(len(voices) <= 256 and len(native_specs) <= 256, "Too many language resources")
    locale_values = [_locale(locale) for locale in set(voices) | set(native_specs)]
    require(len({locale.casefold() for locale in locale_values}) == len(locale_values), "Ambiguous locale spelling")
    spec_dir = spec_path.parent
    catalogs: dict[str, Catalog] = {}
    decoded_texts: dict[str, dict] = {}

    def source_catalog(descriptor: dict) -> tuple[Catalog, str]:
        path, digest = _input_file(spec_dir, descriptor, output, 256 * 1024 * 1024)
        if digest not in catalogs:
            catalogs[digest] = Catalog(parse_mdic(read_source(path)))
        return catalogs[digest], digest

    prepared = {}
    unique_movies = {}
    for locale, voice in voices.items():
        require(isinstance(voice, dict) and isinstance(voice.get("movies", {}), dict), f"Invalid voice specification: {locale}")
        require(not voice.get("audio_overrides", {}), "Schema1 preserves shared WAVs; nonempty WAV overrides are unsupported")
        movie_specs = voice.get("movies", {})
        require(bool(movie_specs) and set(movie_specs).issubset(MOVIES), f"Unknown or empty movie cue mapping: {locale}")
        container = None
        container_hash = voice.get("source_container_sha256", "")
        require(isinstance(container_hash, str) and (not container_hash or SHA_RE.fullmatch(container_hash) is not None),
                f"Invalid source container hash: {locale}")
        if "source_container" in voice:
            container, container_hash = source_catalog(voice["source_container"])
        native_name = _label(voice.get("native_name"), "native_name", locale)
        edition = _label(voice.get("source_edition"), "source_edition", "locally_supplied")
        prepared[locale] = {"native_name": native_name, "source_edition": edition,
                            "source_sha256": container_hash, "movies": {}, "audio_overrides": {},
                            "verification": {"source_hashes_checked": True, "language_assignment": "explicit_local_specification",
                                             "evidence": voice.get("evidence", []), "original_executable_run": False}}
        for key, descriptor in movie_specs.items():
            path, digest = _input_file(spec_dir, descriptor, output, MAX_MOVIE_BYTES)
            header = _bink_header(path)
            track = descriptor.get("audio_track", 0 if header["source_audio_track_count"] else None)
            require(track is None or (type(track) is int and 0 <= track < header["source_audio_track_count"]),
                    f"Requested Bink audio track does not exist: {locale}/{key}")
            if key in STORY_MOVIES:
                require(track is not None, f"A voice cue must contain its original recorded audio: {locale}/{key}")
            filename = _label(descriptor.get("source_filename"), "source_filename", path.name)
            identity = (digest, track)
            relative = f"movies/{digest}_a{track if track is not None else 'none'}.ogv"
            info = {"path": relative, "source_filename": filename, "source_sha256": digest,
                    "source_size_bytes": path.stat().st_size, "source_audio_track": track,
                    "native_movie_filename_checked": False, **header}
            if container is not None:
                require("language_index" in voice, f"Source container requires an explicit language_index: {locale}")
                info.update(_check_native_movie(container, key, voice["language_index"], filename))
            prepared[locale]["movies"][key] = info
            unique_movies.setdefault(identity, {"source": path, "info": info})

    native = {}
    for locale, descriptor in native_specs.items():
        require(isinstance(descriptor, dict), "Invalid native text specification")
        input_format = descriptor.get("format", "native_container")
        require(input_format in ("native_container", "native_text_json"), "Unknown native text input format")
        if input_format == "native_text_json":
            path, digest = _input_file(spec_dir, descriptor, output, MAX_JSON_BYTES)
            info = _json(path)
            require(info.get("schema_version") == 1 and info.get("locale") == locale
                    and info.get("string_count") == 205 and isinstance(info.get("strings"), list)
                    and len(info["strings"]) == 205
                    and all(isinstance(value, str) and len(value) <= 16384 and "\0" not in value for value in info["strings"]),
                    f"Invalid previously decoded 205-entry text resource: {locale}")
            require(isinstance(info.get("source_sha256"), str) and SHA_RE.fullmatch(info["source_sha256"]) is not None
                    and type(info.get("source_record_index")) is int and 0 <= info["source_record_index"] < 65536
                    and isinstance(info.get("encoding"), str) and bool(info["encoding"])
                    and isinstance(info.get("unresolved_glyph_bytes"), list),
                    f"Missing native text provenance: {locale}")
            info = dict(info)
            info["import_input_format"] = "previously_decoded_native_text_json"
            info["import_input_sha256"] = digest
        else:
            catalog, digest = source_catalog(descriptor)
            if digest not in decoded_texts:
                decoded_texts[digest] = decode_native_texts(catalog)
            require(locale in decoded_texts[digest], f"Source container has no proven native table for {locale}")
            info = decoded_texts[digest][locale]
        require(not info["unresolved_glyph_bytes"], f"Native text {locale} has unresolved glyphs; no substitution is invented")
        if "record_index" in descriptor:
            require(descriptor["record_index"] == info["source_record_index"], f"Native text record mismatch: {locale}")
        native[locale] = info

    output.parent.mkdir(parents=True, exist_ok=True)
    with _lock(output):
        previous = _previous_manifest(output)
        report = {"schema_version": 1, "default_voice_locale": spec.get("default_voice_locale", previous.get("default_voice_locale", "ru")),
                  "conversion_profile": CONVERSION_PROFILE,
                  "voices": {} if replace else copy.deepcopy(previous.get("voices", {})),
                  "native_texts": {} if replace else copy.deepcopy(previous.get("native_texts", {})),
                  "input_spec_sha256": file_sha256(spec_path), "original_executable_run": False,
                  "shared_game_audio": "Native WAV source IDs remain in generated gameplay; this import writes no WAV copies.",
                  "movie_conversion": "Complete Ogg Theora/Vorbis cue, preserving original video variant, dimensions and frame rate."}
        stage = Path(tempfile.mkdtemp(prefix=f".{output.name}-staging-", dir=output.parent))
        try:
            cache = {}
            validated_paths = {}
            for entry in _entries(previous):
                require(isinstance(entry, dict) and isinstance(entry.get("sha256"), str), "Invalid existing language asset")
                relative = entry.get("path")
                path = _safe_output_path(output, relative)
                if relative not in validated_paths:
                    require(path.is_file() and path.stat().st_size <= MAX_CONVERTED_BYTES
                            and file_sha256(path) == entry["sha256"], f"Existing language asset failed its hash: {relative}")
                    validated_paths[relative] = path
                if entry.get("source_sha256") and path.suffix == ".ogv" and previous.get("conversion_profile") == CONVERSION_PROFILE:
                    with path.open("rb") as stream:
                        require(stream.read(4) == b"OggS", "Cached movie is not Ogg data")
                    cache[(entry["source_sha256"], entry.get("source_audio_track", 0))] = entry
                if not replace:
                    destination = _safe_output_path(stage, relative)
                    if not destination.exists():
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(path, destination)

            pending = []
            results = {}
            for identity, item in unique_movies.items():
                info = item["info"]
                destination = _safe_output_path(stage, info["path"])
                cached = cache.get(identity)
                if cached:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if not destination.exists():
                        shutil.copy2(_safe_output_path(output, cached["path"]), destination)
                    results[identity] = {"sha256": cached["sha256"], "size_bytes": destination.stat().st_size}
                else:
                    pending.append((identity, item, destination))
            converter = shutil.which(ffmpeg) if pending else None
            require(not pending or converter is not None, "ffmpeg is required to convert local Bink voice movies")
            say(f"Language import: {len(prepared)} voice locales, {len(native)} native text tables, "
                f"{len(unique_movies)} distinct source movie/track pairs; {len(pending)} conversions needed.")
            with ThreadPoolExecutor(max_workers=jobs) as workers:
                futures = {workers.submit(_convert_movie, item["source"], destination, str(converter), identity[1]):
                           (identity, item, destination) for identity, item, destination in pending}
                for completed, future in enumerate(as_completed(futures), 1):
                    identity, item, destination = futures[future]
                    future.result()
                    results[identity] = {"sha256": file_sha256(destination), "size_bytes": destination.stat().st_size}
                    say(f"Converted {completed}/{len(pending)}: {item['source'].name}")

            for locale, voice in prepared.items():
                merged = dict(report["voices"].get(locale, {}).get("movies", {}))
                for key, info in voice["movies"].items():
                    info.update(results[(info["source_sha256"], info["source_audio_track"])])
                    merged[key] = info
                voice["movies"] = merged
                voice["coverage"] = {"required": list(STORY_MOVIES), "present": [key for key in STORY_MOVIES if key in merged],
                                     "missing": [key for key in STORY_MOVIES if key not in merged],
                                     "complete": all(key in merged for key in STORY_MOVIES)}
                report["voices"][locale] = voice
            for locale, resource in native.items():
                relative = f"texts/{locale}.json"
                destination = _safe_output_path(stage, relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                write_json(destination, resource)
                report["native_texts"][locale] = {"path": relative, "sha256": file_sha256(destination),
                    "size_bytes": destination.stat().st_size, "source_sha256": resource["source_sha256"],
                    "record_index": resource["source_record_index"], "encoding": resource["encoding"], "string_count": 205}
                if "import_input_format" in resource:
                    report["native_texts"][locale]["input_format"] = resource["import_input_format"]
                    report["native_texts"][locale]["input_sha256"] = resource["import_input_sha256"]
            default = _locale(report["default_voice_locale"])
            require(not report["voices"] or default in report["voices"], "Default voice locale is not available in the complete output")
            referenced = {entry["path"] for entry in _entries(report)}
            for path in stage.rglob("*"):
                if path.is_file() and path.relative_to(stage).as_posix() not in referenced:
                    path.unlink()
            report["totals"] = {"voice_locales": len(report["voices"]), "native_text_locales": len(report["native_texts"]),
                                "movie_cues": sum(len(v["movies"]) for v in report["voices"].values()),
                                "distinct_files": len(referenced), "payload_bytes": sum((_safe_output_path(stage, p)).stat().st_size for p in referenced),
                                "converted_movies_this_import": len(pending), "reused_movies_this_import": len(unique_movies) - len(pending)}
            write_json(stage / MANIFEST_NAME, report)
            publish_directory(stage, output)
            return report
        finally:
            if stage.exists():
                shutil.rmtree(stage, ignore_errors=True)
