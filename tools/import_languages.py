#!/usr/bin/env python3
"""Import local Hugo original voice movies and native text language tables."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "The specification explicitly maps each locale and movie cue to local files. "
        "No game, movie, voice or installer is downloaded or executed. Existing locales are retained unless --replace is set."))
    parser.add_argument("--language-spec", required=True, type=Path, help="Local schema1 language specification JSON")
    parser.add_argument("--project-root", type=Path, default=TOOLS.parent, help="Receiving project (default: this repository)")
    parser.add_argument("--output", type=Path, help="Override generated language directory; default game/assets/localization")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Trusted local ffmpeg executable")
    parser.add_argument("--jobs", type=int, default=2, help="Parallel movie conversions, 1..8 (default2)")
    parser.add_argument("--replace", action="store_true", help="Replace the complete installed language set with this specification")
    parser.add_argument("--debug", action="store_true", help="Show an import traceback")
    args = parser.parse_args(argv)
    try:
        from hugo_assets.binary import FormatError
        from hugo_assets.localization import import_languages
    except ImportError as exc:
        print(f"Missing importer dependency: {exc}. Install tools/requirements.txt.", file=sys.stderr)
        return 2
    try:
        report = import_languages(args.language_spec, args.output or args.project_root / "game/assets/localization",
                                  ffmpeg=args.ffmpeg, jobs=args.jobs, replace=args.replace,
                                  progress=lambda message: print(message, flush=True))
    except (FormatError, OSError, ValueError) as exc:
        if args.debug:
            raise
        print(f"Language import failed: {exc}", file=sys.stderr)
        return 2
    totals = report["totals"]
    print(f"Imported {totals['voice_locales']} voice locales and {totals['native_text_locales']} native text tables; "
          f"{totals['movie_cues']} cue mappings, {totals['distinct_files']} distinct payload files, {totals['payload_bytes']} bytes.")
    print("Original executable run: false. Source and output hashes are recorded in localization_manifest.json.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
