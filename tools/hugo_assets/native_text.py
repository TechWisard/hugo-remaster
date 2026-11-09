"""Bounds-checked recovery of the original 205-entry type-6006 text tables.

Only format rules, Unicode glyph maps and comparison hashes live in the public
source. Original strings are read from a user-supplied resource container.
"""
from __future__ import annotations

import hashlib
import struct
from typing import Iterable

from .binary import Reader, require
from .catalog import Catalog, Record
from .mdic import sha256


LANGUAGE_IDS = {
    "Danish": "da", "Swedish": "sv", "Norwegian": "no", "Finnish": "fi",
    "English": "en", "French": "fr", "Spanish": "es", "Italian": "it",
    "Portuguese": "pt-PT", "Dutch": "nl", "German": "de", "Czech": "cs",
    "Hungarian": "hu", "Slovakian": "sk", "Russian": "ru", "Polish": "pl",
}
CENTRAL_MAP = {
    0xE7: "Č", 0xE8: "Ď", 0xE9: "Ě", 0xEA: "Ĺ", 0xEB: "Ľ", 0xEE: "Ň",
    0xEF: "Ő", 0xF0: "Ř", 0xF1: "Ŕ", 0xF2: "Ť", 0xF3: "Ű", 0xF4: "Ů", 0xF5: "Ž",
}
POLISH_MAP = {0x8C: "Ś", 0x8F: "Ź", 0xA3: "Ł", 0xA5: "Ą", 0xAF: "Ż", 0xC6: "Ć", 0xCA: "Ę", 0xD1: "Ń"}
RUSSIAN_MAP = dict(zip(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ", "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШ"))
RUSSIAN_MAP.update(dict(zip(range(0xC8, 0xCF), "ЩЬЪЭЮЯЫ")))
AUTONYM_IDS = (182, 183, 184, *range(191, 202))
AUTONYM_FINGERPRINT = "b7da777b70851d59b603a863ac0bfa8c8c1c26fdf18563ee1169b5d2d421b88a"

# The earlier Nordic build omits names from its header12 tables. These hashes
# cover ALL 205 length-prefixed raw strings and match the named Central build.
# No language is inferred from a file's country, ordinal, or likely words.
UNNAMED_TABLE_IDENTITIES = {
    "e537943b4386cae00f305500472867ba1ecdd22d301c9ebe4c8418e2d2b2ddd9": "da",
    "3969eddd0c3e0462c86c4ed5af47a99222b90a1477e7699e9d131018d2182323": "sv",
    "8c113fff6b4075dc240a75e570c26c8eaadf89cd8f7e011b54780a5b741d6463": "no",
    "f9d260ea8cf1f3286f33b24e80b5b1c3ce6c823e219b20a53741e0bc8320f8e3": "fi",
    "0f6f5b21023fbf61707a4adeea896dbf46bd1c55e3ee62dc5fa403520ab33454": "en",
    "3b770930231858182b14300f0285b5457e8138146545c74e62b6c73f9b2fa37b": "fr",
    "1c28d6728e7c039c11843532970c0daf326aa3d15a32f77debc4e5f3b5eaed71": "es",
    "81905c42242960f68c946173aa5a54957091740ed71e59d7142a3b6f759448d4": "it",
    "8499e9de777a19f8c129d928201f27ba62b27424985c41ba3a340556a812e8e7": "pt-PT",
    "d5100747ed44d5e917d042af087e6a110d652eebe7eb0eedecc1dd014b5c3a1f": "nl",
    "d9d3cfe426cff47e3037b29b9247d1eb34c32a645fde3b69be1dfd4773ee6a43": "de",
    "09dd1264640660feae92448debd411ab2cb6595de47f4c36f64909d9ccf652f1": "cs",
    "d821918d60f37fc104534211138d27bbce774eb2cf16dadb2429e4f923823084": "hu",
    "02d5671a41baf04def9f9919bfdb08e3d193a0938561ed36ac554a2798c138be": "sk",
}


def strings_fingerprint(strings: Iterable[bytes]) -> str:
    digest = hashlib.sha256()
    for raw in strings:
        digest.update(struct.pack("<I", len(raw)))
        digest.update(raw)
    return digest.hexdigest()


def read_native_text_table(record: Record) -> dict:
    """Keep positional IDs, including empty strings, in either proven layout."""
    r = Reader(record.data, record.label)
    require(record.kind == 6006 and record.header_size in (12, 16),
            "Expected a native text record6006/header12 or16")
    require(r.u32(0) == 0, "Unexpected text record flags")
    if record.header_size == 16:
        require(r.u32(8) == 0, "Unexpected text record flags")
        name_at = r.u32(4)
        table_at, count = r.unpack("<HH", 12)
        require(name_at == 16 and table_at >= 20 and table_at % 4 == 0,
                "Unsupported text table/name layout")
        r.check(name_at, table_at - name_at, "language name")
        name_end = record.data.find(b"\0", name_at, table_at)
        require(name_end >= name_at, "Unterminated table name")
        try:
            name = record.data[name_at:name_end].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("Native table name is not ASCII") from exc
    else:
        require(r.u32(4) == 0, "Unexpected old-layout text flags")
        table_at, count = r.unpack("<HH", 8)
        require(table_at == 12, "Unsupported header12 text table offset")
        name = ""
    require(0 < count <= 4096, "Invalid native text count")
    r.check(table_at, count * 4, "string offset table")
    offsets = r.unpack(f"<{count}I", table_at)
    require(offsets[0] == table_at + count * 4, "Strings do not follow the complete pointer table")
    strings = []
    for index, offset in enumerate(offsets):
        end = offsets[index + 1] if index + 1 < count else len(record.data)
        require(offset % 4 == 0 and table_at + count * 4 <= offset < end <= len(record.data),
                "Out-of-order or out-of-bounds native string offset")
        terminator = record.data.find(b"\0", offset, end)
        require(terminator >= offset, "Native string lacks a bounded NUL terminator")
        strings.append(record.data[offset:terminator])
    return {"name": name, "record_index": record.index, "header_size": record.header_size,
            "table_offset": table_at, "count": count, "offsets": list(offsets),
            "raw_strings": strings, "record_sha256": sha256(record.data)}


def decode_glyph_bytes(raw: bytes, alphabet: str) -> tuple[str, list[int]]:
    require(alphabet in ("central_latin", "russian", "polish"), "Unknown native glyph alphabet")
    overrides = RUSSIAN_MAP if alphabet == "russian" else POLISH_MAP if alphabet == "polish" else CENTRAL_MAP
    result = []
    unknown = []
    for code in raw:
        if code in overrides:
            result.append(overrides[code])
            continue
        # These two positions contain sprites, not Latin-1 accented letters.
        if code in (0xEC, 0xED) or code < 32:
            unknown.append(code)
            result.append(f"⟦glyph:{code:02X}⟧")
            continue
        try:
            result.append(bytes([code]).decode("cp1252"))
        except UnicodeDecodeError:
            unknown.append(code)
            result.append(f"⟦glyph:{code:02X}⟧")
    return "".join(result), sorted(set(unknown))


def decode_native_texts(catalog: Catalog) -> dict[str, dict]:
    """Return per-locale JSON resources, including raw-byte and record evidence."""
    require(0 in catalog.scenes, "Native text container has no global scene")
    source_hash = sha256(catalog.container.data)
    tables = [read_native_text_table(record) for record in catalog.scenes[0].records if record.kind == 6006]
    russian = next((table for table in tables if table["name"] == "Russian"), None)
    output = {}
    for table in tables:
        name = table["name"]
        if not name and table["count"] != 205:
            continue  # The separate 208-entry credits resource is not a locale.
        require(table["count"] == 205, "Expected all 205 native language string IDs")
        if name:
            require(name in LANGUAGE_IDS, f"Unrecognized native language table: {name}")
            locale = LANGUAGE_IDS[name]
            identity = "embedded_language_name"
        else:
            locale = UNNAMED_TABLE_IDENTITIES.get(strings_fingerprint(table["raw_strings"]))
            require(locale is not None, "Unnamed native language does not match a proven 205-string table")
            identity = "all_205_length_prefixed_raw_strings_match_named_reference"
        if name == "English" and russian is not None and table["raw_strings"] == russian["raw_strings"]:
            continue  # Canonical Russian is the explicitly named table, never an English option.
        require(locale not in output, f"Ambiguous duplicate native language: {locale}")
        alphabet = "russian" if locale == "ru" else "polish" if locale == "pl" else "central_latin"
        latin_autonyms = alphabet != "central_latin" and strings_fingerprint(
            table["raw_strings"][index] for index in AUTONYM_IDS) == AUTONYM_FINGERPRINT
        strings = []
        evidence = []
        unresolved = set()
        for index, raw in enumerate(table["raw_strings"]):
            glyph_text, unknown = decode_glyph_bytes(raw, alphabet)
            value = glyph_text
            policy = "type2002_glyph_mapping"
            if latin_autonyms and index in AUTONYM_IDS:
                value = raw.decode("cp1252")
                policy = "unchanged_latin_language_name_verified_by_reference_hash"
                unknown = []
            strings.append(value)
            row = {"id": index, "offset": table["offsets"][index], "raw_hex": raw.hex(), "decode_policy": policy}
            if value != glyph_text:
                row["source_atlas_glyph_text"] = glyph_text
            if unknown:
                row["unresolved_glyph_bytes"] = unknown
                unresolved.update(unknown)
            evidence.append(row)
        output[locale] = {
            "schema_version": 1, "locale": locale, "source_sha256": source_hash,
            "source_group": 0, "source_record_index": table["record_index"], "source_record_kind": 6006,
            "source_record_sha256": table["record_sha256"], "source_header_size": table["header_size"],
            "source_table_name": name, "language_identity_evidence": identity,
            "encoding": f"hugo_{alphabet}_glyphs_v1", "string_count": 205, "strings": strings,
            "source_entries": evidence, "unresolved_glyph_bytes": sorted(unresolved),
            "source_executable_executed": False,
        }
        if locale == "ru" and russian is not None:
            output[locale]["duplicate_english_slot_records"] = [table2["record_index"] for table2 in tables
                if table2["name"] == "English" and table2["raw_strings"] == russian["raw_strings"]]
    return output
