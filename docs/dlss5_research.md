# DLSS 5: source audit and external Windows integration

Research snapshot: **2026-11-09**. The user targets an RTX 4090 and also
requires useful operation on other graphics cards. The implemented route is
an optional, isolated **GITC-Uplift / ReShade OpenGL → D3D12 → DLSS Neural
Rendering integration**, with an independent clean Godot fallback. It is not
a native Godot Streamline implementation. Packaging/static verification and
actual GPU execution are separate states.

## Selected dependencies

The machine-readable pins, per-member hashes and required PE exports are in
[`integrations/dlss5/dependencies.lock.json`](../integrations/dlss5/dependencies.lock.json).
The assembly and user workflow are in
[`integrations/dlss5/README.md`](../integrations/dlss5/README.md).

| Component | Pin | Reason |
| --- | --- | --- |
| GITC-Uplift | 1.8.0, source `0d73f2102032dcf8df24c7ff0f18315911f4af59` | Real OpenGL transport and NR evaluator, public source and release |
| ReShade | 6.8.0 Addon, DLL file version 6.8.0.2155 | Full add-on API and OpenGL runtime |
| NR runtime | ShortFuse compat-fp16 310.9.16 through RHI | The RHI 2.9.2 manifest explicitly selects the 20/30/40/50 compatibility build |
| LumeniteFX Kernel | `b50d47c0867a9a6633c8c29c410562ffc68be483` | Image-based motion vectors for a game without native DLSS |
| ReShade shader headers | `fd0022170615ce0d8162d219bff07232fa6dd84f` | Actual transitive shader includes, pinned with their notices |

