# Original languages and local language packs

The language importer accepts locally supplied resources. It does not download
the game, run an original executable or installer, synthesize speech, or put
original language assets in this repository. UI language and recorded voice
language are separate settings.

## Examined original recordings

The recovered Windows PC discs provide the following sixteen distinct language
assignments. Each has all seven authored story-movie cues. The ITE logo is an
additional shared cue. Assignment uses the disc's full **Joliet filename**, the
original type-8001 movie filename slot, and the actual media data. A country or
download-page language icon is insufficient evidence.

| Locale | Language | Movie source edition | Original filename suffix | Native text source |
| --- | --- | --- | --- | --- |
| `da` | Dansk | Northern Europe | `DAN` | Central table19 |
| `sv` | Svenska | Northern Europe | `SWE` | Central table20 |
| `no` | Norsk | Northern Europe | `NOR` | Central table21 |
| `fi` | Suomi | Northern Europe | `FIN` | Central table22 |
| `en` | English | Northern Europe | `ENG` | Central table23 |
| `fr` | Français | Western Europe | `FRE` | Central table24 |
| `es` | Español | Western Europe | `SPA` | Central table25 |
| `it` | Italiano | Western Europe | `ITA` | Central table26 |
| `pt-PT` | Português (Portugal) | Western Europe | `POR` | Central table27 |
| `nl` | Nederlands | Western Europe | `DUT` | Central table28 |
| `de` | Deutsch | Western Europe | `GER` | Central table29 |
| `cs` | Čeština | Central Europe | `CZE` | Central table30 |
| `hu` | Magyar | Central Europe | `HUN` | Central table31 |
| `sk` | Slovenčina | Central Europe | `SLO` | Central table32 |
| `pl` | Polski | Poland | `POL` | Polish table30 |
| `ru` | Русский | Russia | `RUS` | Russian table33 |

`no` follows the source's “Norwegian” identity; the importer does not invent a
more specific written-language identity. The text and movie source editions do
not need to match: all source provenance remains per resource.

