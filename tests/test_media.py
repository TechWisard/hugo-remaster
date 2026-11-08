from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.media import MOVIES, convert_media


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "output"

    def tearDown(self):
        self.temporary.cleanup()

    def movie(self, name="CUTSC01A.BIK"):
        header = bytearray(36)
        header[:4] = b"BIKf"
        struct.pack_into("<4I", header, 20, 320, 160, 1094451, 65536)
        path = self.source / name
        path.write_bytes(header + b"local synthetic fixture")
        return path

    @staticmethod
    def fake_convert(command, **kwargs):
        Path(command[-1]).write_bytes(b"OggS" + bytes(1100))
        return subprocess.CompletedProcess(command, 0, "", "")

    def test_source_dimensions_and_source_remains_unchanged(self):
        source = self.movie()
        before = source.read_bytes()
        with patch("hugo_assets.media.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.media.subprocess.run", side_effect=self.fake_convert
        ) as converter:
            report = convert_media(self.source, self.output)
        movie = report["movies"]["intro_a"]
        self.assertEqual((movie["width"], movie["height"]), (320, 160))
        self.assertEqual(movie["frame_rate_numerator"], 1094451)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(converter.call_count, 1)
        self.assertIn("-nostdin", converter.call_args.args[0])
        self.assertEqual(len(report["missing_movies"]), len(MOVIES) - 1)

    def test_verified_cache_reused_but_corrupt_cache_reconverted(self):
        self.movie()
        with patch("hugo_assets.media.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.media.subprocess.run", side_effect=self.fake_convert
        ) as converter:
            convert_media(self.source, self.output)
            convert_media(self.source, self.root / "second", cache_dir=self.output)
            self.assertEqual(converter.call_count, 1)
            (self.output / "media/intro_a.ogv").write_bytes(b"OggS corrupted")
            convert_media(self.source, self.root / "third", cache_dir=self.output)
            self.assertEqual(converter.call_count, 2)

    def test_changed_source_invalidates_cache(self):
        source = self.movie()
        with patch("hugo_assets.media.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.media.subprocess.run", side_effect=self.fake_convert
        ) as converter:
            convert_media(self.source, self.output)
            source.write_bytes(source.read_bytes() + b"changed source")
            convert_media(self.source, self.root / "second", cache_dir=self.output)
            self.assertEqual(converter.call_count, 2)

    def test_bad_movie_header_never_invokes_converter(self):
        (self.source / "CUTSC01A.BIK").write_bytes(b"MZ this is not a movie")
        with patch("hugo_assets.media.shutil.which", return_value="ffmpeg"), patch(
            "hugo_assets.media.subprocess.run"
        ) as converter:
            with self.assertRaises(FormatError):
                convert_media(self.source, self.output)
            converter.assert_not_called()

    def test_missing_optional_media_does_not_invoke_a_tool(self):
        with patch("hugo_assets.media.subprocess.run") as converter:
            report = convert_media(self.source, self.output)
            converter.assert_not_called()
        self.assertEqual(report["movies"], {})
        self.assertEqual(len(report["missing_movies"]), len(MOVIES))

    def test_western_credits_preserve_accents_and_remove_only_line_delimiters(self):
        original = '" CREATIVE COORDINATOR "\r\n"RENÉ BIDSTRUP"\r\n\r\n"ELSA SØBY"\r\n"EIRIK JOHNSBRÅTEN"'.encode("cp1252")
        (self.source / "CREDITS.TXT").write_bytes(original)
        report = convert_media(self.source, self.output)
        self.assertEqual((self.output / "media/credits.txt").read_text(),
                         "CREATIVE COORDINATOR\nRENÉ BIDSTRUP\n\nELSA SØBY\nEIRIK JOHNSBRÅTEN\n")
        self.assertEqual(report["credits"]["source_encoding"], "cp1252")
        self.assertEqual((self.source / "CREDITS.TXT").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
