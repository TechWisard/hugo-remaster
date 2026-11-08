# Original resource format and import limits

This document describes the parts of the **Windows Hugo: Black Diamond Fever / «Кузя: Алмазная лихорадка»** resource file that were established by examining actual bytes. The repository contains reader code and generated synthetic tests. It does not contain the original resource file, game executables, extracted textures, audio, or meshes.

The importer reads a local `HUGO4.CD`, validates the supported container and geometry, and exports all eight playable scenes, action graphs, animations, gameplay metadata and original audio. Three small GLB previews remain available as a separate inspection profile. It neither downloads the game nor executes a game binary. The exported geometry retains the original low-poly data.

## Run the importer

Python 3.10 or newer, NumPy and Pillow are required:

```bash
python -m pip install -r tools/requirements.txt
python tools/import_original.py /path/to/HUGO4.CD
```

The project root defaults to the repository containing the script. An explicit destination is supported:

```bash
python tools/import_original.py /path/to/HUGO4.CD --project-root /path/to/hugo-remaster
```

The input must be the MDIC resource file itself. ISO, ZIP, setup executables, and PS1 images are not supported input wrappers in this version. The importer does not change the source file.

### Outputs

| File | Contents |
|---|---|
| `game/assets/generated/hugo.glb` | Body and head in the first recovered local pose: 574 vertices, 596 triangles, 17 submeshes |
| `game/assets/generated/palm.glb` | Palm: 160 vertices, 80 triangles, 4 submeshes |
| `game/assets/generated/hugo_body.glb` | Body: 360 vertices, 376 triangles; first sample plus 3 morph targets |
| `game/assets/generated/asset_manifest.json` | Input and output SHA-256 hashes, checked counts, source record references, coordinate/material conventions, fidelity limits |
| `game/assets/generated/campaign.json`, `levels/` | Eight reconstructed scene graphs, all action meshes, collision data, transforms and source IDs |
| `game/assets/generated/animation_manifest.json`, `animations/` | Fourteen Hugo actions and 27 special surface-death graphs |
| `game/assets/generated/material_animation_manifest.json`, `materials/textures/` | Native texture sequences, RGB samples and UV samples, keyed by source mesh and part |
| `game/assets/generated/gameplay_manifest.json`, `audio/` | Source state machines, events, player parameters, speakers and original WAV bytes |
| `game/assets/generated/effects/` | Original particle sprite frames; parameters are included in level manifests |
| `game/assets/generated/media_manifest.json`, `media/` | Optional locally converted movies, supplied music tracks and credits |

Initial textures are embedded in the GLBs; material-sequence frames are also exported as lossless PNGs. The small `hugo_body.glb` preview still exposes named stored samples without autoplay. The campaign animation layer decodes native Q12 timelines, transform tracks and state timing; see [animation.md](animation.md).

Intermediate extraction and reports are under `.work/imports/<source-sha256>/`:

- `extracted/textures/`, `extracted/audio/`, `extracted/scene_data/` hold locally derived files.
- `extracted/chunks.json`, `groups.json`, and `summary.json` inventory the container.
- `scene_catalog.json` describes scene descriptors and object counts.
- `mesh_audit.json` and `mesh_inventory.json` record geometry validation.
- `hugo_assembly_evidence.json` records the actor links used to place the head and body.
- `outputs/` holds the complete export set before publication.

These directories are local generated data and must stay out of version control. Keep the original source outside `.work/imports/` and `game/assets/generated/`, since those are managed destinations.

### Publication and errors

All parsing, extraction, GLB construction, and verification happen before the existing generated directory is replaced. PNG pixels are compared with their original RGBA payloads; WAV and scene bytes are hashed after extraction. GLB buffers, indices, morph targets, and embedded PNGs are independently read before publication.

Publication moves a complete staged directory into place. If the promotion raises an error after the old directory was moved, the old directory is restored. There is no partially generated mixture of old and new assets. Portable replacement of a non-empty directory uses two individually atomic renames, so concurrent readers can briefly observe the directory as absent. This is not a claim of power-failure transactionality.

