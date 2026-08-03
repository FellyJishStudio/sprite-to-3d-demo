# Cast-shadow test plan

The cast-shadow projection (scr_anim_render: `anim_light_shadow`, `anim_shadow_ground`,
`anim_shadow_paint`) has failed in six distinct ways during development, each caught by a
player screenshot rather than by a check. This plan defines the invariants, the metrics
that measure them, and the sweeps that exercise them, so that every historical failure —
and the classes around it — is machine-checked before a change ships.

## Invariants

| # | Invariant | Historical failure it guards |
|---|-----------|------------------------------|
| I1 | **Root attachment**: solid shadow mass reaches the feet; no leading hole along the cast centerline | detached blob while riding (band angles) |
| I2 | **Hoof pinning**: near-pair hooves' shadows within 4.5px of the hooves at every angle; far pair bounded (18px, face-on only) | front-leg misalignment (the original bug) |
| I3 | **Width**: silhouette's lateral thickness never below 3.5px, and >= 12px when the cast is near due E/W | the 1px dash |
| I4 | **Continuity**: no tracked shadow feature moves more than ~4px between adjacent 0.5-degree/1px steps of any motion — orbiting, approaching, or turning. NO exempted angles | the signed-floor mirror-pop flicker |
| I5 | **Solidity**: the union of stamps has no internal centerline gap > 8px | fan banding; also re-catches I1 |
| I6 | **No light-side overshoot**: shadow mass extends at most ~20px toward the light from the root | (guards fixes that slide stamps rootward) |
| I7 | **Exact shear pinning out of band**: every ground-line pixel maps to itself (checked algebraically) | regression of the core projection |

## Metrics

The harness models the drawn figure as a set of card-space **mass rectangles** (legs,
body, neck+head, tail, rider torso+head, root taper), placed from the decoded baked
clips (`sq_horse_idle_state.bin`, `sq_horse_run.bin` — real joint positions per frame,
with the per-bone iso tilt anim_build applies), foreshortened per facing. Each rect is
mapped through **both stamps** (pinned shear + lying, exactly the shipped matrices):

- **Centerline coverage** (I1, I5): every mapped quad near the cast centerline
  contributes its along-ray interval; intervals are unioned; the largest uncovered
  stretch between the root and 85% of the tip is the gap metric.
- **Lateral width** (I3): total spread of all mapped quads perpendicular to the ray.
- **Pin drift** (I2): distance from each *planted* hoof (within 3px of its ground row —
  a lifted gait-frame hoof legitimately casts displaced) to its shear-stamp shadow.
- **Step delta** (I4): max movement of any mapped quad corner between adjacent samples.
- **Overshoot** (I6): most-negative along-ray coordinate of any mass quad.

## Sweeps

| Sweep | Coverage | Why |
|-------|----------|-----|
| A. Grid | light angle (15-deg steps) x facing (30-deg steps) x radius {320, 150, 80}, idle pose | decouples facing from light angle — the orbit laps used before coupled them and missed away-facing band cases |
| B. Named regressions | the exact geometry of each reported screenshot, riding pose included | each past bug is a permanent RED/GREEN case |
| C. Temporal | full orbit lap; straight-line approach through a light's row; turn-in-place inside the band | flicker in all three motion classes |
| D. Gait | every frame of sq_horse_run x 4 facings x 5 band/edge light angles | "did you test it while riding?" — yes, every frame now |
| E. Startup (in-game) | `anim_shadow_regression_test()` runs at boot: cast-vector algebra, out-of-band ground-line pinning, lying-axis continuity, width floor | the always-on guard; the demo refuses to boot on failure |

Named regression cases (sweep B):
- **R1 front-leg drift**: diagonal light, side facing -> I2.
- **R2 E/W dash**: light due east/west -> I3.
- **R3 row-crossing flicker**: radial walk crossing the light's row -> I4.
- **R4 fan banding**: any multi-stamp scheme -> I5.
- **R5 riding detach**: light at (dgx 318, dgy -15) from an away-facing ridden horse,
  run gait -> I1. (The screenshot that prompted this plan.)

## Running

The harness lives beside the session scratchpad (`shadow_suite.ps1`); it ports the
shipped GML formulas verbatim and reads the real rig/clip data files, so it needs no
GameMaker runtime. Any change to `anim_light_shadow`, `anim_shadow_ground`, or
`anim_shadow_paint`'s matrices must be mirrored there (and in the startup test) in the
same commit — the suite prints the constants it mirrors at startup so drift is visible.

Baseline discipline: when a visual bug is reported, first encode it as a sweep-B case
and confirm the suite goes RED on the unmodified code; only then change the renderer.

## Status: shadows are posed from the light

Every artifact this document was written for — the dash, the mirror flip, the banding,
the detached blob, the slab — had one cause: the shadow was made by *transforming the
card the camera sees*. No transform of a view-dependent card can produce the silhouette
seen from somewhere else, so each fix traded one artifact for another.

`anim_shadow_dir` removes the cause. The rig poses to any facing, and the shadow build
was always separate from the drawn one, so the shadow is now posed at the **light's**
bearing. The card then *is* the outline being cast, correctly wide by construction —
broadside to the light it is the whole body, nose-on it foreshortens to the flank. The
`groundFootprint` data, the minimum-width floor, the smear and every band constant are
deleted, not disabled.

Two invariants changed meaning with it, and the suite was corrected accordingly:

- **I2** is no longer per-hoof pinning. The shadow's feet are the caster's floor outline
  *as the light sees it*, which is a different set of points from the hooves the camera
  draws. What must hold is that the shadow stays anchored at the caster (measured: 0.00px).
- **I4/no-flip** is the determinant of the map, not which side of the tail the nose is on.
  Card-x lies across the ray, so the shadow legitimately sweeps a full circle as the light
  orbits; testing the nose/tail side reports ~90 phantom flips a lap.

## Status

The parallel-projection model (a flat card sheared along one fixed cast vector) was
retired in favour of the footprint wedge described in `anim_shadow_paint`. Measured on
the refactor, all sweeps green:

| metric | parallel model | footprint wedge |
|---|---|---|
| worst centreline gap (A, 864 cells) | 31.7px | **0.0px** |
| R5 riding-detach | detached, unbridged | **0.0px** |
| R2/R6 width, light along the body axis | 2 ground units (the dash) | **22 ground units** |
| worst step move, all of sweep C | 3.3px | **2.3px** |
| worst planted-hoof drift (D, 600 gait cells) | 5.8px | **7.7px** |

Widths are judged in ground units, not screen pixels: the iso projection halves ground
y, so a correct flank-width shadow reads about 7px tall on screen and a screen-space
threshold silently demands a shadow wider than the horse.

Known residual: hoof drift is exact facing across the light and grows to ~8px facing
along it, where the flat card falls short of the footprint and the columns are padded
sideways to reach it. Those hooves stay inside the contact patch, so the shadow covers
them; the drift is in where their own cast lands, not in whether they are shadowed.
