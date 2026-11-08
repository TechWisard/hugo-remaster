# Native gameplay recovery

This document records what was recovered from the PC version of **Hugo: Black
Diamond Fever**, and distinguishes decoded data from implemented gameplay.
Extracting a state table does not by itself prove that a replacement runtime
faithfully executes every state or collision rule.

## Evidence and reproducibility

The original game executable was **read, never executed**. The hardware PC
executable in the examined Russian and Portuguese releases is byte-identical:

`HUGO4_PC.EXE` SHA-256:
`bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3`.

Addresses below are virtual addresses in that PE32 image, whose image base is
`0x00400000`. The executable retains MSVC RTTI. The proof of a class ID is the
resource factory branch, its constructor call, and the constructor's vtable
write linked through the RTTI CompleteObjectLocator to the native class name.
This is stronger than assigning names from an object's appearance.

The importer requires only the user's `HUGO4.CD`; the executable and extracted
copyrighted assets are not checked into this repository. The decoder publishes
the source CD hash and the static-evidence executable hash in its JSON. Each
object has a stable ID, scene/container offset, field offsets, and evidence
addresses. All reference and array accesses are checked before reading.

```python
from hugo_assets.gameplay import recover_gameplay, export_gameplay

manifest = recover_gameplay(catalog)        # no filesystem writes
manifest = export_gameplay(catalog, output) # JSON plus original PCM WAVs
level = manifest["levels"]["g006"]
owner = level["owners"]["g007_o0028_t10400"]
```

`export_gameplay` writes `gameplay_manifest.json` and
`audio/g###_r####.wav`. The WAV files are copied without transcoding. The
manifest includes all 355 source WAV resources, their format, duration and
hash, and 862 `CSound` record-to-sample links in the examined Russian archive.

## Native classes

Game resource factory: `CHugo4ResourceFactory`, creation method `0x0040b200`,
vtable `0x0043e6e0`. It reads the signed 16-bit directory class ID, selects a
constructor, and passes the actual record buffer to it.

| MDIC type | Native RTTI class | Constructor | Confirmed role |
| ---: | --- | --- | --- |
| 10000 | CHugoMainActor | `0x00401a50` | Player |
| 10101 | CTargetCam | `0x0040a3d0` | Target camera |
| 10200 | CActorTrigger | `0x00404ef0` | Enter/exit/stay event trigger |
| 10203 | CNotifyTrigger | `0x00406570` | Once-only notification trigger |
| 10204 | CFallTrigger | `0x00406020` | Lethal fall volume |
| 10300 | CSimpleStateActor | `0x00407850` | General state machine |
| 10301 | CPowerUp | `0x00406fc0` | Collectible / deferred bonus |
| 10400 | CDefaultSegment | `0x00405960` | Native terrain collision segment |
| 10401 | COrnemental | `0x00406850` | Decoration, without automatic physics |
| 10402 | CPlatform | `0x00406c20` | Animated platform with explicit collider |
| 10403 | CBackmap | `0x004055b0` | Background centered on the camera |
| 10500 | CSpeaker | `0x00404cb0` | Sound actor |
| 10501 | CLoudSpeaker | `0x00406250` | Sound actor |
| 10600 | CSegmentTrigger | `0x00407590` | Segment management trigger |
| 10602 | CEndOfLevelTrigger | `0x00405b70` | Level exit |
| 10900 | CSysInfo | `0x0040b980` | System information |

System factory `0x0041f980` additionally proves type 6017 is `CHealthBar`
(`0x004288c0`), type 6018 is `CUpdateBonusCounter` (`0x00427650`), type 8000
is `CSceneController` (`0x00416800`), type 8001 is `CMoviePlayer`
(`0x004251f0`), and type 8003 is `CCharacterVisual` (`0x00425140`).

`CSimpleStateActor` is used for enemies, mechanisms, effects and other actors.
Its class alone must not be used to label every instance an enemy.

## References, coordinates and campaign