A `.work/import.lock` prevents simultaneous publication by two importer processes. An interrupted process can leave its lock and staging directory behind. The importer reports that condition instead of silently taking the lock. On a normal failure it prints a specific error and exits with status 2; `--debug` includes a traceback. Validation uses explicit exceptions and remains active under `python -O`.

## Examined inputs

The whole-file hashes below identify the examined data; they are not download links or license statements.

| Resource | Bytes | SHA-256 |
|---|---:|---|
| Russian Windows edition | 42,946,560 | `fac39256dfdeedc4b19e07c171048e8c4e72a4fbe37cb4a8b8791239972aaa58` |
| Portuguese Windows edition | 42,944,512 | `f63291730ebe1b07b5d8c140919e2e5f6c69a2afee0166d877b1626facac3e99` |

An unrecognized file hash is not automatically rejected, but it must pass all structural checks and the specific inspected scene-6 export layout. Another title with an MDIC-like file is not sufficient. The profile requires the expected body/head/palm counts and the observed actor-reference links.

## 1. MDIC container

All multi-byte integers described here are **little endian**. Every chunk begins on a **2,048-byte boundary**. Its payload has an explicit byte length; alignment padding is outside the payload.

| Offset from chunk start | Type | Meaning |
|---|---|---|
| `0x00` | 4 bytes | ASCII `MDIC` |
| `0x04` | uint32 | Header length: 16 or 24 |
| `0x08` | uint32 | Payload length, excluding header and alignment padding |
| `0x0c` | uint32 | Chunk kind |
| `0x10` | uint32 | Auxiliary field 0, only in a 24-byte header |
| `0x14` | uint32 | Auxiliary field 1, only in a 24-byte header |

The next chunk is at:

```python
end = chunk_offset + header_length + payload_length
next_offset = (end + 2047) // 2048 * 2048
```

Observed kinds:

| Kind | Header/payload | Meaning of auxiliary fields |
|---:|---|---|
| 1 | 24-byte header, empty payload | Group span in bytes; number of following member chunks |
| 2 | 24-byte header, RGBA pixels | Texture resource ID; width in low 16 bits and height in high 16 bits |
| 4 | Scene/object payload | Observed files use a 16-byte outer header |
| 5 | 24-byte header, RIFF/WAVE payload | Audio resource ID; the second auxiliary field is preserved without assigning new semantics |

A group starts at its kind-1 header and extends to the next group header, or the end of the file. Its declared span includes its header and all chunk padding. Its member count excludes the group header. The importer rejects span/count mismatches, assets before a group, duplicate texture IDs inside a group, unsupported chunk kinds, missing signatures, and out-of-bounds lengths.

Both examined versions contain **2,107 chunks** in **81 groups**: 81 group headers, 1,590 texture chunks, 81 scene chunks, and 355 audio chunks.

### Images and audio

Texture bytes are row-major **RGBA8**; payload length must be exactly `width * height * 4`. The importer does not swap channels. PNG extraction is lossless and checked against these bytes after decoding the PNG again.

Audio is an embedded RIFF/WAVE file, copied byte-for-byte. The reader checks the RIFF size, supported PCM parameters, and the number of available frame bytes. Audio is extracted for research but is not part of the three preview GLBs.

The first implementation limits a source file to 256 MiB, an individual texture to 4,194,304 pixels, a scene directory to 65,535 records, and a mesh to 2,000,000 decoded vertices across its samples. These bounds are checked before large allocations. The observed inputs are far below these limits.

## 2. Scene and object directory

Each kind-4 payload starts with `01 01 01 01 02 02 02 02`.

| Payload offset | Type | Meaning |
|---|---|---|
| `0x08` | uint16 | Category: 2 global, 3 main scene, 4 subscene in the examined files |
| `0x0a` | uint16 | Outer group number plus one |
| `0x0c` | uint32 | Offset of the object directory header |
| directory + 0 | uint32 | Marker `0x03030303` |
| directory + 4 | uint32 | Object record count |
| directory + 8 | uint32 | Offset of the object descriptor array |

Each descriptor consists of three uint32 values: **record offset, class/type ID, fixed header size**. These offsets are relative to the scene payload. Whole record lengths are determined by the next record offset, or by the payload end. The importer checks ordering, header bounds, and overlap with the directory.

