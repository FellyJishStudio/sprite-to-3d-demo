# WOLLABONGA

A plan for turning this isometric animation demo into a mobile survivors-roguelite.

> You start in the dark, whacking zombies. Every upgrade bolts another piece of the rig on --
> a laser bar, a smoke machine, a disco ball, a subwoofer -- until twelve minutes later you are
> on a horse in the middle of a full laser show, and the zombies are confetti.

---

## 1. What the research says the genre demands

Five findings that should drive every decision below.

**Portrait, one thumb, auto-attack.** The dominant mobile control scheme is a single finger moving the
character while weapons fire themselves. Vampire Survivors' "one finger" movement and automatic fire is
the template, and Survivor.io's success came from repackaging it *specifically* for phones rather than
porting a desktop layout. Landscape-only titles are consistently relegated to honourable-mention tiers
regardless of quality — Balatro included. **This is the single most consequential finding for us,
because the demo is currently landscape.**

**Runs of 10-20 minutes, and interruptible.** Brotato's twenty-minute runs are near the top of the
comfortable range. The absence of a mid-run save in Vampire Survivors is repeatedly called out as a real
mobile failure — a phone game gets interrupted, and losing a fifteen-minute run to a phone call is a
churn event.

**Meta-progression is the retention engine.** The rule is that no run is ever wasted: death must deliver
both "you made a mistake" and "you still gained something". Hades leans on it heavily and deliberately.
Dead Cells layers permanent unlocks that open new routes. Without this, a phone roguelite dies at the
day-7 cliff.

**Escalating visual chaos is the product, not the polish.** In the survivors genre the late-run screen
full of overlapping projectiles and absurd power scaling *is* the reward — "getting there is entirely
the point". This matters enormously for us: it means the thing this codebase is already best at is the
genre's core appeal rather than a nice-to-have.

**Performance is a design constraint, not an optimisation task.** Input lag during heavy moments and
device heat over long sessions are named as tangible mobile failures. We already have quality tiers, a
profiler harness and a phone tier — that discipline is worth more here than in most projects.

**Monetisation: the market is rewarding transparency.** Vampire Survivors' model — free/cheap base,
optional content packs — is repeatedly held up as the ethical benchmark, versus manipulative currency
sizing that leaves awkward leftovers. Worth building toward content-expansion revenue rather than
friction revenue.

---

## 2. The concept

> **A rave that escalates until it kills everyone.** You start in a dim field killing zombies with
> one weak weapon. Every upgrade is another piece of the rig. By the end the field is a laser show,
> the music is a full track, and you are riding a horse through it.

**The progression IS the theme, and that is the whole idea.** Every game in this genre escalates —
that is the genre. What is different here is that getting stronger and the rave arriving are *the same
curve*. The research says the late-run screen of absurd overlapping power is the actual reward and that
"getting there is entirely the point"; in this game that moment means something specific. The party
peaked. Nobody else in the genre has an escalation that is *about* anything.

Three differentiators, and we already have most of the technology for all of them:

**The lighting rig is the content, not the presentation.** Almost every game in this genre is flat,
top-down and unlit — sprites on a tilemap. We have per-light cast shadows, coloured light pools, smoke
that samples nearby lights, caustics, lasers and weather. In a dark-fantasy game that engine would be a
nice presentation layer. Here it is the *subject*: the smoke that samples nearby lights is a fog machine
catching the lasers. Tech and theme are the same thing, which is rare and is the single most valuable
fact about this project.

**Upgrades are diegetic.** You do not pick "+10% area damage", you bolt on a laser bar, a smoke machine,
a disco ball, a subwoofer. The upgrade list is the rig being assembled around you. Every other game in
the genre offers a stat sheet.

**Mounted combat, and the horse is the joke.** Research turned up plenty of pets and companions —
Space Survivors, Relicborne — but mounted combat is essentially absent. We already have a working
horse-and-rider with correct depth, attachment and a shared shadow. The absurdity of a man calmly
sitting on a horse in the middle of a laser show is the identity, and it reads instantly with no
caption — which is exactly what a fifteen-second clip has to do.

### 2.1 The rule that makes it work: START DRAB

Minute one must be dim, quiet, colourless: a few zombies, one weak weapon, no lasers, a bare kick drum.