A resource reference is `0x80000000 | (ancestor_count << 16) | record_index`.
Scope 0 means the current scene, scope 1 its parent, scope 2 its grandparent.
Child scenes refer to the gameplay main scene, and gameplay main scenes refer
to global group 0. The middle bits are **not an absolute group ID**.

Coordinates are not recentered. The shared conversion is:

`Godot = (source.x, source.z, -source.y) * 0.01`.

The row-major source basis multiplies a column vector. Native `0x0040bde0`
implements that multiplication. `0x00414ad0` uses a transposed basis for the
inverse collision transform. Trigger JSON contains the original oriented box,
source basis, and an enclosing world AABB; using only that AABB loses the
orientation of a rotated volume.

The level sequence comes directly from global type-4000 scene descriptors.
Chapter labels in other localizations may differ; these names are source IDs.

| Chapter | Source name | Main group | Segments | Native diamond total | Diamond records | Checkpoints | CD track |
| ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |
| 1 | S05_TheBeach | 6 | 7–16 | 74 | 74 | 3 | 3 |
| 2 | S06_OldKikuTrail | 17 | 18–25 | 76 | 76 | 4 | 4 |
| 3 | S08_DiamondMines | 27 | 28–35 | 85 | 86 | 5 | 5 |
| 4 | S09_SupplyLine | 36 | 37–44 | 74 | 74 | 4 | 6 |
| 5 | S11_SmoothPipeline | 46 | 47–53 | 93 | 93 | 4 | 7 |
| 6 | S13_DiamondSquashFactory | 55 | 56–58 | 51 | 51 | 1 | 7 |
| 7 | S14_MeltDown | 59 | 60–67 | 86 | 86 | 4 | 8 |
| 8 | S16_TheGetaway | 69 | 70–77 | 99 | 99 | 0 | 9 |

The Mines mismatch is retained, not silently corrected. Some bonuses start
inactive and are revealed by actor notifications. The native expected count
and the sum of source collectible values are different measurements.

The eight level exits occur in groups 16, 25, 35, 44, 53, **57**, 67 and 77.
The Factory exit is not in its last segment. Exit handler `0x00405d60` emits
`0x22000040` to its HealthBar once on collision. It does not require all
diamonds. Its record fields are transform reference `+0x08`, local box
`+0x3c..0x50`, target reference `+0x5c`.

## Player spawn, camera and background

Player type 10000 field `+0x10` is the initial transform reference. Constructor
`0x00401c02` resolves it. Reset `0x004021d0` samples it at phase zero
(`0x00402245`) and copies XYZ to the current and previous position
(`0x0040224f..0x00402273`). Thus these are actual initial player locations,
not guessed points chosen from visible terrain.

| Main group | Source spawn XYZ |
| ---: | --- |
| 6 | 12012.10546875, 3300.611328125, -3037.479248046875 |
| 17 | -1.21124267578125, -1180.829833984375, -1004.8346557617188 |
| 27 | -1788.6982421875, 754.1580810546875, 75.48077392578125 |
| 36 | -5719.12353515625, -17520.67578125, -978.3978881835938 |
| 46 | -52344.59375, 14582.880859375, -949.5186767578125 |
| 55 | 2757.326171875, 29139.146484375, -349.8956298828125 |
| 59 | -1257.94384765625, 427.31964111328125, 18.273834228515625 |
| 69 | 22.731719970703125, 587.73046875, 18.273834228515625 |

`CTargetCam` has a camera resource at `+0x14`, an animated camera path at
`+0x1c`, its Hugo target at `+0x24`, and another path at `+0x28`. Constructor
`0x0040a4cf..0x0040a521` resolves them and samples the first path at zero.
The complete tracking algorithm is distinct from decoding these references.

Type 2000 is `CCameraVisual`. `+4` stores horizontal field of view in turns;
multiply by 360 for degrees. `+8` stores requested view distance.
`I3DCamera::0x004138f0` computes `160*cot(pi*fov_turns)`;
`0x00413c70` returns radians. D3D projection `0x0040ffd0` uses
`x_scale=cot(fov/2)` and `y_scale=x_scale*width/height`, proving horizontal
FOV. The PC renderer uses near 30 source units and clamps the projection far
plane to at least 50000 source units. It separately preserves the requested
distance; its use must not be confused with that far-plane clamp.

