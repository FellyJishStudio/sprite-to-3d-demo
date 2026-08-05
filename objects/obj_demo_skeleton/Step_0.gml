/// Deliberately dumb flee AI -- no pathfinding, so the frame-rate reading is about the
/// animation and nothing else.
///
/// FLEE_NEAR and FLEE_FAR are deliberately not the same number. With one threshold the
/// skeleton runs to just past it, stops, drifts back inside on the next frame and runs
/// again, flipping clip and facing every frame -- which reads as a shake rather than as a
/// decision. Starting at NEAR and only settling once it is FAR away gives the state
/// somewhere to sit. FLEE_HOLD then keeps each run going for a beat regardless, so a
/// player walking the boundary cannot strobe it either.
///
/// The distance they settle at has to be INSIDE the reach of an attack, or they simply cannot
/// be hit: they used to hold station at 220-260 while a blast reached 150, so anything let off
/// at your own feet -- which is everything fun mode does -- landed in the gap and caught nobody.
/// Keep FLEE_NEAR under demo_boom's radius.
///
/// Do NOT close the gap from this end, though. This is also what sets how far a hundred
/// skeletons spread out, and a tighter ring puts far more of them on screen at once where none
/// of them can be culled: pulling it in to 150 cost about ten frames a second at a hundred
/// characters, twice what the entire ragdoll solver costs. Widen the attack instead.
#macro FLEE_NEAR 220
#macro FLEE_FAR  260
#macro FLEE_HOLD 24

/// DOWN takes priority over everything: a skeleton on its back does not flee, does not
/// steer and does not move. It falls, lies there, then levers itself up.
///
/// There is no fall CLIP. The body goes limp at the moment of the hit and is simulated from
/// there (scr_anim_doll), so what it looks like on the way down is whatever the physics does
/// to it -- which is why no two knockdowns land in the same shape. `down_p` is only the
/// timeline: 0 -> 1 while it is going over, held while it lies there, then back to 0 as the
/// ragdoll is pulled onto a standing pose.
#macro DOWN_FALL 0.42        // seconds to go over, and the same again to get back up

/// Gravity, and how much of a landing survives it. A body is not a ball: it keeps very
/// little of the impact and stops skidding quickly, so the restitution is low and the
/// friction is fierce. Higher values look like a bouncing sack.
#macro FALL_GRAVITY  900
#macro FALL_BOUNCE   0.28
#macro FALL_SKID     0.0002    // fraction of ground speed kept per SECOND, once it is down