This is the hardest discipline in the project and the most important. If the game opens looking like the
demo does today, there is nowhere left to go and the entire arc collapses — the spectacle becomes the
baseline instead of the payoff. Restraint at the start is what makes the end land.

It also quietly solves a real genre problem. Every survivors-like looks identical at minute one: a
character on an empty field. Ours has a *reason* to look plain, and a payoff for having done so.

---

## 3. Why this codebase is unusually well-placed

Honest inventory of what already exists and maps directly onto the game:

| Already built | Becomes |
|---|---|
| 12 tuned effects (boom, lightning, laser, fissure, meteor, glacier, fire, smoke, galaxy, disco, water, weather) | The entire launch weapon list |
| Per-light cast shadows + light pools + sheen | The visual identity |
| Ragdoll knockdowns, with a canned phone-tier variant | Every enemy death |
| Horse + rider with attachment and depth | The mount system |
| Hitboxes with distance-falloff knockback | The damage model's foundation |
| Baked animation pipeline (`clips.json`, rigs, `anim_pipeline`) | Adding mobs is a data task, not a code task |
| Quality tiers incl. a phone tier, culling, batching, profiler harness | Shipping on phones at all |
| Measured crowd capacity (see 4.8) | The crowd budget, 60-80 visible |

The expensive, uncertain half of this game — making hundreds of animated, lit, dying characters run on a
phone — is the half that is already done and measured. What is missing is almost entirely *game*: rules,
numbers, UI and loop.

---

## 4. Full plan

### 4.1 Pillars

1. **Start drab, end absurd.** The run is one long crescendo. Minute one earns minute twelve.
2. **Spectacle is the reward.** Every upgrade must be visible from across the screen — and audible.
3. **One thumb, no menus mid-fight.** Movement is the only input. Everything else is automatic or a
   pause-and-pick.
4. **The mount is the joke and the fantasy.** Speed, trample, and the panic of losing it.
5. **Never waste a run.** Currency and unlocks from every death.

### 4.2 Core loop

```
Pick character + mount  →  12-min run  →  die or clear
        ↑                       ↓                ↓
   spend currency  ←  currency + unlocks  ←  results screen
```

**Within a run:** survive waves → kill mobs → collect XP → level up → choose 1 of 3 upgrades → repeat →
boss at 6 min and 12 min. Difficulty scales on a curve, not on kills, so a run has a known shape.

### 4.3 Weapons — the FX library becomes the arsenal

This is the highest-leverage part of the plan. Each existing effect is already tuned and performance-
budgeted; it needs a damage number, a cooldown and a targeting rule.

| Existing | Weapon | Behaviour |
|---|---|---|
| Q boom | **Fireball** | Periodic blast at the densest nearby cluster |
| A lightning | **Chain Lightning** | Arcs between N nearest mobs |
| S laser | **Prism** | Rotating beams, damage over time |
| F fissure | **Earthshatter** | Ground crack, area denial, knockback |
| V meteor | **Meteor Swarm** | Telegraphed drops, heavy single-target |
| H glacier | **Glacial Shatter** | Slab drops, shards spread as physical fragments |
| G fire | **Pyre** | Persistent burning ground |
| D smoke | **Ash Cloud** | Slows and obscures; interacts with every light |
| R galaxy | **Singularity** | Pulls mobs inward, then collapses |
| W disco | **Prismatic Ward** | Rotating orbit damage |
| E water | **Tidecaller** | Slow field, caustic lighting |
| Z rain / X snow | **Weather** | Stage-level modifiers, not weapons |

**Evolutions** are the genre's signature hook (Vampire Survivors' weapon fusion). We are unusually well
set up for it because our effects already composite well: Fireball + Ash Cloud → **Firestorm**;
Chain Lightning + Tidecaller → **Stormsurge**; Meteor + Earthshatter → **Cataclysm**. Each evolution is
mostly a parameter set on effects that already exist.

### 4.4 Mounts

The mechanical hook. Mounts are a resource that can be lost and regained mid-run.

- **Speed** — the core survival stat.
- **Trample** — moving through mobs deals damage and knocks them down, using the existing knockback.
- **Mount HP** — taking hits dismounts you rather than killing you. On foot you are slow and fragile
  until you find or summon a new mount. This is the game's tension curve, and it is unique to us.
- **Variety** — Horse (balanced, exists), Wolf (fast, low HP), Bear (slow, trample-heavy), and later
  exotic mounts as unlock rewards.