`CBackmap` record `+8` references its mesh. Its render handler `0x00405720`
copies camera translation into an identity matrix, adds the local offset at
`+0x18..0x20`, draws the mesh, then restores projection settings. `+0x10`
optionally rotates that offset by camera yaw; `+0x14` supplies a temporary
distance. Beach's only Backmap, g6r238, has a zero offset and yaw flag 0.
It is a camera-centered background, not ordinary terrain at world origin.

## Collectibles and native status rules

`CPowerUp` handler `0x00407190` resolves transform `+0x0c` and CSound reference
`+0x64`. Collision starts visual action 1, a 0.6-second timer, and its sound;
it disables the collision immediately. On timer completion it delivers its
rewards and is removed. Header fields describe independent rewards, not one
subtype enum:

| Field | Meaning | Delivery / receiver evidence |
| --- | --- | --- |
| `+0x10`, signed 16-bit | Diamond increment | `0x004074e4`, event 5 → HealthBar `+0x7c` |
| `+0x12`, signed 16-bit | Life increment | `0x00407504`, event 7 → HealthBar `+0x70`, cap 20 |
| `+0x14`, unsigned 16-bit | Nonzero enables healing | `0x00407524`, event 6; raw 5 or 50 is not the healed amount |
| `+0x16`, unsigned 16-bit | Start inactive | `0x0040727e`; event 2 copies sender pose and activates |

HealthBar event table at `0x00429164` maps events 3–7. Event 6 restores
20/10/5 health at difficulty indices 0/1/2, capped to maximum health. Event 7
adds total lives; death decrements them (`0x00429136..0x0042914c`). The HUD
shows spare lives as total lives minus one (`0x004293aa`).

SceneController initializes difficulty 1 and total lives 4
(`0x004169a1`, `0x004169ab`). HealthBar construction replaces its serialized
defaults with controller values. Maximum health starts at 11/10/8 by
difficulty and adds one per qualified status slot (`0x00416eb0`). End-level
status overwrites that qualification with whether integer
`diamonds*100/native_total` is at least 90 (`0x00427adf..0x00427b14`,
`0x00416f20..0x00416f44`). Ordinary damage event 3 adds the
difficulty index to incoming damage; alternate damage event 0x12 does not.

## State machines and notifications

Actor type 10300 field `+0xac` packs a record-relative low-16-bit offset and
high-16-bit state count. Each state is 72 bytes. Initialization at
`0x0040833e` resolves that array. The examined eight levels contain **2845
states** and **1275 state sound cues**. Their 603 total source records include
menu and credits actors; 2514 gameplay owners across all supported actor
classes are emitted for the eight levels.

| State field | Confirmed meaning |
| --- | --- |
| `+0x00`, signed int | Visual action; negative disables the visual/collider |
| `+0x04`, int | Transform-loop transition limit |
| `+0x08`, float | Transform period, seconds |
| `+0x0c`, int | Visual-loop transition limit |
| `+0x10`, float | Visual period for time-driven animation |
| `+0x14`, float | State timeout, seconds |
| `+0x18`, int | Contact damage |
| `+0x1c`, float | Contact knockback multiplier |
| `+0x20`, int | State flags |
| `+0x24`, 20 bytes | Sound-sequence object |
| `+0x38`, packed pointer/count | 12-byte transition entries |
| `+0x40`, packed pointer/count | 16-byte entry notifications |

Transition entries contain `{condition_mask, next_state, argument}`. The
native engine scans in source order and selects the first matching entry.
The decoded sentinel destinations are -1 (previous state), -2 (reset health
and phases, enter state 0), and -2000 (stop the search without a transition).
Masks are alternatives: a descriptor with mask 72 accepts path-loop bit 8
or collision bit 64. The argument is consulted only for the relevant
condition, rather than requiring every bit in a combined mask.

