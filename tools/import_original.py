#!/usr/bin/env python3
"""Recover local Hugo: Black Diamond Fever resources for the Godot project."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

# Also supports importlib/unittest invocation from the repository root.
TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Outputs: game/assets/generated/ with levels, actor animations and provenance manifests. "
        "Intermediate extraction stays in .work/. This importer does not download the game or run its EXE."))
    parser.add_argument("source", type=Path, help="Path to the original HUGO4.CD resource file (not an ISO/ZIP)")
    parser.add_argument("--project-root", type=Path, default=TOOLS.parent,
                        help="Project receiving generated assets (default: this repository)")
    parser.add_argument("--debug", action="store_true", help="Show a traceback on an import error")
    parser.add_argument("--previews-only", action="store_true", help="Only export the original three model previews")
    parser.add_argument("--media-dir", type=Path, help="Optional local directory containing original BIK movies and CREDITS.TXT")
    parser.add_argument("--music-dir", type=Path, help="Optional local directory with original Track02.ogg through Track09.ogg")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Local ffmpeg executable used for BIK conversion")
    parser.add_argument("--version", action="version", version="hugo-remaster importer 0.6.0")
    args = parser.parse_args(argv)
    try:
        from hugo_assets.binary import FormatError
        from hugo_assets.importer import import_original
    except ImportError as exc:
        print(f"Missing importer dependency: {exc}. Install with: python -m pip install -r tools/requirements.txt", file=sys.stderr)
        return 2
    try:
        result = import_original(args.source, args.project_root, progress=lambda message: print(message, flush=True),
                                 include_campaign=not args.previews_only, media_dir=args.media_dir,
                                 music_dir=args.music_dir, ffmpeg=args.ffmpeg)
    except (FormatError, OSError, ValueError) as exc:
        if args.debug:
            raise
        print(f"Import failed: {exc}", file=sys.stderr)
        return 2
    print(f"Imported {result['validation']['geometry']['mesh_records']} validated mesh records; "
          f"published {len(result['files'])} generated files and asset_manifest.json.")
    print(f"Source SHA-256: {result['source']['sha256']}")
    print("Recovery evidence and remaining fidelity limits are recorded in the generated manifests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