### 4.4b The music is a system, not an asset

On most projects audio is a shipping task. Here it is a core mechanic and belongs in the MVP.

**Layered stems keyed to progression.** The run opens on a bare kick drum. Each upgrade unmutes another
stem — hats, bass, a synth line, a vocal hook — so by minute twelve a full track is playing *because you
built it*. Levelling up is heard as well as seen. This is cheap to implement (a set of looping stems on
one clock, with gain envelopes) and does an enormous amount of work.

**Beat-synced effects.** The disco, the lasers and the strobes should pulse on the beat rather than on
their own timers. Everything in the FX library is already driven by a phase value; feeding those from a
shared musical clock instead of `delta_time` is a small change with a huge payoff, because it is the
difference between "lights are flashing" and "the room is on the track".

**The drop.** Boss waves are a drop. Build, break, silence, then everything at once. The genre has no
natural climax structure — a track does, for free.

Design consequence: **the track has to be built for this**, in stems, with a known BPM. That is a brief
for a composer, not something to bolt on at the end.

### 4.5 Mobs

Archetypes, all reusing the skeleton rig with palette and scale variation before any new art. Comic
rather than menacing — the art direction is high-key and saturated, not gloomy:

- **Swarm** — fast, weak, arrives in dozens. The bread and butter.
- **Bruiser** — slow, high HP, blocks lanes.
- **Ranged** — forces you to keep moving.
- **Exploder** — punishes standing still, and looks spectacular under the lighting.
- **Elite** — full ragdoll on death (see performance note), drops a chest.
- **Boss** — arena-scale, telegraphed attacks, uses the fissure system as an attack.

### 4.6 Meta-progression

Three layers, deliberately overlapping:

1. **Currency → permanent stat upgrades** (damage, HP, pickup radius, mount HP). Cheap, immediate,
   respeccable — respec being free is specifically praised in the research.
2. **Unlocks** — characters, mounts and weapons, opened by achievements rather than currency, so they
   feel earned. ("Trample 500 enemies" → unlock Bear.)
3. **Stage progression** — new stages with distinct lighting and weather, which is where our engine
   shows off. Night graveyard → storm coast (rain + lightning) → frozen waste (snow, glacier) →
   underworld (fissures, red light).

### 4.7 What has to be built

Roughly in dependency order.

**Foundational (no game without it):**
- Portrait camera + touch input (virtual thumb-stick or drag-to-move)
- Health, damage, XP, level-up
- Wave director / spawner with a difficulty curve
- Level-up card UI (pause and pick)
- Run state machine, results screen, meta save file
- Mob AI: seek-and-swarm (currently the AI only flees)
- Object pooling for mobs and pickups

**Game feel:**
- Weapon framework (cooldown, targeting, scaling) so all 12 effects share one system
- Mount HP / dismount / remount
- Damage numbers, hit flash, screen shake
- Pickups: XP gems, chests, magnet

**Shipping:**
- GameMaker Android/iOS export, **YYC compiler** (see risks)
- Mid-run save/resume
- Settings, audio, haptics
- Store assets

### 4.8 Measured baselines

All figures: desktop, fun mode (crowd + effects together), seeded, 100 characters unless stated.

**VM vs YYC.** YYC compiles GML to C++; it accelerates code, not fill.

| Tier | VM | YYC | Gain |
|---|---|---|---|
| x-low | 119.3 avg / 59.3 min | 263.4 avg / 155.8 min | 2.2x avg, 2.6x floor |
| high | 31.6 avg / 9.4 min | 68.9 avg / 42.7 min | 2.2x avg, 4.5x floor |

A consistent 2.2x from a code-only optimisation says a large share of the frame is **CPU, not fill** --
so YYC is the right lever and shipping on VM would be leaving half the machine unused. It also more
than doubles the FLOOR, which is what actually makes a game feel bad.

**Crowd ceiling — YYC, x-low, culling OFF, every character drawn.** This is the number wave design
must respect.

| Visible characters | fps avg | fps min |
|---|---|---|
| 100 | 95.2 | 40.8 |
| 200 | 56.0 | 33.9 |
| 300 | 41.1 | 28.9 |
| 400 | 31.6 | 25.0 |

For contrast, 100 characters *with* culling on reads 263/156 — the cull hides almost the whole cost,
which is why any benchmark that leaves it on will flatter a crowd design badly.

