"""Offline pack integrity tests. No neural DLL or game is executed."""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dlss5_build_pack", REPO / "integrations/dlss5/build_pack.py")
PACK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACK)


class Dlss5PackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.sources = self.root / "sources"
        (self.sources / "templates").mkdir(parents=True)
        (self.sources / "templates/ReShade.ini").write_text("[Uplift]\nEnabled=1\n")
        (self.sources / "Install-Hugo-DLSS5.ps1").write_text("# fixture, never executed\n")
        (self.sources / "README.md").write_text("Offline fixture\n")
        archive = self.cache / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as target:
            target.writestr("component/data.bin", b"unmodified publisher bytes")
        data = b"unmodified publisher bytes"
        self.lock = {
            "components": [{
                "id": "fixture", "version": "1", "type": "zip",
                "artifact": {"url": "https://invalid.example/never-requested.zip", "cache_name": archive.name,
                             "size": archive.stat().st_size, "sha256": PACK.digest_file(archive)},
                "members": [{"member": "component/data.bin", "destination": "nested/data.bin",
                             "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}],
            }],
            "required_pe_exports": {},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def build(self, output):
        with patch.object(PACK, "ROOT", self.sources), patch.object(PACK, "request", side_effect=AssertionError("offline test contacted network")):
            return PACK.build(self.lock, output, self.cache)

    def test_atomic_pack_contains_real_bytes_and_never_claims_execution(self):
        output = self.root / "pack"
        result = self.build(output)
        self.assertEqual((output / "payload/nested/data.bin").read_bytes(), b"unmodified publisher bytes")
        self.assertEqual(result["hardware_validation"], "not_run")
        self.assertEqual(result["model_execution"], "not_run")
        self.assertEqual(json.loads((output / "pack-manifest.json").read_text()), result)

    def test_bad_member_hash_leaves_no_partial_installation(self):
        self.lock["components"][0]["members"][0]["sha256"] = "0" * 64
        output = self.root / "failed"
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.build(output)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob(".dlss5-stage-*")))

    def test_cache_tampering_is_not_silently_accepted_or_redownloaded(self):
        archive = self.cache / "fixture.zip"
        data = bytearray(archive.read_bytes())
        data[20] ^= 1
        archive.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.build(self.root / "failed")

    def test_existing_output_is_not_overwritten(self):
        output = self.root / "existing"
        output.mkdir()
        (output / "keep.txt").write_text("user file")
        with self.assertRaises(FileExistsError):
            self.build(output)
        self.assertEqual((output / "keep.txt").read_text(), "user file")

    def test_path_traversal_and_absolute_cache_paths_are_rejected(self):
        for name in ("../outside", "/outside", "C:/outside", "a/../../outside", "a\\outside"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                PACK.checked_path(self.root, name)
        self.lock["components"][0]["members"][0]["destination"] = "../outside"
        with self.assertRaises(ValueError):
            self.build(self.root / "failed")
        self.assertFalse((self.root / "outside").exists())

    def test_x86_executables_are_rejected_without_execution(self):
        data = bytearray(512)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 0x3C, 64)
        data[64:68] = b"PE\0\0"
        struct.pack_into("<H", data, 68, 0x14C)
        struct.pack_into("<H", data, 88, 0x10B)
        path = self.root / "old.exe"
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "Windows x64"):
            PACK.inspect_pe(path)

    def test_actual_lock_selects_compat_nr_and_keeps_neural_api_distinct(self):
        lock = json.loads((REPO / "integrations/dlss5/dependencies.lock.json").read_text())
        nr = next(c for c in lock["components"] if c["id"] == "dlss_nr_compat")
        self.assertEqual(nr["members"][0]["sha256"], "cdfa6c1ec784867182164c7836f324f087b5c9f374d0c9fe46f54999feabf3ed")
        paths = [m["destination"] for c in lock["components"] for m in c.get("members", [])]
        self.assertIn("GITC-Uplift/nvngx_dlssnr.dll", paths)
        self.assertNotIn("nvngx_dlss.dll", paths)
        self.assertNotIn("nvngx_dlssg.dll", paths)

    def test_visual_helper_is_required_and_pinned_in_authored_manifest(self):
        self.lock["required_authored_files"] = ["Hugo-NR-ImageCapture.cs"]
        with self.assertRaisesRegex(ValueError, "Missing required authored template"):
            self.build(self.root / "missing_helper")
        helper = self.sources / "templates/Hugo-NR-ImageCapture.cs"
        helper.write_text("// authored capture fixture; never executed\n")
        result = self.build(self.root / "with_helper")
        pinned = next(item for item in result["authored_templates"] if item["path"] == helper.name)
        self.assertEqual(pinned["sha256"], PACK.digest_file(helper))
        self.assertEqual(pinned["size"], helper.stat().st_size)
        payload = next(item for item in result["files"] if item["path"] == helper.name)
        self.assertEqual(payload["sha256"], pinned["sha256"])
        self.assertFalse(payload["mutable"])
        lock = json.loads((REPO / "integrations/dlss5/dependencies.lock.json").read_text())
        self.assertTrue({"Check-Hugo-NR-Image.cmd", "Check-Hugo-NR-Image.ps1", "Hugo-NR-ImageCapture.cs"}.issubset(lock["required_authored_files"]))


if __name__ == "__main__":
    unittest.main()
