# Native PC mesh materials

This describes the ordinary type-2001 mesh path in `HUGO4_PC.EXE`, not the
type-2002 sprite mode numbering. The executable was inspected statically;
the original program was not executed.

Source EXE SHA-256:
`bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3`.
All addresses below are virtual addresses in that executable. The decoder
is `tools/hugo_assets/mesh.py::decode_material_flags`.

## Blend selection

Each source submesh stores a 32-bit flags word at offset `+4`. Both the
untextured `C3DPSXSurfaceG3` path (`0x412C25`, `0x412C57`) and textured
`C3DPSXSurfaceGT3` path (`0x412E9B`–`0x412EA5`) select:

```python
blend_selector = (flags >> 29) & 3
```

The textured command queue receives this value unchanged at `0x411D10`.
At `0x411E5F`, selector 3 enters the opaque list; the other selectors enter
the depth-sorted transparent list. The untextured command path performs
the same separation. The draw pass `0x410919`–`0x410991` sets these states:

| Mesh selector | Source factor | Destination factor | RGB result | Z write |
| --- | --- | --- | --- | --- |
| 0 | `SRCALPHA` (5) | `INVSRCALPHA` (6) | `S * As + D * (1 - As)` | Off |
| 1 | `ONE` (2) | `ONE` (2) | `S + D` | Off |
| 2 | `ZERO` (1) | `INVSRCCOLOR` (4) | `D * (1 - S)` | Off |
| 3 | Blending disabled | Blending disabled | `S` | On |

`S` and `D` denote the source and existing framebuffer RGB values;
`As` is source alpha. Transparent state setup at `0x4108FA`–`0x410916`
sets `ALPHABLENDENABLE=1`, `ZWRITEENABLE=0`. Opaque setup at
`0x4107E9`–`0x410805` does the reverse.

The numeric factor names and equations are documented by Microsoft in
[D3DBLEND](https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3dblend).
The decoder obtains the selected values from the original executable;
the documentation identifies the API enum values.

This fixes a concrete visual defect: an additive image can have a completely
opaque alpha channel and a black background. Treating it as an opaque glTF
surface displays a black rectangle. Its original additive equation leaves
the destination unchanged where source RGB is zero. The inverse multiply
mode likewise leaves black source pixels unchanged. No brightness-based
discard or guessed black color key is needed.

The sprite path is different: `0x411063`–`0x411070` transforms a sprite's
serialized mode to `3 - mode`. Thus ordinary mesh selector 1 is additive,
whereas serialized sprite mode 1 means inverse-source multiplication.

## Alpha and texture modulation

The fourth byte of the stored vertex-color record is not vertex alpha.
The PC vertex writers construct alpha explicitly:

| Surface | Source instructions | Vertex alpha |
| --- | --- | --- |
| Untextured | `0x412B11`, OR `0xFFFF8000`, then two 8-bit shifts | `128 / 255` |
| Textured | `0x412FAB`, OR `0xFFFFFF00`, then two 8-bit shifts | `255 / 255` |

Both writers use the first three stored bytes as RGB. Their interpolated
paths construct the same alpha. Textured source alpha comes from the
texture stage; the default alpha operation selects texture alpha, or diffuse
alpha when no texture is bound. See Microsoft's
[texture stage states](https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3dtexturestagestatetype).

The renderer's final initialization at `0x40F3D2`–`0x40F3DB` sets stage 0
`COLOROP=4`, which is `MODULATE`, not `MODULATE2X`. The raw texture payload
passes through `CTextureReceiver` at `0x421FCE`–`0x421FED`; the upload loop
`0x411B20`–`0x411B9A` repacks channels to the selected pixel format without
brightness multiplication. Ordinary PC mesh vertex colors therefore use
`RGB / 255`, including textured surfaces. This replaces the earlier preview
assumption that byte 128 was neutral texture modulation. The corresponding
API operation is documented in
[D3DTEXTUREOP](https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3dtextureop).

The global alpha test at `0x40F385`–`0x40F3A6` enables alpha testing,
sets reference 8, and selects comparison 7 (`GREATEREQUAL`). Its normalized
cutoff is **8/255**, not 0.5. Both opaque cutout materials and transparent
shaders use this source threshold. The comparison enum is documented in
[D3DCMPFUNC](https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3dcmpfunc).

## Other flags and explicit limits

| Mask | Verified behavior |
| --- | --- |
| `0x01000000` | Disable culling; otherwise native `D3DCULL_CW` (`0x41327F`, `0x412BC7`) |
| `0x04000000` | Advance/interpolate the stored color sample along with the vertex sample (`0x412F0B`, `0x41295E`) |
| `0x90000000` | Skip the surface's native draw submission (`0x412C29`, `0x412DD8`) |

The remaining flag bits remain numeric metadata. The decoder does not
assign them speculative names. The preview/export pipeline retains its
double-sided compatibility policy; the source culling flag is reported
separately until the complete native camera/projection winding correspondence
is checked. Color, UV and texture animation are decoded separately below;
their clock is the owning visual's source phase.

glTF does not define additive or inverse-source blend modes. The export
therefore retains `native_render` metadata and a stable blend selector in
the material name; the Godot adapter supplies the corresponding shaders.
Material batching must include the source render flags and decoded render
settings in its identity. Otherwise two surfaces sharing the same image
would be merged even when they use different native blending.

This recovers the blend equations, not a claim of byte-identical output
from a 2001 Direct3D driver. Modern color conversion, depth sorting,
sampling, clipping and framebuffer precision can still differ.

