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
            self.assertTrue({"hugo.glb", "palm.glb", "hugo_body.glb", "asset_manifest.json",
                             "campaign.json", "animation_manifest.json", "material_animation_manifest.json", "levels"}.issubset(
                                 {p.name for p in generated.iterdir()}))
            manifest = json.loads((generated / "asset_manifest.json").read_text())
            self.assertEqual(manifest["source"]["sha256"], original_hash)
            self.assertEqual(manifest["files"]["hugo.glb"]["triangles"], 596)
            self.assertEqual(manifest["files"]["hugo_body.glb"]["morph_target_accessors"], 30)
            campaign = json.loads((generated / "campaign.json").read_text())
            gameplay = json.loads((generated / "gameplay_manifest.json").read_text())
            animations = json.loads((generated / "animation_manifest.json").read_text())
            materials = json.loads((generated / "material_animation_manifest.json").read_text())
            self.assertEqual(len(campaign["levels"]), 8)
            self.assertEqual(len(gameplay["levels"]), 8)
            self.assertEqual(gameplay["event_coverage"]["unrecognized_source_events"], [])
            self.assertEqual(sum(len(v["owners"]) for v in gameplay["levels"].values()), 2514)
            self.assertEqual(animations["hugo_action_count"], 14)
            self.assertEqual(len(animations["surface_deaths"]), 27)
            self.assertEqual(len(animations["contact_deaths"]), 1)
            fatal_actor = gameplay["levels"]["g069"]["owners"]["g069_o0192_t10300"]
            death = fatal_actor["state_machine"]["contact_death_visual"]
            self.assertEqual((death["group"], death["record"], death["graph_offset"]), (69, 192, 0x4F0))
            clip = animations["clips"][death["action"]]
            self.assertEqual(clip["profile_role"], "contact_death")
            self.assertEqual(clip["authored_duration_seconds"], 2.0)
            self.assertEqual(len(clip["nodes"]), 3)
            self.assertTrue((generated / clip["path"]).is_file())
            self.assertEqual(len(fatal_actor["state_machine"]["contact_sound_sequence"]["cues"]), 1)
            self.assertEqual(len(materials["materials"]), 483)
            self.assertEqual(materials["validation"]["texture_sequences"], 285)
            self.assertEqual(materials["validation"]["color_animated_parts"], 190)
            self.assertEqual(materials["validation"]["uv_animated_parts"], 8)
            self.assertEqual(manifest["materials"]["validation"], materials["validation"])
            self.assertEqual(manifest["material_preview"]["textured_rgb_divisor"], 255)
            self.assertEqual(manifest["material_preview"]["uv_divisor"], 255)
            for chapter in campaign["levels"]:
                level = json.loads((generated / chapter["manifest_path"]).read_text())
                self.assertTrue(level["native_collision_meshes"])
                self.assertTrue(level["native_transform_tracks"])
                self.assertTrue(level["native_scope_policy"])
                self.assertEqual(gameplay["levels"][chapter["id"]]["native_player"]["movement"]["schema_version"], 1)
            for filename, info in manifest["files"].items():
                self.assertEqual(hashlib.sha256((generated / filename).read_bytes()).hexdigest(), info["sha256"])
            self.assertFalse((root / ".work/import.lock").exists())
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original_hash)


if __name__ == "__main__":
    unittest.main()
