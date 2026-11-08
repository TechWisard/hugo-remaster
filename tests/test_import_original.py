"""Synthetic-only tests: no original game files or copyrighted fixture assets."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import numpy as np
from PIL import Image

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog, Record, parse_scene
from hugo_assets.gltf import export_glb, preview_colors, verify_glb
from hugo_assets.importer import import_lock, publish_directory, read_source
from hugo_assets.mdic import MAX_SOURCE_BYTES, extract, parse_mdic
from hugo_assets.mesh import Selection, audit_meshes, parse_mesh

PIXELS = bytes((255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 255, 255, 255, 128))


def chunk(kind, payload=b"", aux=None):
    header = 24 if aux is not None else 16
    raw = b"MDIC" + struct.pack("<III", header, len(payload), kind)
    if aux is not None:
        raw += struct.pack("<II", *aux)
    raw += payload
    return raw + b"\0" * (-len(raw) % 2048)


def synthetic_mesh(samples=2):
    """A generated, textured triangle with one genuine moving vertex sample."""
    b = bytearray(156)
    for offset, value in ((0, 2001), (4, 0x01010101), (32, 0x02020202),
                          (40, 104), (44, 112), (112, 116)):
        struct.pack_into("<I", b, offset, value)
    struct.pack_into("<H", b, 38, 1)
    struct.pack_into("<HH", b, 104, samples, samples)
    struct.pack_into("<6f", b, 72, 0, 0, 0, 10, 10, samples - 1)
    vertices = b"".join(struct.pack("<hhhBB", x, y, z, u, v)
                        for z in range(samples)
                        for x, y, u, v in ((0, 0, 0, 0), (10, 0, 255, 0), (0, 10, 0, 255)))
    face = 156 + len(vertices)
    color = face + 4
    material = color + 12
    timeline = material + 20
    struct.pack_into("<I", b, 48, timeline)
    struct.pack_into("<IIHHII", b, 116, 0x10003, 0x60000000, 3, 1, face, 156)
    struct.pack_into("<II", b, 148, color, material)
    b += vertices + struct.pack("<I", (1 << 10) | (2 << 20)) + bytes((128, 128, 128, 0)) * 3
    b += struct.pack("<HHIII4B", 0, 1, material + 8, material + 12, 7, 0, 0, 2, 2)
    b += b"".join(struct.pack("<I", i << 16) for i in range(samples))
    return bytes(b)


def synthetic_scene(mesh=None):
    mesh = synthetic_mesh() if mesh is None else mesh
    return (b"\x01" * 4 + b"\x02" * 4 + struct.pack("<HHI", 2, 1, 16)
            + struct.pack("<III", 0x03030303, 1, 28)
            + struct.pack("<III", 40, 2001, 104) + mesh)


def synthetic_wav():
    out = io.BytesIO()
    with wave.open(out, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(11025)
        wav.writeframes(struct.pack("<3h", 0, 200, -200))
    return out.getvalue()


def synthetic_container():
    assets = [chunk(2, PIXELS, (7, (2 << 16) | 2)),
              chunk(4, synthetic_scene()), chunk(5, synthetic_wav(), (1, 0))]
    return chunk(1, aux=(2048 + sum(map(len, assets)), len(assets))) + b"".join(assets)


class ContainerTests(unittest.TestCase):
    def test_complete_synthetic_container_and_lossless_extraction(self):
        container = parse_mdic(synthetic_container())
        self.assertEqual(len(container.groups), 1)
        self.assertEqual([c.kind for c in container.chunks], [1, 2, 4, 5])
        catalog = Catalog(container)
        report, _ = audit_meshes(catalog)
        self.assertEqual(report["mesh_records"], 1)
        self.assertEqual(report["models_with_changing_vertex_positions"], 1)
        self.assertEqual(report["resolved_texture_references"], 1)
        with tempfile.TemporaryDirectory() as temporary:
            exports = extract(container, Path(temporary))
            with Image.open(exports[1]) as png:
                self.assertEqual(png.mode, "RGBA")
                self.assertEqual(png.tobytes(), PIXELS)
            self.assertEqual(exports[2].read_bytes(), synthetic_scene())
            self.assertEqual(exports[3].read_bytes(), synthetic_wav())

    def test_declared_members_and_spans_are_enforced(self):
        for offset, value, message in ((20, 2, "members"), (16, 10240, "span")):
            with self.subTest(offset=offset):
                data = bytearray(synthetic_container())
                struct.pack_into("<I", data, offset, value)
                with self.assertRaisesRegex(FormatError, message):
                    parse_mdic(bytes(data))

    def test_truncation_and_wrong_texture_dimensions_are_rejected(self):
        with self.assertRaisesRegex(FormatError, "aligned"):
            parse_mdic(synthetic_container()[:-1])
        data = bytearray(synthetic_container())
        struct.pack_into("<I", data, 2048 + 20, (2 << 16) | 3)
        with self.assertRaisesRegex(FormatError, "RGBA length"):
            parse_mdic(bytes(data))

    def test_bad_audio_riff_length_is_rejected(self):
        wav = bytearray(synthetic_wav())
        struct.pack_into("<I", wav, 4, len(wav) + 50)
        asset = chunk(5, bytes(wav), (1, 0))
        data = chunk(1, aux=(4096, 1)) + asset
        with self.assertRaisesRegex(FormatError, "RIFF size"):
            parse_mdic(data)

    def test_scene_offsets_are_checked_before_iteration_or_allocation(self):
        data = bytearray(synthetic_scene())
        struct.pack_into("<I", data, 12, 0xFFFFFFFC)
        with self.assertRaisesRegex(FormatError, "outside"):
            parse_scene(bytes(data), 0)
        data = bytearray(synthetic_scene())
        struct.pack_into("<I", data, 28, 28)
        with self.assertRaisesRegex(FormatError, "overlapping"):
            parse_scene(bytes(data), 0)


class MeshTests(unittest.TestCase):
    def record(self, data):
        return Record(0, 40, 2001, 104, data, 0)

    def test_out_of_range_triangle_is_rejected(self):
        data = bytearray(synthetic_mesh())
        face = struct.unpack_from("<I", data, 128)[0]
        struct.pack_into("<I", data, face, 3 | (1 << 10) | (2 << 20))
        with self.assertRaisesRegex(FormatError, "index exceeds"):
            parse_mesh(self.record(bytes(data)))

    def test_sample_count_and_nan_bounds_are_rejected(self):
        data = bytearray(synthetic_mesh())
        struct.pack_into("<H", data, 104, 65535)
        with self.assertRaisesRegex(FormatError, "sample size"):
            parse_mesh(self.record(bytes(data)))
        data = bytearray(synthetic_mesh())
        struct.pack_into("<f", data, 72, float("nan"))
        with self.assertRaisesRegex(FormatError, "bounding box"):
            parse_mesh(self.record(bytes(data)))

    def test_neutral_texture_color_is_not_half_brightness(self):
        colors = preview_colors(np.array([[128, 128, 128], [255, 64, 0]]), textured=True)
        np.testing.assert_allclose(colors, [[1, 1, 1], [1, 0.5, 0]])
        np.testing.assert_allclose(preview_colors(np.array([[128, 128, 128]]), textured=False), [[128 / 255] * 3])

    def test_export_has_bounded_indices_embedded_texture_and_morph_sample(self):
        catalog = Catalog(parse_mdic(synthetic_container()))
        model = parse_mesh(catalog.record(0, 0, 2001))
        encoded = export_glb(catalog, [Selection(model, "synthetic_triangle", np.zeros(3), np.eye(3))], include_samples=True)
        result = verify_glb(encoded)
        self.assertEqual((result["vertices"], result["triangles"], result["morph_target_accessors"]), (3, 1, 1))
        self.assertEqual(result["embedded_texture_sizes"], [[2, 2]])
        np.testing.assert_allclose(result["bounds"], [[0, 0, -0.1], [0.1, 0, 0]], atol=1e-7)
        json_size = struct.unpack_from("<I", encoded, 12)[0]
        doc = json.loads(encoded[20:20 + json_size])
        self.assertEqual(doc["materials"][0]["alphaMode"], "MASK")
        self.assertEqual(doc["meshes"][0]["extras"]["targetNames"], ["sample_001"])
        self.assertNotIn("animations", doc)
        accessor = doc["accessors"][doc["meshes"][0]["primitives"][0]["attributes"]["COLOR_0"]]
        view = doc["bufferViews"][accessor["bufferView"]]
        first_color = struct.unpack_from("<4f", encoded, 28 + json_size + view["byteOffset"])
        self.assertEqual(first_color, (1.0, 1.0, 1.0, 1.0))


class PublicationAndCliTests(unittest.TestCase):
    def test_failed_promotion_restores_previous_asset_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            current, staged = parent / "generated", parent / "staged"
            current.mkdir(); staged.mkdir()
            (current / "hugo.glb").write_bytes(b"previous validated output")
            (current / "asset_manifest.json").write_bytes(b"previous manifest")
            (staged / "hugo.glb").write_bytes(b"new output")
            real_replace = os.replace

            def fail_promotion(source, destination):
                if Path(source) == staged:
                    raise OSError("simulated publication failure")
                return real_replace(source, destination)

            with patch("hugo_assets.importer.os.replace", side_effect=fail_promotion):
                with self.assertRaisesRegex(OSError, "simulated"):
                    publish_directory(staged, current)
            self.assertEqual((current / "hugo.glb").read_bytes(), b"previous validated output")
            self.assertEqual((current / "asset_manifest.json").read_bytes(), b"previous manifest")
            self.assertTrue(staged.is_dir())

    def test_concurrent_import_does_not_take_or_remove_existing_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            with import_lock(work):
                owner = (work / "import.lock").read_text()
                with self.assertRaisesRegex(FormatError, "lock"):
                    with import_lock(work):
                        self.fail("A second importer acquired the lock")
                self.assertEqual((work / "import.lock").read_text(), owner)
            self.assertFalse((work / "import.lock").exists())

    def test_cli_rejects_corrupt_input_without_changing_existing_assets_even_under_optimization(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            generated = root / "game/assets/generated"
            generated.mkdir(parents=True)
            (generated / "hugo.glb").write_bytes(b"keep existing assets")
            source = root / "HUGO4.CD"
            source.write_bytes(b"MDIC")
            result = subprocess.run([sys.executable, "-O", str(ROOT / "tools/import_original.py"), str(source),
                                     "--project-root", str(root)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("Import failed:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual((generated / "hugo.glb").read_bytes(), b"keep existing assets")
            self.assertEqual(sorted(p.name for p in generated.iterdir()), ["hugo.glb"])
            self.assertEqual(source.read_bytes(), b"MDIC")

    def test_cli_help_documents_direct_resource_input(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools/import_original.py"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("HUGO4.CD", result.stdout)
        self.assertIn("--project-root", result.stdout)

    def test_disc_images_are_rejected_without_loading_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "disc.iso"
            with source.open("wb") as out:
                out.seek(MAX_SOURCE_BYTES)
                out.write(b"\0")
            with self.assertRaisesRegex(FormatError, "disc image"):
                read_source(source)


if __name__ == "__main__":
    unittest.main()