| Mask | Condition | Evidence |
| ---: | --- | --- |
| 1 | Event `0x22000001` | `0x00407b2b` |
| 2 | Collision with matching native collision mask | `0x00408d88` |
| 4 | Health depleted | `0x00407e20` |
| 8 | Transform loop count reached | `0x0040859d` |
| 16 | Visual loop count reached | `0x004088ca` |
| 32 | Elapsed state time exceeds timeout | `0x004089a6` |
| 64 | Collision | `0x0040911c` |
| 128 | Damaged | `0x00407e9c` |
| 256 | Event 2, then copy sender pose | `0x00407bfa` |
| 512 | Event 4 whose first argument matches | `0x00407cf6` |

State flags 1/2 reset visual/path phases on entry, 4 enables path animation,
0x40/0x80 reverse path/visual phases, 0x18 are forwarded physical-collider
bits, 0x100 requests a checkpoint snapshot, 0x200 removes the actor,
0x400 stops the previous sound sequence, 0x800 suppresses sequence repeat,
0x1000 enables sound pitch variation, and 0x4000 sends a player checkpoint
notification on collision. Unnamed bits remain raw.

Entry notifications contain `{target_reference, event, param1, param2}`.
`0x00409741..0x0040975a` sends them to the target in source order. This is
how an actor can reveal a previously inactive collectible. Actor initial HP
is its header `+0x14` plus the difficulty index (`0x0040824f..0x00408263`).
Damage events deduplicate the incoming damage record's ID at `+0x10`.

Header floats `+0x1c/+0x20` are initial visual/path percentages. Native init
and reset multiply them by 0.01 after initial state entry (`0x004084a6`).
The examined archive has 41 actors with a nonzero initial path phase, which
stagger instances on shared paths. Zero is not a safe replacement for these
authored values.

Path time advances only while state flag 4 is set (`0x0040855f`). For a
time-driven visual, a period less than or equal to zero freezes its phase
(`0x00408796..0x004087a8`); this occurs in 195 authored states. A distance
action instead advances by actual world displacement divided by its graph
root-motion vector length. The graph descriptor's bit 0 selects that domain;
the sign follows the transform-reverse flag (`0x004086eb..0x00408784`).
This is independent of the native 300-Hz clock and mesh sample count.

`CTicker` preserves the exact normalized endpoint 1. A value strictly above
1 or below 0 wraps and reports an overflow (`0x00416100`). Loop transitions
are tested on overflow, after incrementing a counter once for that update;
a loop limit of zero does not cause a transition before the first overflow.
Reverse reset begins at phase 1. The state update discards elapsed time
greater than one second (`0x0040852a`). The replacement VM tests these
cases separately from ordinary forward playback.

The 25 checkpoint actors have state flag 0x4000. Their notification is
`0x22000013`; Hugo saves the sender's actual matrix position, and HealthBar
increments the checkpoint counter. A checkpoint should therefore follow
the actor's native transition, not merely be invented at a convenient floor.

Sound-sequence entries are 84 bytes: a phase/time value, a CSound resource
reference, and runtime instance storage. Constructor `0x004158d0` divides
the time by the sequence denominator and resolves the reference. Handler
`0x004159f0` emits cues when animation phase passes that value. The manifest
preserves both raw and normalized timing.

## Triggers, collision and moving platforms

`CActorTrigger` has transform `+8`, local box `+0x0c`, and 20-byte event
descriptors at `+0x5c` (enter), `+0x70` (exit), `+0x84` (stay). Each descriptor
contains a target, event, two parameters and parameter-reference flags.
Bits 1/2 of the last word mark parameters 1/2 as resource references.
`0x00406540` sends the resolved event; `0x00405412..0x00405455` compares the
current and previous collision state to choose enter/exit/stay notifications.

`CFallTrigger` uses transform `+8`, bounds `+0x10`, and delivers a damage
record with magnitude 1000 (`0x00406217..0x00406244`). `CNotifyTrigger` uses
bounds `+0x0c`, a packed reference list at `+0x60`, and fires it once
(`0x00406774..0x004067a2`).