if (down_t > 0 || rising) {
    var _dt = delta_time / 1000000;
    clip  = rig.gait.idle;    // only read on the way back up, as the pose to reassemble onto
    speed = 0;

    // THE BODY'S OWN MOTION, integrated rather than scripted. It is launched, arcs, lands,
    // takes a small bounce, skids to a halt and stops turning as it does -- so no two
    // knockdowns end the same way even when the poses are identical.
    //
    // `x`/`y` stay on the FLOOR the whole time and only the draw is lifted by `hit_z` (see
    // Draw). That keeps the cast shadow on the ground under the body, where a shadow
    // belongs, instead of flying with it.
    if (hit_z > 0 || hit_vz != 0) {
        hit_vz -= FALL_GRAVITY * _dt;
        hit_z  += hit_vz * _dt;
        if (hit_z <= 0) {
            hit_z = 0;
            // IMPACT. Most of the travel and nearly all of the spin goes into the ground the
            // moment it arrives -- a body lands and digs in, it does not skate on. This is one
            // hard scrub rather than a gentle friction curve because the alternative reads as
            // the whole figure gliding under a ragdoll that has already gone still.
            hit_vx   *= 0.3;
            hit_vy   *= 0.3;
            hit_spin *= 0.3;
            if (hit_vz < -60) {
                hit_vz = -hit_vz * FALL_BOUNCE;
            } else {
                hit_vz = 0;                       // too slow to leave the ground again
            }
        }
    }
    if (hit_vx != 0 || hit_vy != 0) {
        // Air keeps its speed; GROUND TAKES IT AWAY, and quickly. A body is not a puck: it
        // arrives, digs in and stops within its own length. What it must not do is keep
        // travelling under a settled ragdoll, because then the limbs are motionless while the
        // whole figure glides -- which reads as the floor moving, not the body.
        var _fr = power(hit_z > 0 ? 0.6 : FALL_SKID, _dt);
        hit_vx *= _fr;
        hit_vy *= _fr;
        x += hit_vx * _dt;
        y += hit_vy * 0.5 * _dt;                  // iso: ground travel is halved on screen
        // Stops DEAD rather than creeping: below walking pace there is nothing left to show,
        // and a body that drifts a pixel a frame forever never looks like it has landed.
        if (abs(hit_vx) < 20 && abs(hit_vy) < 20) { hit_vx = 0; hit_vy = 0; }
    }
    if (hit_spin != 0) {
        direction += hit_spin * _dt;
        hit_spin  *= power(0.06, _dt);
        if (abs(hit_spin) < 6) hit_spin = 0;
    }

    // The tumble bleeds off once it is down. It is no longer a drawn rotation -- the ragdoll
    // owns the shape now -- but it still says whether the body is rolling, which is what the
    // friction above reads.
    if (hit_rollv != 0) {
        hit_rollv *= power(hit_z > 0 ? 0.85 : 0.05, _dt);
        if (abs(hit_rollv) < 4) hit_rollv = 0;
    }
    x = clamp(x, 16, room_width  - 16);
    y = clamp(y, 16, room_height - 16);

    if (!rising) {
        down_p = min(1, down_p + _dt / DOWN_FALL);
        // The timer only starts running once it is actually down, so the stall is time
        // spent lying there rather than time spent falling.
        if (down_p >= 1) {
            down_t -= _dt;
            if (down_t <= 0) { rising = true; down_t = 0; }
        }
    } else {
        down_p -= _dt / DOWN_FALL;
    }

    // THE BODY ITSELF. Everything above is where the body is; this is what shape it is in.
    //
    // Off-camera bodies do not simulate. Nothing is drawing them, and in fun mode a heap of
    // them outside the view is the single commonest thing in the room. Same rule as the draw
    // (see Draw), so a body is never simulated for a frame in which it cannot be seen.
    if (doll != undefined && !global.demo_nodoll
        && (!global.cull_on || (x >= global.cull_x0 && x <= global.cull_x1
                             && y >= global.cull_y0 && y <= global.cull_y1))) {
        // A CANNED body has no solver to run: it holds its airborne shape until it touches
        // down, then eases into the shape it was baked settling into. See anim_doll_bake.
        if (doll[$ "flr"] != undefined) {
            if (hit_z <= 0) anim_doll_land(doll, _dt);
        } else {
            anim_doll_step(doll, _dt, hit_z);
        }
        if (rising) {
            // Reassembling. The pull strength runs 0 -> 1 as `down_p` runs back to 0, so the
            // limbs are gathered gently at first and are exactly on the pose by the time the
            // ragdoll is dropped -- there is no frame where the body jumps into shape.
            play += clip.speed / game_get_speed(gamespeed_fps);
            anim_doll_pull(doll, rig, clip, play, x, y - hit_z, direction, look, 1 - down_p);
        }
    }
    if (rising && down_p <= 0) { down_p = 0; rising = false; doll = undefined; }

    depth = -y * 100;
    exit;
}

var _p = instance_nearest(x, y, obj_demo_player);
if (_p == noone) {
    flee = false;
    flee_hold = 0;
} else {
    var _d = point_distance(x, y, _p.x, _p.y);
    if (flee_hold > 0) flee_hold--;
    if (!flee) {
        if (_d < FLEE_NEAR) { flee = true; flee_hold = FLEE_HOLD; }
    } else if (_d > FLEE_FAR && flee_hold == 0) {
        flee = false;
    }
}

if (flee) {
    // Eased, not snapped, so a fleeing crowd sweeps through its facings.
    direction += angle_difference(point_direction(_p.x, _p.y, x, y), direction) * 0.1;
    speed     = 2.4;
    clip      = rig.gait.run;
} else {
    speed = 0;
    clip  = rig.gait.idle;
}

x = clamp(x, 16, room_width  - 16);
y = clamp(y, 16, room_height - 16);

play += clip.speed / game_get_speed(gamespeed_fps);
depth = -y * 100;
