# throne-anim-demo

A standalone GameMaker Studio 2 project that draws characters which turn smoothly through a
full 360 degrees — from flat, side-on 16×16 bone sprites.

There is **no 3D geometry, no camera projection and no perspective transform** anywhere in
this project. There are also no GameMaker Sequences at runtime. Every frame is an array
lookup into a pre-baked table plus a sorted list of `draw_sprite_ext` calls.

It exists to demonstrate the animation pipeline in
`throne-client/tools/anim_pipeline` end to end, outside the game it was built for, in a
folder you can zip and hand to someone.

Roughly 950 lines of GML, 32 sprites, 8 baked clips, 2 rigs.

---

## 1. Running it

**From the IDE:** open `ThroneAnimDemo.yyp` in GameMaker Studio 2 (runtime
`2024.1400.5.1027`) and press Run.

**From PowerShell:** `rundemo` builds and launches it in the background, recording the
Runner PID so it can be stopped without touching any other GameMaker window. `demodown`
stops it. Build output lands in `C:\tmp\throne-demo-logs\rundemo.out.log`. Both are
functions in the user profile, not part of this folder.

**Raw Igor invocation**, if you want it without the profile:

```
Igor.exe --project=<path>\ThroneAnimDemo.yyp ^
         --runtimePath=C:\ProgramData\GameMakerStudio2-Beta\Cache\runtimes\runtime-2024.1400.5.1027 ^
         --runtime=VM --user=%APPDATA%\GameMakerStudio2-Beta ^
         --cache=C:\tmp\demo-cache --temp=C:\tmp\demo-temp windows Run
```

### Exporting to HTML5 / GX Games — turn off "Remove unused assets"

`options_main.yy` sets `option_remove_unused_assets` to **false**, and it has to stay that
way. Every bone sprite here is named as a *string* in the rig JSON and resolved at load
time with `asset_get_index` — which is the whole point of the data-driven design, but it
also means the compiler's reachability pass cannot see those sprites and deletes them.

A Windows test run does not strip, so this only bites on export, and it fails *quietly*:
the game boots, the HUD and ground grid draw normally, and each character collapses to the
handful of sprites that happen to be written literally somewhere in GML (`spr_head_base`,
`spr_horse_body_middle`, `spr_player_shadow`, `spr_sword`). It reads as a rendering bug,
not a build setting.

The real game avoids this without the option because it hard-codes `spr_bone_*` in GML.
A data-driven runtime cannot, so it pays for the flexibility with this setting. If a sprite
ever fails to resolve, the HUD prints a red `MISSING <sprite>` line.

---

## 2. How the illusion works

The rig is authored once, from the side, as a small pile of bone sprites — an arm is an
11×4 px stick. Four mechanisms turn that into a character that reads correctly from any
angle. All four live in `scripts/scr_anim_render/scr_anim_render.gml`.

### 2.1 Foreshortening: `x * cos(direction)`

Every bone's X offset from the root is multiplied by `cos(direction)`; Y is left alone.

```gml
_jx[i] = _dat[_r2 + ANIM_X] * _dcos + _ox;      // scr_anim_render.gml
_jy[i] = _dat[_r2 + ANIM_Y] + _oy + iso;
```

That is an orthographic projection of the side-view rig rotated about the vertical axis.
At `direction = 0` or `180` you get the full side view; at `90` or `270` the cosine is 0,
every bone collapses onto the centre line, and you are looking at the character head-on.
Between those it is continuous — this is what makes turning look smooth rather than
stepped, and it is the whole trick. One multiply.

### 2.2 Volume: bones point at the next joint and stretch to reach it

The baked pose gives joint *positions*. Each bone sprite is then rotated to aim at the next
joint in its chain and scaled along X by `distance / naturalLength`:

```gml
ang : point_direction(_jx[i], _jy[i], _nx, _ny),
xs  : point_distance(_jx[i], _jy[i], _nx, _ny) / (_m.len * poseXscale),
```