`CDefaultSegment` uses the native mesh collision section. Its constructor
asks `CMeshVisual` for the collision object at mesh `+0x18`
(`0x0042c420`) and initializes `CQuadTreeCollD`; it does not mark every
visible render triangle solid. Decoration type 10401 has no such registration.

Segment surface indices select one of **20 descriptors, 52 bytes each**, at
record `+0x9c + surface_type*52` (`0x00416680`). The manifest preserves each
descriptor. `+0x0c` is ground-contact damage, `+0x10` a movement-response
coefficient, `+0x14` a death-visual reference relative to the owner, and
`+0x18` prevents leaving a fully crouched state when nonzero. The crawl
handler checks this field together with the released crawl button and
standing headroom (`0x004035c4..0x004035e9`, `0x0040374e..0x00403773`).
This does not prove an automatic switch into crawling. The first XYZ vector
is still preserved without a speculative label.

Graph node `+0x14` is its category and `+0x18` its receive filter. They are
not bounding-box counts. Initialization `0x00415f4d/0x00415f8c` copies the
category to collider `+0x0c`; `0x00415f5c/0x00415fa4` copies the filter to
collider `+0x10`. `CLogicCollisionSystem` delivers a directed notification
only when `receiver.filter & other.category != 0` (`0x0041ca31..0x0041caa4`).
The sender is the other actor; its payload is `[own_collider, other_actor,
other_collider]`. Therefore state transition condition 2 compares the
**receiver's own category** against its argument (`0x00408d8d`). If that
state has a mask-2 descriptor but none matches the argument, it does not
fall back to mask 64.

Hugo's idle body has category `0x1001`, receive filter `8`; his attack
volume has category `2`, receive filter `4`. Native attack handling checks
his own category bit 2 and sends **one HP** of damage (`0x004031ed`). Each
accepted attack increments a damage ID (`0x0040350a`); the receiver rejects
that same ID a second time (`0x00407e08`). State-actor contact damage requires
its own category bit 8 and a positive authored damage value (`0x00408c06`).
Record `+0x260` selects ordinary damage event 3 or alternate event 0x12.
Only ordinary player damage adds the difficulty index. The state actor
itself handles event 3, not event 0x12.

`NativeGraphColliders` uses these action-specific node boxes and transform
chains. It composes the current graph pose with the owner pose, preserves
box orientation, and tests separating axes after an enclosing-AABB broad
phase. There is no guessed attack radius or cone. Node masks do not make
rendered meshes physically solid; physical movement remains a separate
native subsystem.

For physical obstacles, `CSimpleStateActor` wraps child collider 0 of
`CCharacterCollD` (`0x0040830a..0x0040832f`). That is the first **non-null
box** in the top-level graph, not necessarily graph node 0:
`0x00415f42..0x00415f47` skips missing box pointers and `0x00416004`
records the packed child-to-graph index mapping. The distinction affects 247
of the 595 examined physical action states. The wrapper's state flags are
`flags & 0x18`; the native physical sweep checks only whether this is nonzero
(`0x0041a8c1..0x0041a8cb`). Bits 8 and 16 do not select separate floor/wall
behaviors on this branch. The replacement creates an animated physical box
from that first authored collider, while Godot supplies the contact solver.

`CPlatform` has explicit bounds at `+0xa0`, collider selector `+0x9c`, and
inherits `COrnemental` timing. The path timer period is at `+0x28`, initial
phase at `+0x34`; visual period and phase are at `+0x14/+0x20`.
`0x00406b8a` advances path phase by elapsed seconds divided by that period;
`0x00406ba4` samples the transform. Constructor `0x00416040` forces wrap
mode. There is no separate activate/reverse/ping-pong event in this handler.
For example g13r145 has a five-second repeating path and a one-second visual
cycle. A return trip can be encoded in the actual source path.

## Pickup timing and checkpoint restoration