[RHI 2.9.2](https://github.com/RankFTW/RHI/releases/tag/RHI-2.9.2) adds GITC
as a supported installation route and describes OpenGL setup with
antialiasing. Its pinned
[model manifest](https://github.com/RankFTW/RHI/blob/939b1d9066763797ded3bedf30bea5175b6dcc3a/dlss_manifest.json)
maps `310.9.16 (20/30/40/50)` to the exact ZIP used by this project.
[GITC 1.3.2](https://github.com/ghostinthecamera/GITC-Uplift/releases/tag/v1.3.2)
reports live RTX 4090 testing of the ShortFuse compatibility runtime on
D3D12 and Vulkan. That upstream result does not prove this Godot/OpenGL
combination or every other RTX generation.

The selected runtime is x64 PE32+, 276,162,560 bytes, file version
`310.9.16.0`, SHA-256
`cdfa6c1ec784867182164c7836f324f087b5c9f374d0c9fe46f54999feabf3ed`.
Its archive SHA-256 is
`dbeb1f2790b5c621887db99b1a56ac8bd5cb35207e8c074cbb806710f7460cab`.
The archive and extracted file are both checked; the version string alone
cannot distinguish this build from NVIDIA's original model binary.

## Actual NR interface, not a bootstrap

The inspected source is
[GITC v1.8.0 `src/nr/snippet.cpp`](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/nr/snippet.cpp).
It dynamically resolves the following exports from `nvngx_dlssnr.dll`:

```text
NVSDK_NGX_D3D12_Init_Ext
NVSDK_NGX_D3D12_CreateFeature
NVSDK_NGX_D3D12_EvaluateFeature
NVSDK_NGX_D3D12_ReleaseFeature
NVSDK_NGX_D3D12_Shutdown1
NVSDK_NGX_D3D12_PopulateParameters_Impl
```

`Snippet::CreateFeature` passes `NVSDK_NGX_Feature_Reserved18`; its evaluate
method calls the actual NR DLL. These exports were also found in the
selected DLL's PE export table without loading or executing it. The
runtime additionally exports Vulkan initialization, create/evaluate and
extension-requirement functions, but this pack uses its D3D12 interface.

[GITC `feature.cpp`](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/nr/feature.cpp)
and [`keys.hpp`](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/nr/keys.hpp)
provide the concrete parameter contract. Creation supplies dimensions,
node masks, preset, scaling ratio and performance setting. Evaluation binds
`DLSSNR.Color`, `DLSSNR.Output`, optional `DLSSNR.MVec`, mask/backbuffer/UI
resources with subrects, motion scale, reset, enabled state and artistic
controls. The host checks the result and records whether an enabled
evaluation happened. No placeholder callback is substituted for NR.

[The OpenGL bridge](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/bridge/gl_bridge.cpp)
creates a private D3D12 side, shares textures with OpenGL and orders access
with shared fences, with a CPU-ordered fallback where supported. It copies
the processed result back only when the recorder wrote it. It reports a
returned frame after that path succeeds. An unavailable/failed NR pass
does not turn an ordinary frame into a claimed neural result.

The checked add-on imports ordinary Windows D3D11/D3D12/DXGI, version,
crypto and system APIs. Its build uses the static MSVC runtime. The NR
DLL's checked import table contains Windows system APIs; the NGX driver
core is resolved at runtime. The actual driver, OpenGL interop extensions,
memory budget and feature creation therefore remain runtime gates.

## Antialiasing and motion vectors

The OpenGL bridge accepts a single-sampled input. This does **not** require
turning off game MSAA: GITC's
[`src/gl/format.cpp`](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/gl/format.cpp)
and its adjacent format contract distinguish a multisampled backbuffer
from ReShade's resolved intermediate at the `Uplift` technique.

The preset explicitly enables `Lumenite_Kernel@lumenite_Kernel.fx` followed
by `Uplift@Uplift.fx`, requests Lumenite motion and disables the unrelated
Launchpad input. GITC's
[`Uplift.fx`](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/fx/Uplift.fx)
consumes the Kernel flow/confidence textures and produces `UPLIFT_MV`.
The selected Kernel, its includes, standard shader headers and required
texture are downloaded as actual files. Their existence/hashes and ordering
are checked; a live ReShade shader compilation and temporal-quality test
still require the Windows GPU environment.

The NR profile uses MSAA 4× and game render scale 1.0. It starts with one
NR pass, full working resolution, Present placement and Keep Faces off.
The clean safe profile uses MSAA 2× and scale 1.0. Estimated motion can
produce temporal artifacts; it is not equivalent to engine motion from
previous camera/object/skinning transforms. The pack does not claim SR,
frame generation, a frame-rate improvement, or visual equivalence to a
native engine integration.

## Automatic compatibility path

The installer copies the supplied Godot x64 export into a new directory
and also creates a clean copy under `clean/`. Original source game binaries
are never part of this installer. No proxy or NR DLL is copied into the
clean application directory, and its working directory is explicitly set
there. The launcher never changes the source export in place.

The first probe runs the clean game in native OpenGL. If no valid rendered
probe is produced, a second clean probe requests `opengl3_angle`. The game
reports the effective driver, API, adapter, software-renderer status and
rendered-frame evidence. ANGLE is a clean fallback only; the OpenGL
ReShade route is not presumed to hook an ANGLE/D3D11 renderer.

Only a hardware-rendered native OpenGL NVIDIA RTX result, plus valid NR
files, permits a bounded NR probe. Model generation labels are a candidate
filter, not proof of compatibility. The NR probe runs up to 320 frames,
with an engine quit limit and a 120-second process watchdog. Its report
and fresh ReShade log must both succeed. The required log evidence covers
bridge initialization, feature creation, enabled evaluation and return of
an OpenGL frame. Loading a DLL or drawing a ReShade menu is insufficient.

A successful probe is cached against adapter/API-driver data and the
explicit `driver_info` reported by Godot, game/PCK,
runtime/add-on/ReShade hashes and settings. Its evidence log is hashed.
Failures invalidate the cache. AMD/Intel, non-RTX NVIDIA, software
renderers, ANGLE or an unsuccessful NR probe use the clean safe profile.
Missing driver information disables caching. The 1280×720 probe qualifies
the processing path only: it does not establish available VRAM, frame time
or visual stability at 4K or ultrawide output. Actual launches pass no
resolution/fullscreen override, leaving the game's display settings intact.
Game output dimensions, game render scale and GITC NR working resolution
are separate controls. GITC can decline processing a frame while ordinary
rendering continues.

The preset explicitly enables GITC's `VramCheck=0` (Careful) and
`BudgetMarginMB=0` (automatic 512 MiB reserve). The pinned
[budget implementation](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/nr/budget.cpp)
fits passes at the requested working dimensions; it does not silently
reduce the output resolution. If zero passes fit, NR is skipped. While
active, the
[session](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/nr/session.cpp)
samples memory once per second. Two over-budget samples suspend a
single-pass session; optional resumption requires ten seconds of sustained
headroom. This is a budget estimate, not a successful 4K allocation test.
`RealHost::QueryMemory` reports unlimited headroom if the DXGI query fails,
so the budget guard cannot guarantee protection in that case.

The
[OpenGL bridge](https://github.com/ghostinthecamera/GITC-Uplift/blob/0d73f2102032dcf8df24c7ff0f18315911f4af59/src/bridge/gl_bridge.cpp)
returns without copying a neural result into the game frame when the
queue is busy, recording fails or its bounded CPU wait times out. CPU
waits are capped at two seconds; three consecutive timeouts stop the
bridge. Feature/evaluation failures are also reported by the session.
These source paths support ordinary-frame continuation for handled
failures; they cannot guarantee recovery from every GPU or driver hang.

The actual game has no probe timeout. A healthy process is not killed
because NR is absent. Backend failures are observed, allowing its normal
frame path to continue. A nonzero exit from the NR game triggers one clean
relaunch, with an additional explicit ANGLE attempt if clean native
rendering fails. Hardware below Godot's OpenGL/GLES requirements still
cannot be promised a working renderer.

## Official alternatives examined

NVIDIA's
[DLSS 5 launch description](https://www.nvidia.com/en-eu/geforce/news/dlss-5-3d-guided-neural-rendering/)
identifies 3D-guided neural rendering as an independent feature and names
Streamline as an integration route. The public
[Streamline 2.14.16](https://github.com/NVIDIA-RTX/Streamline/releases/tag/v2.14.16)
source declares `kFeatureDLSS_NR = 1004`; its
[changelog](https://github.com/NVIDIA-RTX/Streamline/blob/625db07d4bca5abc67d781c42af7e7fb0761f1b6/changelog.txt)
mentions `sl.dlss_nr`. However, inspection of the source and the public
x64 release archive's 511-entry central directory found no NR-specific
integration header, plugin, guide or NR runtime. The release announcement
is not an available complete native integration contract.

The public
[RTX Remix 1.6.1 archive](https://github.com/NVIDIAGameWorks/rtx-remix/releases/tag/remix-1.6.1)
does contain an official `.trex/nvngx_dlssnr.dll`: 266,424,944 bytes,
SHA-256 `2bc19bc09a7b89dd44f73e2ac0108fcc586e2154bdd0830f242f4f040e28789f`.
It was statically inspected as a separate source. It is not the compatible
RTX 4090 build selected above and is not silently included instead.

[Godot RenderingDevice](https://docs.godotengine.org/en/stable/classes/class_renderingdevice.html)
is unavailable in Compatibility mode. Its documented native-resource API
does not expose the current native command buffer. A
[CompositorEffect](https://docs.godotengine.org/en/stable/classes/class_compositoreffect.html)
can access rendering resources in supported renderers, but alone does not
supply Streamline's full initialization, command-buffer and synchronization
contract. Moving to Forward+ is not by itself an NR implementation.

## Unofficial alternatives examined

[DLSS5-Feeder](https://github.com/jlrouzies-fr/DLSS5-Feeder) contains a real
OpenGL transport and can supply a synthetic DLAA contract to a separate NR
consumer. It needs more components, including a consumer and DLSS SR
runtime, and its instructions require disabling MSAA/SSAA. Those
requirements belong to Feeder and are not imposed on the selected GITC
route. The current Feeder source also documents consumer-version and
driver interactions.

[DLSS5 Bridge](https://github.com/NIGos/dlss5-bridge) mirrors existing DLSS
contracts or synthesizes inputs, but needs a separate neural consumer.
[Autopilot](https://github.com/Kizzuwatnaa/DLSS5-Autopilot) and RHI are
install/configuration managers. Neither the presence of a manager nor a
project called “DLSS5 in Godot” establishes actual model execution.

## Verification boundary and distribution

Source inspection, publisher downloads, archive/member hashes, x64 PE
exports, installer isolation/rollback, route selection, probe timeouts and
log classification can be checked without loading the neural DLL. The
pack manifest initially records `hardware_validation = not_run` and
`model_execution = not_run`. Only fresh local process/log evidence changes
the runtime report. No screenshot from the ordinary Godot renderer is
presented as a DLSS 5 result.

Public Git contains this integration code and pins, not downloaded DLLs or
Lumenite source. GITC/ReShade notices and NVIDIA terms accompany a local
pack. Lumenite's AGNYA terms prohibit public rehosting; its unmodified
files are obtained from the author's pinned repository for local use.
The download builder does not modify antivirus, system DLLs, driver
settings or authentication controls.