**The consequence.** 200 visible rigged characters averages 56fps on a fast desktop, at the cheapest
tier, natively compiled. A phone will be worse. The floor is already under 60 at a hundred, because the
minimum lands when a large effect fires into a full crowd — the normal case in this genre, not the
worst case.

### 4.8.1 DECISION: 60-80 visible enemies

**The crowd is capped at 60-80 on screen.** Not 100 — the average at a hundred is comfortable but the
floor is 40.8, and the floor is what a player feels. Sitting under the desktop limit is what leaves
headroom for a phone.

This is a scope *win*, not a compromise. Every enemy stays a full rig — lit, shadowed, ragdolling — and
the entire cheap-swarm-mob workstream disappears: no second art pipeline, no pre-baked facing sprites,
no LOD, no dual render path.

Two consequences to hold on to:

**Visible is not alive.** Culling already does the work: a hundred characters culled read 263fps against
95 drawn. The spawn budget can be far higher than the visible cap — a wave can have 200 alive with 70 on
screen — so wave design is about pacing arrivals, not about a hard entity limit.

**The horde fantasy comes from the effects, not the count.** Competing with Vampire Survivors on raw
enemy numbers means competing on the single axis where a lit, rigged, shadowed game is structurally
worst. Forty skeletons ragdolling through a fissure's glow reads better than four hundred sprites
overlapping, and only one of the two is shippable here. Genre precedent supports it: Archero built a
large mobile business on a handful of enemies per room, and Brotato works in the dozens.
"Survivors-like" spans two orders of magnitude in enemy count — the escalating power fantasy is the
genre requirement, the horde is not.

### 4.9 Performance strategy

We already know how to do this, and the existing tier system is the plan.

- The **canned knockdown system** we just built is exactly right for a survivors game: hundreds of
  deaths a minute cannot each run a solver. Ragdoll only elites and bosses; everything else plays a
  baked fall.
- **Cast shadows will not survive 200+ mobs.** The cheap directional blob is the answer for the crowd;
  reserve real cast shadows for the player, the mount and elites.
- Mobs need a **cheaper draw than a full rig** at scale. Options in order of preference: fewer bones on
  swarm mobs; a single pre-rendered sprite for distant mobs; sprite-only swarm mobs entirely.
- **Establish the crowd budget before designing waves.** Build a benchmark with culling *off* and find
  the real ceiling for visible mobs on target hardware. Wave design follows from that number, not the
  other way round.

### 4.10 Monetisation

Follow the model the research says the market rewards: free base game, revenue from content expansion
(character/mount/stage packs) rather than from friction. Optional rewarded-ad revives are acceptable and
expected. Avoid awkward currency-pack sizing — it is specifically called out as the manipulative
pattern players now punish.

### 4.11 Risks, honestly

| Risk | Severity | Mitigation |
|---|---|---|
| **Portrait + isometric may not read well.** Isometric needs horizontal awareness; portrait removes it. | High — affects everything | Prototype the camera in week 1. Test before building content. Fall back: zoom out, or a slightly rotated camera. |
| **GameMaker VM is too slow for phones.** Every number in this project is from a VM build. | High | Move to YYC early and re-baseline. Do not design waves against VM numbers. |
| **Effect density vs mob count.** Our effects are tuned for ~14 characters, not 200. | High | Budget mobs first, then effects. The tier system already gives the dial. |
| **Genre saturation.** Thousands of survivors-likes exist. | Medium | The lighting and the mount are the wedge. Lead every store asset with them. |
| **Scope.** 12 weapons Ã— evolutions Ã— mounts Ã— stages is years of content. | Medium | MVP below is deliberately one stage, five weapons. |
| **Heat over long sessions.** Named as a real mobile failure. | Medium | Frame cap at 60, aggressive culling, measure sustained sessions not spikes. |

### 4.12 Milestones

1. **M1 — Feasibility (2-3 weeks).** Portrait camera, touch movement, YYC build on a real phone, crowd
   benchmark with culling off. *Gate: does it read, and what is the real mob budget?*
2. **M2 — MVP loop (see Â§5).** One playable run, end to end.
3. **M3 — Depth.** All 12 weapons, evolutions, 3 mounts, 5 mob types, boss.
4. **M4 — Retention.** Meta-progression, unlocks, 3 stages, mid-run save.
5. **M5 — Ship.** Audio, settings, store, soft launch.