`CPowerUp` distinguishes idle (0), collection animation (1), removed (2)
and inactive (3). Native event 2 activates only an inactive pickup: it copies
the full sender pose, selects action 0 and resets phase, without an activation
delay (`0x004072f3..0x00407364`). Idle animation has a two-second period.
On contact, it immediately disables logic collision, selects action 1,
starts the collection sound and a 0.6-second ticker (`0x004073ec..0x00407439`).
Only after the ticker overflows are diamonds/lives/health awarded and the
actor removed (`0x004074bd..0x00407569`). The 0.6 seconds are therefore the
collection animation, not a cooldown before an activated bonus is collectible.

Native checkpoint events 30/31 do not serialize a complete world snapshot.
ActorManager saves removed persistent IDs (`0x0041ba92`) and restores that
list (`0x0041c076`). SceneScope saves which child segments were loaded,
unloads/reloads them on rollback, then restores small per-actor buffers.
The exact persistent fields differ by class:

| Class | Native checkpoint data |
| --- | --- |
| CSimpleStateActor | Four-byte activation flag, only when record `+0x264` enables persistence |
| CPowerUp | No explicit handler; source segment reload plus removed-ID list |
| Hugo | 28 bytes containing checkpoint/current/previous position and yaw |
| CTargetCam | 52 bytes containing closest path phase and source world pose |
| CHealthBar | Diamond count; health becomes maximum after death and the decremented life count remains |
| CActorTrigger | Clears contact state on restore |

The state-actor writer at `0x00407eff` saves its flag `+0x268`, not HP,
state, animation phase, elapsed time or pose. On restore (`0x00407f2b`), a
saved activated persistent actor is removed; otherwise it re-enters state 0
and applies source initial phase percentages. Child segment recreation
restores source HP naturally. An actor in the main scene does not gain an
unproven HP snapshot through this mechanism.

This distinction matters for checkpoints: state 1 sets its persistent flag
and saves the world before its removal animation finishes. Saving only the
already-removed IDs would allow the same checkpoint to activate again after
death. `native_checkpoint_snapshot()` retains the small native flag;
`reset_native_checkpoint(was_removed, saved)` implements this reset contract.
The separate modern `snapshot()/restore()` also preserves phases, loop
counters, world pose and HP to resume a suspended session. It is deliberately
not substituted for native death rollback.

State-entry world-save dispatch precedes authored entry notifications.
Checkpoint notification follows the collision-selected new state, before
its entry actions (`0x00408e4d..0x00408e79`). The source's order must be kept
when a single state both saves progress and reveals additional actors.

Completion health qualification uses at least 90% of the native diamond
total, only in the first seven chapters. The immediate extra-health award
checks that the chapter was not qualified already (`0x004279f3`,
`0x00427bfe`). This guard does **not** make the stored qualification
monotonic: the completion commit calculates a fresh boolean
(`0x00427acb..0x00427ae8`), excludes chapter index 7
(`0x00427af2..0x00427af5`), and overwrites the status slot through
`0x00416f20`. Its store at `0x00416f44` does not OR the previous flag.
Replaying a previously qualified chapter below 90% therefore removes its
contribution to the maximum health of subsequent chapters.

Collecting every checkpoint awards one life, capped at 20
(`0x00427ec7..0x00427ee5`); the native comparison is equality
(`0x00427a01..0x00427a13`) and also accepts a zero-of-zero checkpoint total.
`CEndOfLevelTrigger` only dispatches completion once per loaded instance:
the handler checks and sets its `+0x58` latch, then sends event `0x22000040`
to its target (`0x00405d60..0x00405d8d`). It does not require collecting all
diamonds. Modern suspended-session saves separately preserve `completed`
and `finish_rewards_applied`, so continuing an already finished run can
reopen its completion screen without awarding another life. These fields
are a new save-format safeguard, not claimed native checkpoint fields.

## Authored campaign sequence and movie placement