The primary archival entry points are the
[Windows edition collection](https://www.myabandonware.com/game/hugo-black-diamond-fever-qxf),
the [Polish disc archive](https://archive.org/details/hugo-goraczka-czarnych-diamentow-poland),
and the [Israeli disc archive](https://archive.org/details/Hugo_Black_Diamond_Fever_Israel).
A [contemporary Danish library review](https://bibliotek.dk/materiale/hugo-black-diamond-fever_kim-krogh/work-of:870970-basis:23708205)
specifically describes Danish speech in the PC film sequences and nonverbal
Hugo sounds during play. The underlying disc files, not this review, determine
the recovered resource mappings.

### Labels that did not establish additional recordings

- The downloaded package labelled Brazilian Portuguese contains seven story
  Bink files that are **byte-for-byte identical** to the Western `POR` files.
  Its resource container is also the same. It does not establish a separate
  `pt-BR` voice or native text pack.
- The examined Israeli disc contains `ENG` movies and English launcher text.
  Its archive's `heb` metadata does not establish Hebrew speech.
- A [collector's Argentine PC archive](https://sites.google.com/view/ajugarconhugopc/juegos/hugo-el-diamante-negro)
  states that the local release retained Spain's recording. It does not supply
  an additional Argentine Spanish recording.
- A [Turkish collector discussion](https://forum.donanimhaber.com/hugo-oyunlari-turkce-dublaj-resmi-yamalar--147896407)
  documents other dubbed Hugo games. Search matches for Black Diamond Fever 2/3
  refer to mobile games; a Turkish recording of this Windows title has not been
  recovered.

This describes accessible editions actually examined. It is not proof that no
other historical localization ever existed. Future local packs can use further
BCP47-style locale IDs without a source-code change to the importer.

### Container provenance

| Resource container | Bytes | SHA-256 |
| --- | ---: | --- |
| Russian | 42,946,560 | `fac39256dfdeedc4b19e07c171048e8c4e72a4fbe37cb4a8b8791239972aaa58` |
| Central Europe | 42,944,512 | `56a6455ce2ef5c2fb66a0deb607322c1cbb68dc4b0a009b50d5572ecb7b0ede5` |
| Northern Europe | 42,936,320 | `bc6152aedf1c631a1550d33208aed9f14d27569cf6c3d7d0d92832a629da0fb0` |
| Poland | 42,940,416 | `9ded893ec3df93925d56a63deec5d7a137f868b303198ee43b137dc19a06da41` |
| Western Europe; downloaded Brazilian and Israeli resources | 42,944,512 | `f63291730ebe1b07b5d8c140919e2e5f6c69a2afee0166d877b1626facac3e99` |

The seven examined editions have identical payloads for all 355 WAV source IDs.
The language importer therefore writes no duplicate copies of those sounds.
Decoded mesh IDs, vertices, UVs, faces, colors, animation timelines and known
material fields also agree across the 2800 meshes / 14243 parts. This comparison
does not declare unexplained record bytes equivalent: two unresolved material
reference bytes vary and remain separately recorded in the private audit.

Northern and Polish containers were extracted with the open-source static
[REWise](https://codeberg.org/CYBERDEV/REWise) reader, version 0.4.0, commit
`9d267fc1b305ec452b3e4edc106b73beffe8ee1b`. The installers were data inputs to
that reader; their executable code was never run.

## Movie identity and conversion

| Canonical cue | Original scene group | Movie stem |
| --- | ---: | --- |
| `logo` | 1 | `ITEMedia` |
| `intro_a` | 2 | `Cutsc01a` |
| `intro_b` | 5 | `Cutsc01b` |
| `plan_on_track` | 26 | `Cutsc02` |
| `more_power_1` | 45 | `Cutsc03` |
| `more_power_2` | 54 | `Cutsc04` |
| `lost_juice` | 68 | `Cutsc05` |
| `outro` | 78 | `Cutsc06` |

Each is record0/type8001 in its scene. The filename pointer is a record-relative
`u32` at `+0x08 + 4 * language_index`. Static Russian EXE evidence is the
type8001 constructor dispatch at `0x00420214` to `0x004251f0`, followed by the
indexed filename load and relocation at `0x004252d9`–`0x004252df`.

ISO9660 short names can erase the language suffix and assign misleading numeric
aliases. For example, the Northern short-name ordering is alphabetical by
suffix, while the native language-index order is Danish, Swedish, Norwegian,
Finnish, English. The private recovery matches long and short names by the
disc extent and file size; the import specification pins the resulting files
by SHA-256.

The importer converts each complete Bink cue to Ogg Theora/Vorbis, retaining
its own video variant, source dimensions and frame rate. It does not replace
all languages' pictures with the Russian video: decoded frames differ between
language versions even where duration and frame count agree. Default encoding
is Theora quality 8 and Vorbis quality 5. This is a playback conversion, not a
claim of lossless Bink re-encoding or increased cinematic resolution.

Exactly identical source-file/audio-track pairs share one converted file.
Different Bink files remain independent even if their names or sizes resemble
one another. The initial full import contains 128 locale/cue mappings and 101
distinct source Bink files, totalling 1,043,698,348 source bytes.

## Native text decoder

`tools/hugo_assets/native_text.py` exports 205 indexed Unicode strings per
language. Empty strings retain their original IDs. Original spelling and
untranslated source entries are preserved.

The later type6006 header is 16 bytes: the language-name pointer is at `+4`,
and `u16@12`/`u16@14` give the offset table and string count. The older Northern
header is 12 bytes, with those `u16` fields at `+8`/`+10` and no name. Its locale
is recognized only when **all 205 length-prefixed raw strings** match the
fingerprint of a named table. Unknown old tables are rejected, not assigned
by a guessed ordinal. Every string pointer and NUL terminator is bounded by
the record.

The original type2002 glyph artwork establishes the Central European, Polish
and Russian byte-to-Unicode maps. These are not interchangeable Windows
codepages. Source bytes, source offsets and decoding policy accompany the
Unicode text. Unknown sprite/glyph positions remain explicit and prevent an
import that would silently invent text.

In the Russian container the table named English contains the same 205 raw
Russian strings as the explicitly named Russian table. The decoder selects
the named Russian record 33 and does not advertise that duplicate as English.
Some language-name entries retain unchanged Latin bytes despite the replaced
Russian or Polish font artwork; a combined reference hash identifies those
entries, preserves the intended Latin names and records the conflicting atlas
rendering separately. The separate unnamed 208-entry credits table is excluded
from the language list.

## Import command and specification

```sh
python tools/import_languages.py --language-spec .work/languages.json --jobs 2
```

Default output is `game/assets/localization/`, separate from
`game/assets/generated/`. Reimporting the campaign cannot remove the installed
language packs. The directory and its staging/lock files are ignored by Git.
`--output` selects another local destination. `--replace` explicitly replaces
the complete installed locale set; otherwise new locales and cue overrides
merge with existing ones.

Example specification for a **partial** local English pack:

```json
{
  "schema_version": 1,
  "default_voice_locale": "en",
  "voices": {
    "en": {
      "native_name": "English",
      "source_edition": "Northern Europe",
      "source_container": {"source": "../original/english/HUGO4.CD"},
      "language_index": 4,
      "movies": {
        "intro_b": {
          "source": "../original/english/CUTSC01B_ENG.BIK",
          "source_filename": "Cutsc01b_ENG.bik",
          "audio_track": 0
        }
      },
      "audio_overrides": {}
    }
  },
  "native_texts": {
    "en": {"source": "../original/english/HUGO4.CD"}
  }
}
```

Source paths are local paths relative to the specification file, or explicit
absolute paths. A `source_sha256` field on each input pins its expected bytes;
the importer always computes and records actual hashes. The examined recovery
specifications pin every container and movie. An optional `record_index` on a
native text input additionally checks the selected source record.

When `source_container` is supplied for a voice, `language_index` is required
and every declared original filename is checked against the native movie
record. A future locally supplied voice pack may omit that container and
provide explicit movie mappings. Its language is an author-supplied declaration;
the importer does not infer it by listening or pretend to have source-record
proof. An optional `source_container_sha256` preserves earlier provenance when
restoring a compact recovery bundle without the full original container.

An already recovered text resource can be restored without a full CD image:

```json
{
  "schema_version": 1,
  "native_texts": {
    "ru": {
      "format": "native_text_json",
      "source": "texts/ru.json",
      "source_sha256": "<SHA-256 of this local JSON file>"
    }
  }
}
```

Such a resource must contain its locale, exactly 205 strings, original container
hash, source record index, encoding and unresolved-glyph list. Its original
provenance is retained, and the new import explicitly records that the input
was previously decoded JSON. No text or voice is fabricated for a missing
locale. Nonempty `audio_overrides` are reserved for a later importer extension;
schema 1 uses the common native WAV resources.

## Runtime manifest contract

`localization_manifest.json` uses `schema_version: 1`, a
`default_voice_locale` (Russian in the recovered bundle), a **flat** `voices`
object keyed by locale, and `native_texts` keyed by locale. There is no nested
`voices.locales` object.

Each voice has `native_name`, `source_edition`, `source_sha256`, `movies`, empty
`audio_overrides`, provenance/verification fields, and explicit story-movie
coverage (`required`, `present`, `missing`, `complete`). Each movie descriptor
contains a path relative to `res://assets/localization/`, output SHA-256 and
size, source filename/hash, original dimensions/timing, selected audio-track
index, and native record evidence when available. Paths never use `..` or
absolute/provider URLs.

`native_texts[locale]` points to a resource with `strings[0..204]`, plus source
hash, record index and encoding. The authored modern UI catalog is separate at
`res://localization/ui_catalog.json`; extraction does not overwrite that catalog.

The importer validates every input before starting conversion. It writes into
a sibling staging directory and promotes the complete result with rollback of
the old directory on promotion failure. A conversion failure leaves the prior
pack intact. A verified existing movie can be reused; corrupt installed hashes
stop the import for review instead of becoming trusted cache data. A local
lock prevents two writers from publishing the same pack concurrently.

### Portable delivery

The release can place these resources in the separate `Hugo_Languages.pck`
beside the game executable. In the automatic-launch distribution, place it in
the launcher root beside `Launch-Hugo.cmd`; the shared language pack is not
duplicated into every isolated renderer directory. Runtime mounting adds its
resources without overriding existing project resources. A missing language
pack does not prevent launch: the base game's Russian movie resources remain
available.

Godot imports `.ogv` resources normally. The project's export include filter
covers the JSON resources and manifests; final packaged-resource verification
checks the sidecar language manifest and referenced movie paths. Core game
export excludes `assets/localization/*` when the separate language PCK is built.

## Validation scope

Synthetic tests cover source hashes, media signatures, missing/wrong audio
tracks, path traversal, retained locales, explicit replacement, exact-source
deduplication, failed-conversion rollback, native string boundaries, both
header layouts, glyph maps, and the Russian duplicate. Real-data audits compare
the decoded 205 strings with the private recovery, verify the actual media
streams and retain their source/output hashes. These checks do not replace
listening to every line with a native speaker, nor do they establish ownership
of unexamined historical editions.

## Authored UI and live language changes

`game/localization/ui_catalog.json` contains 111 modern UI keys in each of the
sixteen supported text locales (1,776 authored translations). It covers the
home menu, audio/difficulty/language controls, graphics and display settings,
quality presets, new-game and display-confirmation dialogs, input help, HUD,
checkpoint/collection notices, pause/game-over/completion screens, save errors,
loading captions, cinematic hints and voice-fallback captions. This public
catalog contains authored interface text; it does not contain the complete
extracted 205-string original tables.

The optional native tables supply the original brand and chapter captions.
The eight chapter groups6/17/27/36/46/55/59/69 map to original text
IDs51/55/56/57/58/59/60/61. When a table is absent, invalid, or its selected slot
is empty, the authored locale supplies the caption. Original credit names and
source credit content remain intact; the surrounding dialog is translated.

Version2 saves gain independent `settings.text_locale` and
`settings.voice_locale` values. Existing saves without those fields retain
Russian defaults. Changing text never changes the requested voice, and changing
voice never changes text. The voice picker lists installed original packs;
an unavailable saved request is retained for the voice resolver to handle
explicitly per cue. A new valid voice-pack locale can therefore be selected
without adding a matching text catalog. The application’s stable internal name
and save directory remain unchanged when its visible window title is translated.

`NativeLocalization` loads the authored catalog once and caches a validated
native205 table on first use of that locale. A supplied table SHA-256 is
checked once before JSON parsing; an invalid or mismatched checksum caches an
empty table and falls back to the authored UI. Repeated text lookups and repeated
requests for the current locale perform no JSON parsing or filesystem reads.
`events().language_changed` refreshes existing controls. Bindings retain weak
references to dialogs and controls, and refresh neither rebuilds the menu nor
resets focus, scroll position, a pending display draft, the fifteen-second
confirmation timer, an active toast’s lifetime, pause state, or completion
statistics. Native audio and cinematic timing remain governed by the source
cues; changing text does not restart playback.

The engine’s bundled Open Sans font covers the authored Cyrillic and Latin
Extended characters. A cached system-symbol fallback handles the existing HUD
heart and diamond symbols. The localization regression checks the complete
catalog’s actual font coverage on its host, including `♥♡◇◆`, placeholder
parity, independent save round trips, legacy migration and live UI behavior.
The HUD separately caches collected/total counts, whole elapsed seconds and
vitals, so repeated unchanged simulation updates do not format or assign the
same strings every frame.

```sh
godot --headless --path game --script res://tests/localization_test.gd
godot --headless --path game --script res://tests/graphics_settings_test.gd
```

The localization regression works with and without the private language pack.
A full imported pack additionally validates every installed native text table
and the live original chapter-title override. GPU screenshots and video/audio
playback checks are separate from these headless tests.
