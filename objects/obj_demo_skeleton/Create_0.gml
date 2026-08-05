/// No new art: the clothed humanoid rig and the same three clips, greyed out.
rig       = global.rigs[$ "humanoid"];
look      = look_skeleton();
clip      = rig.gait.idle;
play      = irandom(200) / 20;   // desynchronise the crowd
direction = irandom(359);

// Flee state is latched rather than recomputed from distance alone -- see Step.
flee      = false;
flee_hold = 0;

// KNOCKED DOWN. `down_t` is seconds left on the floor and `rising` says it has started getting
// up; `down_p` runs 0 -> 1 as it goes over, holds, then back to 0 as it reassembles.
//
// The fall itself is NOT a clip -- it is simulated, see `doll` below. `down_p` is only the
// timeline: it holds the body down for its stall, then drives how hard the ragdoll is dragged
// back onto a standing pose, which is what a body levering itself off the ground looks like.
/// `down_back` is true when the blast came from IN FRONT, which is what puts you over
/// backwards; it picks which way the body somersaults. See demo_skeleton_down.
down_t    = 0;
down_p    = 0;
rising    = false;
down_back = false;

/// ...and the body's own motion while it is down. The clip supplies the POSE; these supply
/// where that pose is and which way it is pointing, which is what makes one knockdown differ
/// from the next. `hit_z` is height above the ground -- the position stays on the floor and
/// only the DRAW is lifted, so the cast shadow stays where the body will land.
hit_vx    = 0;
hit_vy    = 0;     // ground units per second; screen y takes half of it, as everywhere
hit_vz    = 0;
hit_z     = 0;
hit_spin  = 0;     // degrees per second of FACING change -- which way the body is pointed
/// How hard the body is tumbling, in degrees per second. It seeds the ragdoll's spin at the
/// moment of the hit and then decays, and while it lasts a body still going over slides further
/// than one that has stopped -- rolling is cheaper than skidding.
hit_rollv = 0;

/// THE RAGDOLL, or `undefined` while the body is on its feet. Built at the moment of the hit
/// from whatever pose it was in, simulated from then on, and dropped once it has got back up.
/// While it exists it replaces the clip entirely -- for the draw, and for the cast shadow.
doll      = undefined;
