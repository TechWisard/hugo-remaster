"""Optional local movie/music conversion. No game executables are loaded."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import struct
from typing import Callable

from .binary import FormatError, require
from .mdic import sha256, write_json

# These names occur in the disc's file directory and in the scene sequence.
MOVIES = {
    "logo": "ITEMEDIA.BIK",
    "intro_a": "CUTSC01A.BIK", "intro_b": "CUTSC01B.BIK",
    "plan_on_track": "CUTSC02_.BIK", "more_power_1": "CUTSC03_.BIK",
    "more_power_2": "CUTSC04_.BIK", "lost_juice": "CUTSC05_.BIK",
    "outro": "CUTSC06_.BIK",
}
CONVERSION_PROFILE = "theora-q8-vorbis-q5-native-size-rate-v1"


def _local_files(directory: Path) -> dict[str, Path]:
    require(directory.is_dir(), f"Media directory does not exist: {directory}")
    files: dict[str, Path] = {}
    for path in directory.iterdir():
        if path.is_file():
            key = path.name.casefold()
            require(key not in files, f"Ambiguous case-insensitive media filename: {path.name}")
            files[key] = path
    return files


def convert_media(source_dir: Path, output: Path, music_dir: Path | None = None,
                  ffmpeg: str = "ffmpeg", progress: Callable[[str], None] | None = None,
                  *, cache_dir: Path | None = None) -> dict:
    """Write media inside an unpublished output directory; caller owns promotion.

    Missing optional files are listed, not replaced with unrelated content.
    The source directory is read-only. ffmpeg is an explicitly selected local
    tool; executable files from the source directory are never invoked.
    """
    say = progress or (lambda message: None)
    sources = _local_files(source_dir)
    available = [(key, sources[name.casefold()]) for key, name in MOVIES.items()
                 if name.casefold() in sources]
    converter = shutil.which(ffmpeg) if available else None
    require(not available or converter is not None,
            "Local BIK movies found, but ffmpeg is unavailable. Install ffmpeg or omit --media-dir.")
    target = output / "media"
    target.mkdir(parents=True, exist_ok=True)
    cache: dict = {}
    if cache_dir is not None:
        try:
            cache = json.loads((cache_dir / "media_manifest.json").read_text(encoding="utf-8"))
            if not isinstance(cache, dict) or cache.get("conversion_profile") != CONVERSION_PROFILE:
                cache = {}
        except (OSError, ValueError):
            cache = {}
    report: dict = {"schema_version": 1, "movies": {}, "music": {}, "missing_movies": [],
                    "conversion_profile": CONVERSION_PROFILE,
                    "music_scene_mapping": "Only a recovered source track assignment may select music.",
                    "movie_conversion": "Ogg Theora / Vorbis; original frame size and frame rate retained"}
    for key, name in MOVIES.items():
        if name.casefold() not in sources:
            report["missing_movies"].append(name)
    for key, source in available:
        require(source.stat().st_size <= 256 * 1024 * 1024, f"Movie is unexpectedly large: {source.name}")
        with source.open("rb") as handle:
            header = handle.read(36)
            require(header[:3] == b"BIK", f"Movie is not a Bink container: {source.name}")
        require(len(header) == 36, f"Truncated Bink header: {source.name}")
        width, height, fps_num, fps_den = struct.unpack_from("<4I", header, 20)
        require(0 < width <= 8192 and 0 < height <= 8192 and fps_num > 0 and fps_den > 0,
                f"Invalid source movie dimensions or frame rate: {source.name}")
        destination = target / f"{key}.ogv"
        source_hash = sha256(source.read_bytes())
        cached: dict = cache.get("movies", {}).get(key, {})
        if cache_dir is not None and isinstance(cached, dict) and cached.get("source_sha256") == source_hash:
            cached_path = cache_dir / "media" / destination.name
            if cached_path.is_file() and cached_path.stat().st_size <= 512 * 1024 * 1024:
                cached_data = cached_path.read_bytes()
                if cached_data.startswith(b"OggS") and sha256(cached_data) == cached.get("sha256"):
                    destination.write_bytes(cached_data)
                    report["movies"][key] = dict(cached)
                    say(f"Reusing verified conversion of {source.name}.")
                    continue
        say(f"Converting local movie {source.name}...")
        command = [str(converter), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(source.resolve()), "-map", "0:v:0", "-map", "0:a:0?",
                   "-c:v", "libtheora", "-q:v", "8", "-pix_fmt", "yuv420p",
                   "-c:a", "libvorbis", "-q:a", "5", "-map_metadata", "-1", str(destination)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=600, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise FormatError(f"Could not convert {source.name}: {exc}") from exc
        require(result.returncode == 0, f"Movie conversion failed for {source.name}: {result.stderr[-1000:]}")
        require(destination.is_file() and destination.stat().st_size > 1024,
                f"Movie conversion produced no playable data: {source.name}")
        with destination.open("rb") as handle:
            require(handle.read(4) == b"OggS", f"Converted movie lacks an Ogg signature: {source.name}")
        report["movies"][key] = {
            "path": f"media/{destination.name}", "source_filename": source.name,
            "source_sha256": source_hash,
            "sha256": sha256(destination.read_bytes()), "size_bytes": destination.stat().st_size,
            "width": width, "height": height, "frame_rate_numerator": fps_num,
            "frame_rate_denominator": fps_den,
        }
    if music_dir is not None:
        tracks = _local_files(music_dir)
        for number in range(2, 10):
            name = f"Track{number:02d}.ogg"
            source = tracks.get(name.casefold())
            if source is None:
                continue
            data = source.read_bytes()
            require(len(data) < 64 * 1024 * 1024 and data.startswith(b"OggS") and b"vorbis" in data[:256],
                    f"Expected a local Ogg Vorbis music track: {source.name}")
            destination = target / name
            destination.write_bytes(data)
            report["music"][str(number)] = {"path": f"media/{name}", "sha256": sha256(data),
                                           "size_bytes": len(data), "source_filename": source.name}
    credits = sources.get("credits.txt")
    if credits:
        raw = credits.read_bytes()
        require(len(raw) <= 1024 * 1024, "Credits text exceeds the size limit")
        try:
            content = raw.decode("utf-8-sig")
            encoding = "utf-8-sig"
        except UnicodeDecodeError:
            # CREDITS.TXT keeps the Danish team's Western-European names even
            # on the examined Russian disc (É, Ø, Å); it is not CP1251.
            content = raw.decode("cp1252")
            encoding = "cp1252"
        lines = []
        for line in content.splitlines():
            line = line.strip()
            if len(line) >= 2 and line.startswith('"') and line.endswith('"'):
                line = line[1:-1].strip()
            lines.append(line)
        content = "\n".join(lines) + "\n"
        (target / "credits.txt").write_text(content, encoding="utf-8")
        report["credits"] = {"path": "media/credits.txt", "source_sha256": sha256(raw),
                             "source_encoding": encoding, "quoted_line_format": True}
    write_json(output / "media_manifest.json", report)
    return report
