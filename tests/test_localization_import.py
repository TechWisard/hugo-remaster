"""Failure, deduplication and local-only contracts, using synthetic media only."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.localization import MANIFEST_NAME, import_languages


class LocalizationImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "output"
        self.spec_path = self.root / "languages.json"
        self.source = self.root / "local.bik"
        data = bytearray(1300)
        data[:4] = b"BIKi"
        struct.pack_into("<2I", data, 4, len(data) - 8, 2)
        struct.pack_into("<4I", data, 20, 320, 160, 1094451, 65536)
        struct.pack_into("<I", data, 40, 1)
        self.source.write_bytes(data)

    def tearDown(self):
        self.temp.cleanup()

    def descriptor(self):
        return {"source": self.source.name, "source_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}

    def spec(self, locale="en", key="intro_b"):
        return {"schema_version": 1, "default_voice_locale": locale,
                "voices": {locale: {"native_name": locale, "movies": {key: self.descriptor()}}}}

    def save_spec(self, spec):
        self.spec_path.write_text(json.dumps(spec), encoding="utf-8")

    @staticmethod
    def convert(command, **kwargs):
        Path(command[-1]).write_bytes(b"OggS" + bytes(1300))
        return subprocess.CompletedProcess(command, 0, "", "")

    def run_import(self, spec, **kwargs):
        self.save_spec(spec)
        return import_languages(self.spec_path, self.output, **kwargs)

    def test_same_source_and_track_is_converted_once_without_changing_input(self):
        spec = self.spec()
        spec["voices"]["fr"] = copy.deepcopy(spec["voices"]["en"])
        before = self.source.read_bytes()
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ) as run:
            report = self.run_import(spec)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(report["voices"]["en"]["movies"]["intro_b"]["path"], report["voices"]["fr"]["movies"]["intro_b"]["path"])
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(report["totals"]["distinct_files"], 1)
        self.assertFalse(report["voices"]["en"]["coverage"]["complete"])
        command = run.call_args.args[0]
        self.assertIn("-nostdin", command)
        self.assertNotIn("-r", command)
        self.assertNotIn("-s", command)

    def test_merge_retains_other_locales_and_reuses_checked_conversion(self):
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ) as run:
            self.run_import(self.spec())
            report = self.run_import(self.spec("fr", "outro"))
        self.assertEqual(set(report["voices"]), {"en", "fr"})
        self.assertEqual(run.call_count, 1)
        self.assertEqual(report["totals"]["reused_movies_this_import"], 1)

    def test_replace_explicitly_removes_an_old_locale(self):
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ):
            self.run_import(self.spec())
            report = self.run_import(self.spec("fr"), replace=True)
        self.assertEqual(set(report["voices"]), {"fr"})

    def test_failed_conversion_leaves_old_pack_byte_identical(self):
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ):
            self.run_import(self.spec())
        before = {p.relative_to(self.output).as_posix(): p.read_bytes() for p in self.output.rglob("*") if p.is_file()}
        data = bytearray(self.source.read_bytes())
        data[-1] = 1
        self.source.write_bytes(data)
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", return_value=subprocess.CompletedProcess([], 1, "", "synthetic decoder failure")
        ):
            with self.assertRaises(FormatError):
                self.run_import(self.spec("fr"))
        after = {p.relative_to(self.output).as_posix(): p.read_bytes() for p in self.output.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(list(self.root.glob(".output-staging-*")))

    def test_bad_source_hash_fails_before_conversion(self):
        spec = self.spec()
        spec["voices"]["en"]["movies"]["intro_b"]["source_sha256"] = "0" * 64
        with patch("hugo_assets.localization.subprocess.run") as run:
            with self.assertRaises(FormatError):
                self.run_import(spec)
            run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_executable_cannot_be_used_as_movie_input(self):
        self.source.write_bytes(b"MZ" + bytes(1298))
        with patch("hugo_assets.localization.subprocess.run") as run:
            with self.assertRaises(FormatError):
                self.run_import(self.spec())
            run.assert_not_called()

    def test_url_input_is_not_downloaded(self):
        spec = self.spec()
        spec["voices"]["en"]["movies"]["intro_b"]["source"] = "https://example.invalid/movie.bik"
        with patch("hugo_assets.localization.subprocess.run") as run:
            with self.assertRaises(FormatError):
                self.run_import(spec)
            run.assert_not_called()

    def test_wrong_audio_track_and_silent_voice_are_rejected(self):
        for track in (1, -1, True, None):
            with self.subTest(track=track):
                spec = self.spec()
                spec["voices"]["en"]["movies"]["intro_b"]["audio_track"] = track
                with self.assertRaises(FormatError):
                    self.run_import(spec)

    def test_corrupt_cache_is_rejected_without_replacing_existing_manifest(self):
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ):
            report = self.run_import(self.spec())
        manifest = (self.output / MANIFEST_NAME).read_bytes()
        (self.output / report["voices"]["en"]["movies"]["intro_b"]["path"]).write_bytes(b"bad")
        with self.assertRaises(FormatError):
            self.run_import(self.spec())
        self.assertEqual(manifest, (self.output / MANIFEST_NAME).read_bytes())

    def test_manifest_path_cannot_escape_the_language_root(self):
        with patch("hugo_assets.localization.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.localization.subprocess.run", side_effect=self.convert
        ):
            report = self.run_import(self.spec())
        report["voices"]["en"]["movies"]["intro_b"]["path"] = "../outside.ogv"
        (self.output / MANIFEST_NAME).write_text(json.dumps(report))
        with self.assertRaises(FormatError):
            self.run_import(self.spec())

    def test_unknown_cue_and_locale_path_are_rejected(self):
        for spec in (self.spec(key="imaginary_cue"), self.spec(locale="../ru")):
            with self.assertRaises(FormatError):
                self.run_import(spec)

    def test_previously_decoded_text_keeps_empty_ids_and_source_provenance(self):
        resource = {"schema_version": 1, "locale": "en", "string_count": 205, "strings": [""] * 205,
                    "source_sha256": "a" * 64, "source_record_index": 23, "encoding": "synthetic_fixture",
                    "unresolved_glyph_bytes": []}
        resource["strings"][204] = "Synthetic final entry"
        path = self.root / "text.json"
        path.write_text(json.dumps(resource), encoding="utf-8")
        spec = {"schema_version": 1, "native_texts": {"en": {"format": "native_text_json", "source": path.name}}}
        with patch("hugo_assets.localization.subprocess.run") as run:
            report = self.run_import(spec)
            run.assert_not_called()
        payload = json.loads((self.output / report["native_texts"]["en"]["path"]).read_text())
        self.assertEqual(payload["strings"], resource["strings"])
        self.assertEqual(payload["source_sha256"], "a" * 64)
        self.assertEqual(payload["import_input_format"], "previously_decoded_native_text_json")


if __name__ == "__main__":
    unittest.main()