---

## 5. MVP plan

The goal of the MVP is to answer one question: **does the crescendo land?** Does starting drab and
ending in a laser show feel as good to play as it does to describe? Everything not serving that
question is cut.

### In scope

- **One stage.** The existing field, opening DIM — see 2.1. This is a feature, not a placeholder.
- **One character, one mount** (the existing rider and horse).
- **Five weapons**, from effects that already exist: Fireball (Q), Chain Lightning (A), Earthshatter (F),
  Pyre (G), Prismatic Ward (W). One starting weapon, the rest offered as level-ups.
- **Diegetic upgrade framing** — each pick is a piece of the rig, not a stat. Costs nothing but naming
  and it is half the identity.
- **Layered music**: one track in five stems, unmuting as upgrades are taken. Not optional; it is the
  thing being tested.
- **Three mob types**: swarm, bruiser, exploder — all skeleton-rig recolours.
- **One boss** at 10 minutes, arriving on a drop.
- **12-minute run** with a fixed difficulty curve, tuned as a crescendo.
- **XP gems, level-up, choose 1 of 3.**
- **Mount HP → dismount** on hit; on foot until you clear a wave.
- **Death → currency → three permanent upgrades** (damage, HP, speed). That is enough to prove the
  "no wasted run" loop.
- **Portrait, one thumb, drag to move.**
- **Runs on a phone at 60fps** on the x-low tier.

### Out of scope

Evolutions, multiple mounts/characters/stages, unlock achievements, mid-run save, ads/IAP, tutorial,
cloud save, settings beyond a quality toggle. Sound effects beyond placeholders — but *not* the music,
which is in scope above.

### Build order

1. **Portrait camera + touch movement.** Nothing else can be judged until this is right.
2. **Crowd benchmark, culling off, on a real device, YYC.** Get the mob budget. *All wave design
   downstream of this number.*
3. **Health/damage/death** on mobs, reusing the existing hitbox and knockdown.
4. **Spawner + difficulty curve.**
5. **Weapon framework**, then port the five effects into it.
6. **XP, level-up, card UI.**
7. **Stem-layered music on an upgrade-driven mixer**, and move the FX phase clock onto the beat.
8. **Mount HP, dismount, remount.**
9. **Boss.**
10. **Results screen, currency, three upgrades, save file.**
11. **Tune the crescendo.** This is the real work: pacing the twelve minutes so each upgrade feels like
    the room got louder.

### Success criteria

The MVP is a success if, on a real phone:

- A run holds **60fps at the x-low tier** with the full late-run mob count and effect stack.
- The run **escalates** — the last two minutes look and *sound* absurd next to the first two, and a
  viewer can tell how far in you are from a single frame.
- Testers **immediately start another run** after dying, without being asked.
- Losing the mount **changes how you play** rather than just lowering a number.
- The hook reads in a **15-second clip with no caption** — someone who has never seen it should get
  "rave" and "horse" instantly and find it funny. If it does not land, the wedge is invalid and the
  plan needs rethinking rather than more content.

---

## Sources

- [A Definitive Guide to Vertical Roguelikes on Mobile in Late 2025](https://antinomy.me/posts/roguelike-mobile-game-2025/)
- [Best Games Like Survivor.io in 2026 — Mobile Game Report](https://www.mobilegamereport.com/articles/best-games-like-survivor-io-2026)
- [Games Like Archero, Ranked — Mobile Game Report](https://www.mobilegamereport.com/articles/archero-fans-guide)
- [11 Best Games Like Vampire Survivors — Eneba](https://www.eneba.com/hub/games/games-like-vampire-survivors/)
- [Roguelite Games With The Best Progression Systems — GameRant](https://gamerant.com/roguelite-games-with-best-progression-systems/)
- [Roguelike vs Roguelite: Slay the Spire 2 vs Hades 2 — Switchblade Gaming](https://www.switchbladegaming.com/strategy-games/roguelike-vs-roguelite-explained/)
- [What is Meta-Progression? — GameBrief](https://www.gamebrief.net/glossary/meta-progression)
- [The Best Mobile Roguelites to Play in 2026 — Choost Games](https://choostgames.com/blog/best-mobile-roguelites-2026/)
- [Rogueliker — Best Roguelike Games](https://rogueliker.com/best-roguelike-games/)