So as an arm foreshortens, the upper-arm sprite squashes toward its shoulder while still
touching the elbow. Limbs stay connected at every angle and read as having depth, without
any per-angle art. The last bone in a chain has no successor, so a tip is synthesised from
its own length and baked angle — that synthesised tip is also where a held item hangs.

**Single-bone chains take a completely different path.** The body, the head and every
animal armature have no next joint: no stretch, the angle is the baked angle multiplied by
`cos(direction)`, and the left/right mirror lives on **X**, not Y. Applying the multi-bone
path everywhere produces a plausible-but-wrong rig. Both paths are in `anim_draw`, marked.

### 2.3 The anisotropic direction remap — discrete decisions only

```gml
skew = point_direction(0, 0, cos(dir) * 0.2, -sin(dir) * 0.6);
```

A deliberately squashed direction: horizontal motion is compressed, vertical stretched, so
the angle at which a character reads as "facing away" matches an isometric ground plane
rather than a true circle. It drives only **discrete** choices — which sub-image (front or
back art), which side the depth bias falls on, which body half draws in front:

- `facing_down` — per rig, and the rigs genuinely disagree: `!(skew < 150 && skew > 30)`
  for the humanoid, `!(skew < 180 && skew > 0)` for the horse.
- the horse's "steep band" — body halves swap to their head-on art while
  `skew ∈ (60,120) ∪ (240,300)`.

It never touches the continuous pose. A local player takes its foreshortening and depth
side from the **raw** direction, everything else from the **skewed** one — two angle spaces
live at once, and conflating them puts the sub-image flip at the wrong angle.

### 2.4 Depth-sorted compositing

Each part gets a depth offset around 0, the list is insertion-sorted descending (GameMaker
paints higher depth first), and ties keep insertion order — which is what makes the
"reverse the chain when facing away, so the shoulder covers the hand" rule mean anything.
Between characters, ordinary `depth = -y * 100` handles it.

The table is data, not code (`datafiles/rigs/<rig>.demo.json`), and collapses to one linear
form evaluated in `scr_anim_depth.gml`:

```
depth = base + (facing_down ? down : up) + mirror·X + dirDep·P·X + legOff
```

The **horse** is the interesting case. It does not use one depth for its whole body: an
isometric tilt `y_adjust = amp · sin(skew)` (amp 7 facing down, 9 facing up) lifts the near
half relative to the far half, and the body splits into two depth bases —
`front = y_adjust·100`, `back = facing_down ? 100 : 0` — so the near legs draw over the far
legs as it turns. The spine piece rides at half tilt and bridges the two halves; when the
horse is nearly head-on it is drawn from a deliberately blank sub-image, because a barrel
seen end-on has no middle.

---

## 3. The pipeline that feeds it

```
GameMaker Sequence .yy  →  converter   →  animation/clips/<id>.anim.json
                                       →  baker       →  datafiles/baked_sequences/<id>.bin
                        →  rig extract →  animation/rigs/<id>.rig.json
```

Full spec: `throne-client/docs/animation-format.md`. Tooling:
`throne-client/tools/anim_pipeline` (`node src/cli.js bake`, `serve`, `validate`).

**What baking buys is the entire performance story.** The `.bin` holds transforms that are
already sampled, already parent-composed and already root-relative:

```
u32 totalFrames | u32 boneCount | f32 playbackSpeed | f32 sequenceLength
boneCount × (u32 byteLength + UTF-8 name)
f32[totalFrames × boneCount × 6]        // relX, relY, angle, xscale, yscale, alpha
```

So at runtime there is **no sequence to evaluate, no hierarchy to walk, no matrix stack, no
IK and no interpolation**. Playing an animation is:

```gml
frame = floor(play * sampleRate) mod totalFrames        // scr_anim_pose.gml
bone  = clip.data[frame * boneCount * 6 + row[slot] + component]
```

That is why this demo has **no draw-list cache and no dirty-flag bookkeeping** of any kind.
Every character recomputes its whole pose and transform every frame, from the baked floats,
and that is still cheap. Adding a cache would be optimising the wrong end.

The one thing v3 drops is the sample rate (and the playback mode), so the demo ships a
generated manifest carrying both — see §4.3.

---

## 4. What is in this folder