Category-3 payloads also contain a child count at offset 28 and an array at offset 32. Each array item matches the corresponding following subscene payload size plus its outer MDIC header size. These relationships are checked.

Type-4000 records in global group 0 describe scenes. Their six initial uint32 fields include relative pointers to two NUL-terminated ASCII strings and an absolute container group offset. These references must point to real group starts. Their names are catalogued locally; the importer does not use strings from the game as output paths.

There are **13,228 object records in RU** and **13,227 in PT**. A class ID by itself does not establish a semantic name for an object.

## 3. Type-2001 geometry

The fixed header is 104 bytes. Geometry-internal pointers are **relative to the start of this object record**, not the file or scene.

| Offset | Type | Established interpretation |
|---|---|---|
| 0 | uint32 | 2001 |
| 4 | uint32 | `0x01010101` |
| 32 | uint32 | `0x02020202` |
| 38 | uint16 | Submesh count |
| 40 | uint32 | Vertex-animation header pointer; observed value 104 |
| 44 | uint32 | Submesh pointer-table pointer; observed value 112 |
| 48 | uint32 | Native timeline pointer, following geometry |
| 52 | uint32 | Native collision quadtree pointer, or zero; see [scene_graph.md](scene_graph.md) |
| 72 | 3 float32 | Bounding-box minimum |
| 84 | 3 float32 | Bounding-box maximum |
| 104 | uint16 | Number of stored vertex samples per submesh |
| 106 | uint16 | Native timeline element count |
| 108 | uint32 | Native timeline loop flag, validated by the animation decoder |
| 112 | uint32 array | Submesh offsets |

The header also has center/radius-like fields; the exporter does not need to assume their meaning. All decoded coordinates in every stored sample must fit the recorded bounding box within 1.001 source units, allowing the source float-to-int16 rounding.

### Submesh layout

| Submesh-relative offset | Type | Meaning |
|---|---|---|
| 0 | uint16 | 1 without a texture-reference block, 3 with one |
| 2 | uint16 | Observed values 0 and 1; precise meaning unconfirmed |
| 4 | uint32 | Native rendering flags: decoded blend/culling/color-animation fields, with remaining bits preserved |
| 8 | uint16 | Vertex count N |
| 10 | uint16 | Triangle count T |
| 12 | uint32 | Index-buffer pointer |
| 16 | uint32 | Vertex-buffer pointer |
| 32 | uint32 | Vertex-color pointer |
| 36 | uint32 | Texture-reference pointer, present only for kind 3 |

The fixed submesh header is **36 bytes for kind 1**, **40 bytes for kind 3**. Its vertex buffer follows immediately. Each vertex occupies **8 bytes**:

```text
int16 x, int16 y, int16 z, uint8 u, uint8 v
```

The last two bytes are interpreted as UV only for textured geometry. Each sample contains N vertices, and samples are stored consecutively. Every one of the 14,243 examined submeshes satisfies:

```python
index_buffer_offset - vertex_buffer_offset == N * 8 * stored_sample_count
```

This establishes stored vertex/morph animation, rather than merely finding plausible coordinate arrays.

### Triangles

A triangle is packed into one uint32:

```python
i0 = word & 1023
i1 = (word >> 10) & 1023
i2 = (word >> 20) & 1023
```

The high two bits are zero in all examined triangles. All indices must be smaller than N. The index buffer is followed immediately by vertex colors:

```python
color_buffer_offset == index_buffer_offset + T * 4
```

There are three triangles with repeated indices in the original data. They are preserved; they are not out-of-range indices.

### Colors and material references

Color records occupy four bytes per vertex. RGB are the first three bytes; the fourth byte is **not vertex alpha**. The PC vertex writers generate alpha 255 for textured surfaces and 128 for untextured surfaces. Some submeshes contain multiple color arrays. The base GLB contains the first array; the material-animation manifest preserves every authored RGB sample for runtime playback. See [Native PC mesh materials](mesh_materials.md) for instruction addresses and the rendering-state evidence.

