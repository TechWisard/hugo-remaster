"""Native string boundaries and glyph rules; no original text is embedded."""
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from hugo_assets.binary import FormatError
from hugo_assets.catalog import Record
from hugo_assets.native_text import decode_glyph_bytes, decode_native_texts, read_native_text_table


def table(name="English", strings=None, *, old=False, index=23):
    strings = [b"SYNTHETIC", b"", *([b"entry"] * 203)] if strings is None else strings
    header = 12 if old else 16
    data = bytearray(header)
    if not old:
        struct.pack_into("<I", data, 4, 16)
        data += name.encode("ascii") + b"\0"
        data += bytes((-len(data)) % 4)
    table_at = len(data)
    struct.pack_into("<HH", data, 8 if old else 12, table_at, len(strings))
    data += bytes(len(strings) * 4)
    for i, value in enumerate(strings):
        struct.pack_into("<I", data, table_at + i * 4, len(data))
        data += value + b"\0"
        data += bytes((-len(data)) % 4)
    return Record(index, 0, 6006, header, bytes(data), 0)


def catalog(records):
    return SimpleNamespace(container=SimpleNamespace(data=b"synthetic container"),
                           scenes={0: SimpleNamespace(records=records)})


class NativeTextTests(unittest.TestCase):
    def test_named_and_old_layout_keep_all_205_ids(self):
        for old in (False, True):
            with self.subTest(old=old):
                result = read_native_text_table(table(old=old))
                self.assertEqual(result["count"], 205)
                self.assertEqual(result["raw_strings"][1], b"")
                self.assertEqual(result["raw_strings"][204], b"entry")

    def test_offset_into_header_is_rejected(self):
        record = table()
        data = bytearray(record.data)
        offset = struct.unpack_from("<H", data, 12)[0]
        struct.pack_into("<I", data, offset, 16)
        with self.assertRaises(FormatError):
            read_native_text_table(Record(23, 0, 6006, 16, bytes(data), 0))

    def test_missing_terminator_cannot_read_into_next_string(self):
        record = table()
        result = read_native_text_table(record)
        data = bytearray(record.data)
        begin, end = result["offsets"][:2]
        data[begin:end] = b"X" * (end - begin)
        with self.assertRaises(FormatError):
            read_native_text_table(Record(23, 0, 6006, 16, bytes(data), 0))

    def test_central_and_polish_maps_use_proven_glyphs(self):
        self.assertEqual(decode_glyph_bytes(bytes([0xE7, 0xE9, 0xEF, 0xF3]), "central_latin"), ("ČĚŐŰ", []))
        self.assertEqual(decode_glyph_bytes(bytes([0x8C, 0x8F, 0xA3, 0xA5, 0xAF, 0xC6, 0xCA, 0xD1]), "polish"), ("ŚŹŁĄŻĆĘŃ", []))
        self.assertEqual(decode_glyph_bytes(b"ABC" + bytes([0xC8, 0xCE]), "russian"), ("АБВЩЫ", []))

    def test_sprite_code_is_explicitly_unresolved(self):
        text, unknown = decode_glyph_bytes(bytes([0xEC]), "central_latin")
        self.assertEqual(unknown, [0xEC])
        self.assertEqual(text, "⟦glyph:EC⟧")

    def test_russian_duplicate_does_not_advertise_fake_english(self):
        values = [b"ABC", *([b""] * 204)]
        result = decode_native_texts(catalog([table("English", values), table("Russian", values, index=33)]))
        self.assertEqual(set(result), {"ru"})
        self.assertEqual(result["ru"]["source_record_index"], 33)
        self.assertEqual(result["ru"]["strings"][0], "АБВ")
        self.assertEqual(result["ru"]["duplicate_english_slot_records"], [23])

    def test_unnamed_credits_are_not_a_language(self):
        result = decode_native_texts(catalog([table("English"), table("", [b""] * 208, index=40)]))
        self.assertEqual(set(result), {"en"})

    def test_unknown_old_table_is_not_assigned_by_ordinal(self):
        with self.assertRaises(FormatError):
            decode_native_texts(catalog([table(old=True, index=19)]))


if __name__ == "__main__":
    unittest.main()