### 4.1 The runtime — four scripts

| script | lines | what it does |
|---|---:|---|
| `scr_anim_load` | 211 | reads the manifest, the `.bin` files and the rig JSON, and resolves **every name to a number**. After it runs, drawing never hashes a string or searches for anything. |
| `scr_anim_pose` | 30 | the payload layout: six component macros and the frame-index function. That is the whole of "playing" an animation. |
| `scr_anim_render` | 341 | `anim_facing`, `anim_sub`, `anim_iso`, `anim_draw` — the transform described in §2. |
| `scr_anim_depth` | 39 | evaluates the per-chain depth table from the demo JSON. |

`scr_demo_look` (88) is not part of the runtime: it is the appearance maths, ported from
`tools/anim_pipeline/editor/js/appearance.js`.

These four scripts are the deliverable. They are a transcription of
`tools/anim_pipeline/src/pose.js`, which is the pipeline's reference implementation, and
they are what a per-engine adapter should be ported from.

### 4.2 The objects — four, ~180 lines total

| object | behaviour |
|---|---|
| `obj_demo_controller` | loads the data, owns the HUD, the camera zoom, the skeleton spawner, the ground grid and the right-click ride menu. Created first (see the room's `instanceCreationOrder`). |
| `obj_demo_player` | click-to-move, sword toggle, look shuffle, riding. |
| `obj_demo_horse` | wanders; when ridden, takes the rider's heading. |
| `obj_demo_skeleton` | flees the player. Same clothed humanoid rig and the same clips, tinted grey — no new art. Deliberately dumb: no pathfinding, so the frame-rate readout measures animation and nothing else. |

Every object's Draw event is a single `anim_draw` call — except the horse's, which builds
itself and any rider into one list (`anim_build`) and paints that (`anim_paint`). There is
deliberately **no off-camera culling**: every instance pays full pose-and-paint cost every
frame, so the fps readout measures capacity rather than where the camera is pointing.

### 4.3 The data

| file | what it is |
|---|---|
| `datafiles/baked_sequences/*.bin` | 8 baked clips, copied verbatim from `throne-client` |
| `datafiles/rigs/{humanoid,horse}.rig.json` | copied **verbatim** from `animation/rigs` — never edited |
| `datafiles/rigs/*.demo.json` | the per-rig tables `pose.js` keeps in code rather than in the rig, plus corrections. Kept separate so the rig copies stay byte-identical to pipeline output. |
| `datafiles/clips.json` | **generated** inventory — see below |
| `sprites/` | 32 folders, copied whole. The PNG filenames are GUIDs referenced by `frames[]` in each sprite's `.yy`; never rename them. |

**`*.rig.json`** (pipeline output) supplies: the bone list with `sprite` / `pivot` /
`naturalLength` / `spriteFrames`, the chain membership, `chainConfig` position and armature
offsets and scale, `skins` (the humanoid defaults to `clothed`), `facingRule`,
`subImageRule` (the steep band), `isoTilt`, and — on rigs you can ride — `mount`: the seat
height, how much of the isometric lift the rider rides, and the six depth offsets that
sandwich the rider between the mount's two halves. All of it is tunable in the editor's
**Isometric look** panel and written back with **Save rig**, so the demo and the game read
the same values.

**`*.demo.json`** (this project) supplies:

| field | controls |
|---|---|
| `depth` | per-chain paint order — `base` / `down` / `up` / `mirror` / `dirDep` / `leg` / `frontOfHead` |
| `side` | which limb a chain belongs to, so a rider can drop the side the horse hides |
| `tint` | per **bone** appearance slot: `skin` / `headSkin` / `shirt` / `pants` / `plain` |
| `depthRide` | the same table again for a mounted rider, which re-stacks its own parts |
| `anchor` | which chains hair, the face and a held item hang off |
| `shadow` | ground shadows, pinned to a drawn chain (or to the origin) with `dy` / `sub` / `sx` / `sy` / `alpha` |
| `attach` | head extras (hair, face): which slot, which look-struct sprite field, which chain to pin to, depth relative to it |
| `gait` | which clip each movement state plays, so no GML names a clip |
| `iso` | corrections to the rig's isometric tilt (horse only) |
| `role` | which `mount.riderDepth` offset a chain takes while riding: `arm` / `leg` / `head` / `body` |

**`clips.json` is generated, never hand-maintained.** The copy script emits it in the same
pass that copies the `.bin` files, so the inventory and what actually shipped cannot drift.
Each entry carries `id`, `rig`, `sampleRate` and `playback`, taken straight from the
pipeline's own `animation/clips/<id>.anim.json`. `scr_anim_load` iterates it and pulls in
each rig the first time a clip needs it — no asset name appears in that file.

Note it is **not** the rig's `sequences` array: that lists all 28 humanoid clips in the
source project, not the 5 this demo ships.

---

## 5. Controls

| | |
|---|---|
| left-click the ground | walk or run there. **Hold and sweep** to keep steering; a yellow ellipse marks the destination |
| `WASD` / arrows | the same mechanic — pushes the destination 40 px ahead of you |
| `Shift` + `WASD` | pushes it 120 px ahead, past the run threshold, so you run |
| mouse wheel | zoom, 0.1 per notch |
| `Space` | draw / sheathe the sword |
| `R` | shuffle the character's look |
| `[wave]` button | wave the right hand — a **Z-axis** animation: the hand sweeps side to side facing the camera, mirrors facing away, and collapses to nothing in profile, because z projects into screen x through `-sin(direction)` exactly as x projects through `cos(direction)`. Spin while waving to see it. |
| `L` | place a **light** at the cursor (two exist at boot, six max). Every character in range casts a shadow of its *animated pose*: the shadow is a second `anim_build` pass whose joints are laid onto the ground (`joint + k·height` away from the light, `k = groundDist/lightHeight`) **before** the bones aim at each other — so the same point-at-next-joint stretch that keeps the standing figure connected keeps its shadow connected and correctly elongated. The isometric 1:2 ground supplies the direction and the metric (a light reaches twice as far along x as along screen-y); glow pools are 2:1 ellipses. Stateless, recomputed per frame. |
| right-click a horse | ride menu, then click **Ride** / **Dismount** |
| hold left on a horse | the same menu, for anyone without a right button (0.4 s) |
| `[+10] [+50] [-10] [reset]` | spawn or remove skeletons |

HUD readouts: `fps`, `fps_real`, the skeleton count and the current zoom. **`fps_real` is
the one that matters** — `fps` is capped at the room speed, `fps_real` is how many frames
the machine could have managed, so it is a direct readout of what the animation costs.

Movement, camera and the destination marker are traced from the real client
(`obj_player/Step_0.gml`, `obj_player/Draw_0.gml`, `obj_camera/Step_0.gml`) rather than
invented: walk 0.5 / run 1.5 px per step, run when the destination is 60 px or further,
3 px arrival snap, 10 %-per-step easing toward the destination, a 6 px minimum click, and a
0.6 default zoom of a 600 px-tall orthographic base. At that zoom the view is 640×360 —
the framing the real game plays at.

---

## 6. Measured performance

VM runtime, `fps_real`, room 2560×1440, camera 640×360. "Characters" counts skeletons plus
the player and horse; every one is a full 10–14 part humanoid or 14-part horse recomputed
from scratch each frame, with **no culling** — the number does not depend on the camera.

The current reference point: **~7.7 `fps_real` at 802 characters**, i.e. ~0.16 ms per
character per frame. Before the scratch-reuse and load-time-index pass the same scene
measured 3.8 (~0.33 ms per character), so cost is linear in characters drawn and the 60 fps
budget lands at roughly a hundred of them on this machine's VM build.

Profiling (`anim_draw` stubbed at three points, measured before that pass) put **~87 % of
the cost in building the transform** and ~13 % in sorting and `draw_sprite_ext`.
Per-character cost tracks almost exactly the number of **GML VM runtime-function
dispatches** — `point_direction`, `point_distance`, `lengthdir_*`, `dcos`/`dsin` — at
roughly 0.8 µs each. What got it there, all of it stateless: a struct per part replaced
with a flat number array, the payload copied into a GML array instead of `buffer_peek`,
`array_sort` with a comparator callback replaced by an inline insertion sort, every name
resolved to an integer at load time, and every per-frame allocation replaced with a reused
scratch workspace.

**YYC was not measured.** Igor refuses it here (`The platform 'windows' requires the 'uf'
argument…`, and `PackageZip` fails earlier with a permission error). Since the remaining
cost is VM dispatch overhead, a YYC build should be substantially faster — but that is an
expectation, not a measurement.

---

## 7. Known simplifications vs the real game

Honest list. These are the things that differ, not a feature list.

- **A mount and its rider share one draw list.** The client renders a horse as two depth
  *proxy instances* (`__horse_front_depth_base` / `__horse_back_depth_base`,
  `obj_horse/Step_0.gml:717-727`) and slots the rider between them. The demo gets the same
  ordering a different way: when a horse carries a rider it builds both characters into one
  depth-sorted list, and the rider's parts resolve against the **horse's** two bases rather
  than its own (`depthRide` / `depthRideFar`). So the horse's neck stays in front of the
  rider and its barrel behind, at every facing, with no offset tuning — but it is one
  instance doing the work, not three. The offsets themselves are rig data (`mount` in
  `horse.rig.json`), shared with `pose.js` and the editor.
- **No palette-swap shader.** Clothing uses the plain multiply tint the game itself uses,
  and so does the hand — `spr_bone_hand` is a pure-white template, so multiplying by the
  skin colour yields the skin colour, exactly as `armature_set_colors(left_arm, shirt, skin)`
  does. `spr_head_base` is the exception: it is already painted in `HEAD_SRC[0]`, and the
  client repaints it with a shader rather than a blend, so the demo gives the head its own
  `headSkin` slot carrying a compensating multiplier.
  The head's 4-colour swap is approximated by a single multiply mapping the head sprite's
  base colour onto the chosen skin — exactly identity on the default skin, as the game does,
  but darker skins get a linearly scaled shadow ramp instead of the two chained merges the
  game uses (documented in `scr_demo_look`'s header — only slot 0 of that palette is
  reachable through a blend, so the rest is not code here).
- **Hair is not recoloured.** The hair sprites are solid black silhouettes; lightening them
  needs the 8-colour appearance shader. The shuffle varies the hair *style* (13 of them) and
  leaves the colour at the game's default black.
- **Hair is drawn once, in front of the head.** The game splits each hair sprite into front
  and back halves at `yoffset + 8`; long styles render entirely in front here.
- **No shield, helmet, or attack animation.** The sword is the only attachment.
- **No pathfinding, no collision.** The client routes around obstacles with `mp_grid` and
  has a slide-fan escape for getting stuck; this walks straight at the destination.
- **No walk/run hysteresis.** The client delays the switch 30 steps so a jittering networked
  destination cannot flicker it. A clicked point only gets closer, so it is not needed.
- **The humanoid's arm offsets are the rig's unresolved ones.** `humanoid.rig.json` carries
  `armOffset [0,0]` with the note *"runtime x offset unresolved"*, while
  `scr_player_avatar.gml:748-752` uses a direction-dependent `-3/-4/-5` on the left arm,
  `+4` on the right, and `y + 1` on both. Not ported; the arms sit fractionally off.
- **Playback modes are carried but not honoured.** `anim_idle` and `anim_ride` are authored
  `pingpong`; the v3 binary has no playback field and the game's own runtime wraps
  unconditionally (`armature_update_player_baked.gml:26`), so this does too.

### Rider seat: `followTilt`, and why it is 0

The horse's front half is lifted by `y_adjust = amp * sin(render_dir)` — up to 9 px facing
away, down to −7 px facing the camera. The saddle sits on that half, but the client pins the
rider at a flat `target_player.y - 19` (`obj_player/Step_0.gml:1157`, the only place a
mounted rider's `y` is assigned), so the rider does not move with it.

`mount.seat.followTilt` in `horse.rig.json` is a 0..1 factor over that lift. It ships at
**0 — the client's behaviour** — after trying 1:

| | feet vs saddle, over 360° | horse head vs rider torso, facing camera |
|---|---|---|
| `followTilt: 0` (shipped, client) | 16.00 px drift | 7.8 px overlap |
| `followTilt: 1` | 0.00 px drift | **14.8 px overlap** of a 16 px sprite |

Gluing the rider to the saddle looks right in isolation, but the head and neck ride the
*same* lift, and at camera-facing they occupy the space the rider gets pulled down into — the
horse's head lands across the rider's chest. The drift is the lesser artefact, which is
presumably why the game does it that way. The slider is in the editor if you want to trade
one for the other.

### Four places this demo does not follow `pose.js`

`pose.js` is the pipeline's reference implementation and this is a transcription of it — but
in four places it disagrees with the game it models. Verified by reading the client; the
demo follows the client. **These are `pose.js` bugs and it has not been edited.**

1. **Animal foreshortening uses the wrong angle.** `pose.js` takes `dcos` from the raw
   direction for every rig. `obj_horse/Step_0.gml:673` passes `render_dir` into
   `armature_update`, and `armature_update_owner.gml:254-255` derives `dcos` from that
   stored value (`__baked_pose_use_armature_direction = true`, `obj_horse/Create_0.gml:31`).
   So an animal foreshortens on `cos(skew)`, a local player on `cos(raw)`. Measured symptom:
   with the raw angle, a seam opens between the horse's body halves at **29 of 360
   directions** (dirs 31–37, 143–149, 211–217, 323–330; worst gap 1.50 px), because the
   halves have not converged by the time the spine piece goes blank. With `cos(skew)` the
   seam is **gone at all 360 directions**.
2. **Tail tilt.** `pose.js` gives it the `facing_down ? -1` step; `obj_horse/Step_0.gml:803`
   and `:845` draw it at a plain `y` in both branches.
3. **Spine tilt.** `pose.js` gives `body_middle` only its half tilt; `:812` gives it the
   `-1` step as well (`y - 1 - 0.5*y_adjust`).
4. **Phantom leg tilt.** `pose.js` adds `isoTilt.legAmp · sin(skew)` to all eight legs.
   `obj_horse` computes that value at `:702` as `y_adjust_leg` and then never reads it — it
   is dead code, so the legs get no extra tilt.

A fifth, already fixed at source: `appearance.js` `boneTint()` returned the shirt colour for
every `/arm/` bone, but `scr_player_avatar.gml:257-258` is
`armature_set_colors(left_arm, shirt_color, skin_color)` — the lower arm is the bare hand,
not a sleeve.

---

## 8. Extending it

**Add a clip.** Add its id to `CLIPS` in the copy script and re-run it. That copies the
`.bin`, regenerates `datafiles/clips.json` from the pipeline's `.anim.json`, and adds the
`IncludedFiles` entry. Then point a `gait` entry in the rig's `.demo.json` at it. No GML
changes. (Included files belong in `IncludedFiles` **only** — adding them to `resources` as
well makes the asset compiler try to parse each `.bin` as a `.yy` and the project fails to
load.)

**Change the look.** `look_random()` in `scr_demo_look` builds a slot struct. A slot set to
`undefined` hides every part that uses it — that single mechanism covers the sword toggle,
the skeleton's missing hair and face, the rider's dropped far limbs and its suppressed
shadow. Which bone reads which slot is the `tint` map in the demo JSON.

**Tune the isometric feel.** `isoTilt.ampDown` / `ampUp` in the rig JSON control how far the
near half lifts; the `front` / `half` / `flat` membership lists control which bones move.
`subImageRule.band` controls where the head-on art swaps in. All of it is data — nothing in
this list requires touching GML.

**Add a rig.** Drop its `.rig.json` and `.bin` files in, write a `.demo.json` with `depth`,
`tint` and `gait`, and add its clips to the manifest. `anim_init` loads rigs on demand from
the manifest, so nothing else needs to know it exists.

If you find yourself typing a bone name, an offset, a depth constant, an angle band or a
clip name into a `.gml` file, it belongs in one of the JSON files instead.