## Material animation

The decoder exports `material_animation_manifest(mesh, part)` in original
vertex order. `sample_material_animation(info, phase)` is an independent
JSON-safe Python reference for the Godot adapter. It reuses the already
recovered Q12 mesh timeline from `animation.py`; it does not assign an
invented frame rate.

### Texture sequences use the visual phase directly

The textured submesh's `+36` pointer refers to its texture sequence.
At `0x412E05`–`0x412E85`, the native renderer obtains the count, computes
`trunc(visual_phase * texture_count)`, then takes its integer remainder by
the count. Valid visual phases are in `[0,1]`, so this is a floor operation.
The texture frame is independent of the Q12 vertex-sample remapping.

The input phase is float32, but the multiplication remains on the x87
stack until `_ftol`. Prematurely rounding the product to float32 can select
the next image early: `float32(5/6) * 6` is slightly below five and selects
frame 4. At the exact phase 1, the remainder selects frame 0, including
when the mesh vertex timeline itself is non-looping.

Sequence order and repeated references are retained. Sixty-one authored
sequences contain repeated image IDs; deduplicating those slots would
change their timing. Getaway `g070/r0044` and `g070/r0045`, for example,
each have six texture slots. Image files may be shared; sequence slots may
not be collapsed.

### RGB follows the native vertex timeline

The mesh timeline yields two stored vertex samples and an interpolation
weight. The renderer stores this weight as float32 at `0x4143AB` before
passing it to the surface writer.

With submesh flag `0x04000000`, the color pointer advances by
`sample_index * vertex_count * 4`; the color count equals the stored
vertex-sample count. Without the flag, the writer always uses the first
color array. Both relationships hold for all 14,243 inspected source
submeshes and are enforced by the parser.

The writer linearly interpolates RGB byte values, then converts each
channel to an integer with `_ftol`. Its implementation at `0x431478`
temporarily sets the x87 rounding mode to truncate toward zero. The fourth
stored color byte is ignored; alpha remains the generated value described
above. RGB bytes are normalized by 255 after this conversion.

There is a small but reproducible precision detail. Red stays on the x87
stack until conversion. Green and blue are saved to float32 temporaries
at `0x413121` and `0x413165` first; the untextured path does the same at
`0x412ABE` and `0x412B02`. Thus interpolating `(109,109,109)` to
`(29,29,29)` with `float32(0.15)` produces `(96,97,97)`. The reference
sampler retains this detail instead of replacing byte interpolation with
unquantized floating-point colors.

### UV follows the native vertex timeline

UV occupies bytes 6 and 7 of each eight-byte stored vertex. The native
textured writer interpolates the selected samples directly at
`0x41319B`–`0x413217`. It does not select a shorter route across the texture
wrap seam and does not round UV to integer bytes.

The divisor is **255**, not 256: the multiplication uses the verified
float32 value `0.003921568859368563` at `0x43E964`, then stores the result
as float32. A stored UV byte 255 therefore maps to the endpoint 1. This
also applies to the initial static UV export.

All eight source parts with changing UV happen to set `0x08000000`.
The PC draw writer does not gate this interpolation on that bit, so the
decoder uses the actual stored samples and retains the bit as numeric
metadata. It does not invent an additional runtime switch.

### Runtime/export contract

Animated entries are keyed by `g###_r####_p###` and retain:

- `vertex_count`, `stored_samples`, `timeline_words`, `timeline_loop`;
- `texture_sequence` in original order;
- `color_samples` as raw RGB byte arrays, one static or all animated samples;
- `uv_samples` as raw UV byte arrays, one identical sample or all changing samples;
- `source_color_animation`, `animate_uv`, `animate_texture`;
- `vertex_alpha`, `color_divisor=255`, `uv_divisor=255`.

The runtime adapter must own its mutable mesh/material state. Actors may
share a source resource while playing different phases. Batching must
distinguish texture sequences, and vertex attributes must retain their
source vertex/part identity through glTF import; the auxiliary `UV2`
channel carries that identity. A mesh's vertex morph, RGB, UV and texture
updates all consume the same owning visual phase.

## Source audit

Both inspected RU and PT containers produce the same material counts
across **2,800 mesh records / 14,243 submeshes**:

| Blend mode | Submeshes |
| --- | ---: |
| Opaque | 13,177 |
| Alpha | 539 |
| Inverse-source multiplication | 478 |
| Additive | 49 |

No authored submesh in either container sets either draw-skip bit.
Concrete Getaway examples include `g070/r0044/part0` (`0x23000000`, texture
334, additive) and `g070/r0045/part0` (`0x43000000`, texture 328,
inverse-source multiplication). These examples require different material
states even when their image alpha is fully opaque.

The synthetic regression `tests/test_materials.py` checks all four source
selectors, generated alpha, the shared source alpha cutoff, culling and
color-animation flags, preservation of uninterpreted bits, invalid flag-word
rejection, repeated texture slots, exact endpoint/boundary selection,
Q12 phase remapping, RGB quantization, UV interpolation and invalid sample
shapes. Its twelve tests pass.

The complete RU and PT audits each identify **483 animated submeshes**:
285 texture sequences, 190 changing color arrays and eight changing UV
arrays. Eight phase samples for every animated part produce **3,864 valid
reference samples per edition**. Minimal source examples are
`g011_r0000_p124` (texture), `g036_r0001_p000` (UV) and
`g058_r0004_p000` (RGB). The exporter and GPU adapter have separate
integration checks so that metadata alone is not treated as a rendered fix.