A texture-reference block starts with uint16 zero, uint16 reference count, and a uint32 pointer to the reference-offset array. Each reference is eight bytes: uint32 resource ID plus four additional bytes. The final two bytes match texture width and height, with **zero representing 256**. The first two additional bytes remain uninterpreted.

References resolve in the last preceding resource group containing texture chunks, falling back to global group 0. Every examined reference resolves, and every referenced dimension matches its RGBA texture. Multi-reference blocks are ordered native texture sequences. Repeated texture IDs remain separate sequence slots; only identical PNG storage is deduplicated.

### Material-animation export contract

`tools/hugo_assets/material_animation.py::export_material_animations(catalog, output)`
writes `material_animation_manifest.json` and `materials/textures/*.png` into a
fresh importer staging directory. Its `materials` map is keyed by
`g<group>_r<record>_p<part>` with zero-padded numeric components, for example
`g070_r0044_p000`. Every entry contains native timeline words and looping,
ordered `texture_sequence` frame descriptors with relative PNG paths,
`color_samples` as byte RGB triples, `uv_samples` as byte pairs, vertex count,
generated alpha, and explicit channel-animation flags. Paths are relative to
the generated root. Container, source mesh, image payload and encoded PNG
hashes retain provenance.

The examined resource exports **483 animated parts**: 285 texture sequences,
190 RGB-animated parts and 8 UV-animated parts. Their 2,775 texture slots use
102 distinct PNG payload/dimension combinations. Every PNG is decoded again
and checked byte-for-byte against its source RGBA image before publication.

Animated source parts remain separate surfaces during material batching.
Their names include `__hugo_anim_<key>` before the final blend selector.
RGB/UV-animated surfaces also carry `TEXCOORD_1 = [source_vertex_index,
source_part_index]`; this is an import-mapping channel, not a visual UV set.
The runtime recovers the indices from Godot's UV2 array after any importer
vertex reordering. The per-mesh limit of 128 surfaces and exact triangle/
morph-attribute checks remain enforced. Texture-only parts need independent
material identity but no vertex-array updates.

Texture frame selection uses the raw source visual phase. RGB and UV use the
native mesh timeline; interpolated RGB channels truncate to bytes, whereas UV
interpolation stays fractional and uses the float32 `1/255` constant. These
data require the runtime sampler; they do not add a guessed glTF animation FPS.

## 4. Measured geometry audit

The following counts include repeated records across scenes unless explicitly described as unique.

| Measurement | RU result |
|---|---:|
| Mesh records | 2,800 |
| Submeshes | 14,243 |
| Vertices in first samples | 316,498 |
| Vertices across all stored samples | 1,257,015 |
| Triangles | 270,408 |
| Valid submesh vertex-buffer sizes | 14,243 / 14,243 |
| Valid submesh index buffers | 14,243 / 14,243 |
| Mesh bounds containing all stored samples | 2,800 / 2,800 |
| Resolved texture references, matching dimensions | 14,476 / 14,476 |
| Mesh records with multiple vertex samples | 919 |
| Mesh records whose coordinates actually change | 894 |
| Submeshes with multiple color samples | 190 |
| Unique whole mesh records by byte SHA-256 | 1,116 |
| Unique geometry + color + UV buffer hashes | 557 |

PT has the same geometry/count results, with 1,103 unique whole mesh-record hashes. Whole-record hashes also include metadata. The 557 buffer hashes do **not** mean 557 semantic game objects: they exclude material identity, placement, timeline interpretation, and actor role.

## 5. The specific export profile

The profile uses scene group 6:

| Record | Interpretation verified by geometry/appearance | Vertices | Triangles | Submeshes | Stored samples |
|---:|---|---:|---:|---:|---:|
| 18 | Hugo body | 360 | 376 | 10 | 4 |
| 121 | Hugo head | 214 | 220 | 7 | 1 |
| 1 | Palm | 160 | 80 | 4 | 1 |

Head placement is derived from source references rather than a visually guessed offset:

- Type-10000 record 183 contains a node linking transform 21 to body record 18.
- The same owner links transform 20 to type-8003 object 158.
- Object 158 links transform 122 to head record 121.