The Russian source's global group 0, record 45 is type 8000
`CSceneController` (constructor `0x00416800`). The record starts at scene
payload offset 47028. Its packed word at `+0x08` is `0x0012011c`: 18 scene
references begin at record-relative offset `0x11c`. The initial scene index
at `+0x14` is zero. The eight chapter-entry indices at `+0x20` are
`[3, 5, 6, 8, 9, 11, 13, 14]`.

These entries are used by executable code, rather than inferred from the
descriptor names. Chapter selection passes its selected slot at
`0x0042724e..0x00427255` to `CSceneController::0x00416ef0`; that method reads
`chapter_entries[slot]` and sends the load-scene event `0x22001001`.
The receiver stores the requested sequence index at
`0x00416c27..0x00416c2f`. Normal advance event `0x22001000` increments the
sequence index (`0x00416b27..0x00416b3e`).

| Chapter slot | Playable group | Source location | Entry sequence index | Movie before gameplay |
| --- | --- | --- | --- | --- |
| 0 | 6 | The Beach | 3 | Intro Part 2 (`intro_b`) |
| 1 | 17 | Old Kiku Trail | 5 | None |
| 2 | 27 | Diamond Mines | 6 | Plan on Track |
| 3 | 36 | Supply Line | 8 | None |
| 4 | 46 | Smooth Pipeline | 9 | More Power 1 |
| 5 | 55 | Diamond Squash Factory | 11 | More Power 2 |
| 6 | 59 | Melt Down | 13 | None |
| 7 | 69 | The Getaway | 14 | The Lost Juice |

The boot prefix is sequence 0 `S00_ITELogo` (group 1), sequence 1
`S02_Cut01_Intro_Part1` (group 2), then sequence 2 `S03_MainMenu` (group 3).
Intro Part 1 therefore belongs before the first menu; the first chapter's
authored entry starts with Intro Part 2. The logo is its own movie scene:
group 1, record 0 is type 8001 `CMoviePlayer`, and its filename pointer at
`+0x08` names `ITEMedia.bik`. It is not part of either intro movie.

During sequential play the interchapter movies consequently follow groups
17, 36, 46 and 59. After The Getaway, sequence 16 is `S17_Cut06_Outro`
(group 78), followed by sequence 17 `S18_OutroCredits` (group 79). Fresh
chapter selection uses the same entry table and includes the movie listed
above. Resuming a suspended gameplay session and a direct QA `--level`
launch can bypass the entry movie; neither is represented as an original
chapter-selection transition.

## CD music, with repeated tracks preserved

Type 1101 has the historical RTTI name `CSQMidiFile`, but the Windows
implementation opens **cdaudio** through `mciSendCommandA`
(`0x0042c7fd`). It reads the track byte at record `+0x1c`
(`0x0042c83d`) and plays from that track to the next track
(`0x0042c846..0x0042c86d`). These are physical CD track numbers.

Menu g3 and credits g79 use Track02. Gameplay uses Track03, 04, 05, 06, 07,
**07 again**, 08 and 09. Mapping eight unique music tracks to eight gameplay
levels would therefore be wrong.

## Validation and remaining limits

Synthetic unit tests exercise ancestor references, rotated volume bounds,
nonfinite and truncated input rejection, reward fields, packed state tables,
checkpoint flags, target references and event parameter flags. They contain
no original assets. Run:

```sh
python -m unittest discover -s tests -p test_gameplay.py -v
godot --headless --path game --script res://tests/native_vm_test.gd
```

The full examined Russian archive has also been decoded through all strict
checks and serialized as finite JSON. This validates the structural recovery;
it does not replace playing every original puzzle or verifying the new
runtime's complete puzzle interactions and physical response.

The synthetic Godot VM suite exercises actual runtime nodes: directed masks,
own-collider payload semantics, rotated-box separation, one damage per attack
ID, zero-period freeze, path flag gating, strict ticker endpoints, loop
conditions, event arguments, native checkpoint flags, modern resume,
effect-anchor poses and distance-driven action phases. It contains no source
game assets. Native physics response, complete campaign playthroughs and
rendering are separate integration checks; these passing regressions are not
a claim that every original encounter has already been played to completion.
