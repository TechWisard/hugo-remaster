"""Optional local integration test; never downloads or embeds original assets."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("HUGO_BDF_SOURCE"), "Set HUGO_BDF_SOURCE to a local HUGO4.CD to run the full import")
class LocalOriginalImportTests(unittest.TestCase):
    def test_local_original_import(self):
        source = Path(os.environ["HUGO_BDF_SOURCE"]).resolve()
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.run([sys.executable, str(ROOT / "tools/import_original.py"), str(source),
                                     "--project-root", str(root)], capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            generated = root / "game/assets/generated"
            self.assertEqual({p.name for p in generated.iterdir()}, {"hugo.glb", "palm.glb", "hugo_body.glb", "asset_manifest.json"})
            manifest = json.loads((generated / "asset_manifest.json").read_text())
            self.assertEqual(manifest["source"]["sha256"], original_hash)
            self.assertEqual(manifest["files"]["hugo.glb"]["triangles"], 596)
            self.assertEqual(manifest["files"]["hugo_body.glb"]["morph_target_accessors"], 30)
            for filename, info in manifest["files"].items():
                self.assertEqual(hashlib.sha256((generated / filename).read_bytes()).hexdigest(), info["sha256"])
            self.assertFalse((root / ".work/import.lock").exists())
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original_hash)


if __name__ == "__main__":
    unittest.main()