The source node pattern begins with marker `0x03030303`, and the relevant references carry `0x80000000 | record_index`. The importer checks the specific patterns before exporting. It reads the first transform's three float32 translation values at offset 4 and its 3×3 matrix at offset 16. The selected matrices are rotations, with the inner head transform effectively identity. These checks establish this local pose; they do not implement the entire native scene graph.

## 6. Preview coordinate and material conventions

**Axes and scale.** The GLBs use `(x, z, -y) * 0.01`, converting the observed Z-up coordinates to Y-up. The axis change has determinant +1, so it does not reverse triangle order. The scale is a fixed presentation choice, not a recovered physical unit. `hugo.glb` includes local body/head translations; `hugo_body.glb` retains the body's local origin. A scene/world transform is not applied.

**UV.** Textured UV bytes are multiplied by float32 **1/255**, matching the native GT3 writers (`0x412fd3`, `0x412fe7`, constant `0x43e964`). GLB V follows the image's top-to-bottom convention. Animated byte UVs interpolate before normalization, without wrapping the interpolation across a seam. The original renderer's exact texture edge-sampling rules remain a separate limit; the base GLB uses nearest filtering and clamp-to-edge.

**Brightness.** Ordinary mesh RGB is normalized by **255** for both textured and untextured surfaces. The Windows renderer uploads source texture RGB without a brightness boost, writes the stored diffuse RGB bytes, and uses `D3DTOP_MODULATE` (`0x40f3d2..0x40f3db`). Byte 128 therefore represents approximately half intensity in this PC path. Materials are unlit so the preview does not compound the source vertex colors with an invented light setup. Particle colors use a separate recovered path and retain their own normalization.

**Transparency.** The native mesh selector is `(source_flags >> 29) & 3`: 0 is source-alpha blending, 1 additive, 2 destination multiplied by inverse source RGB, and 3 opaque. Material `extras.native_render` preserves these states, generated vertex alpha, the native depth-write flag, and the alpha-test cutoff **8/255**. Opaque textured surfaces with non-opaque image pixels use glTF `MASK` at that cutoff. The three nonopaque modes use a `BLEND` fallback; additive and inverse-source-color equations require the Godot material adapter because core glTF does not express them. Names retain `__hugo_blend_<selector>` for importers that omit material extras. Batching includes the complete source flags word, so two surfaces with equal texture/fallback settings but different native blend states cannot merge. No black color key or brightness-based discard is introduced.

**Winding.** Source index order is retained. Materials remain double-sided for compatibility; the recovered native culling flag is preserved in metadata until the native camera/projection and Godot winding correspondence is checked. Full transparent sorting remains a separate rendering limit. See [Native PC mesh materials](mesh_materials.md) for the complete source proof.

**Normals.** No original normal buffer is claimed as recovered. No reconstructed skeleton or skin weights are exported. A target engine can generate geometric normals if needed, but the proof materials do not depend on them.

**Animation.** Timeline words use a high-16 sample index and low-12 Q12 fraction. Native transform tracks, state/action durations, distance-driven cycles, head motion and graph transitions are decoded by the campaign pipeline. The small preview profile remains static in a generic glTF viewer. Texture, RGB and UV playback uses the separate material-animation manifest and the actor's visual phase; these channels are not represented as position morph targets.

## Tests

Synthetic fixtures are constructed in Python from an original triangle, a four-pixel RGBA image, and a tiny PCM signal. No fixtures are copied from the game.

```bash
python -m unittest discover -s tests -p 'test_import*.py' -v
```

The tests cover lossless extraction, group span/count mismatches, truncation, image/WAV lengths, object pointers, malformed mesh samples, invalid triangle indices, non-finite bounds, neutral texture brightness, morph export, output rollback, lock ownership, and CLI failure under `python -O`.

An optional complete integration test runs only when a local source is explicitly supplied:

```bash
HUGO_BDF_SOURCE=/path/to/HUGO4.CD python -m unittest discover -s tests -p 'test_import_end_to_end.py' -v
```

That test checks output hashes/counts and confirms that the original file is unchanged. It does not download anything.
