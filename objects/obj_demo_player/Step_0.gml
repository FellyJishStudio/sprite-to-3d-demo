/// Movement, traced from throne-client obj_player/Step_0.gml (:1315-1440, :1747-1770).
/// The real game paths around collision with mp_grid; the demo has none, so it walks
/// straight at the destination. Everything else is the game's: the 6px minimum click (in
/// the controller), the 3px arrival snap, the 60px run threshold, the 12px direction snap,
/// walk 0.5 / run 1.5, and the 0.2 speed blend. The turn blend is the horse's 0.1 rather
/// than the player's 0.2: a slower sweep shows off the continuous 360-degree rendering,
/// which is the entire point of the demo.
///
/// Direction is the actual movement vector, which is what drives the 360-degree rendering.

if (keyboard_check_pressed(vk_space))  sword_on = !sword_on;
if (keyboard_check_pressed(ord("T")))  look = look_random();      // was R; see below

// The ARROWS, not WASD: W, E and R now drop the effect lamps at the cursor (controller
// Step), and a key that both walked and spawned a disco ball dropped one every time you
// stepped north. R moved off the look shuffle for the same reason. This is the same
// mechanic as clicking, not a second one -- it pushes the destination ahead of you, and
// Shift pushes it past the run threshold below.
var _h = keyboard_check(vk_right) - keyboard_check(vk_left);
var _v = keyboard_check(vk_down)  - keyboard_check(vk_up);
if (_h != 0 || _v != 0) {
    var _lead = keyboard_check(vk_shift) ? 120 : 40;
    var _push = point_direction(0, 0, _h, -_v);
    target_x = x + lengthdir_x(_lead, _push);
    target_y = y + lengthdir_y(_lead, _push);
}

var _dist = point_distance(x, y, target_x, target_y);
var _run  = (_dist >= 60);           // run to a far destination, walk to a near one

if (_dist <= 3) {
    mv = 0;
} else {
    var _to = point_direction(x, y, target_x, target_y);
    // Ease a tenth of the way toward the destination each step, but snap once very close.
    direction = (_dist < 12) ? _to : direction + angle_difference(_to, direction) * 0.1;
    mv = min(lerp(mv, _run ? 1.5 : 0.5, 0.2), _dist);   // ramp up, never overshoot
}

// Waving is an idle-only gesture: moving past the walk threshold or mounting cancels it
// rather than pausing it, so the arm never snaps back up seconds after a ride.
if (wave_t > 0) wave_t -= 1 / game_get_speed(gamespeed_fps);
if (mv > 0.3 || mount != noone) wave_t = 0;

if (mount != noone) {
    var _horse = mount;              // GML cannot assign through `mount.field` directly
    _horse.direction = direction;
    // The horse carries you faster than you walk, but not by the flat 2.2 this used to
    // apply to both gaits -- that outran both cycles and the hooves slid. Walking takes
    // half of it and running three quarters, which still clears the 2.2 run threshold below.
    _horse.speed     = mv * (_run ? 1.65 : 1.1);
    clip  = (mv <= 0.3) ? rig.gait.rideIdle : rig.gait.rideRun;
    // x / y / depth are set in the End Step, once the mount has actually moved.
} else {
    if (mv > 0) {
        x += lengthdir_x(mv, direction);
        y += lengthdir_y(mv, direction);
    } else {
        x = target_x;                // arrive exactly, then idle
        y = target_y;
    }
    clip  = (mv <= 0.3) ? ((wave_t > 0) ? rig.gait.wave : rig.gait.idle)
                        : (_run ? rig.gait.run : rig.gait.walk);
    depth = -y * 100;
}

x = clamp(x, 1, room_width);
y = clamp(y, 1, room_height);

look.sword  = sword_on ? c_white : undefined;
look.shadow = (mount != noone) ? undefined : c_white;   // the mount casts its own
// While waving toward the camera the raised hand must draw over the head AND the hair;
// the chain is named here and clamped in front of the head in anim_build.
look.frontChain = (wave_t > 0) ? "armLeftUpper" : undefined;

play += clip.speed / game_get_speed(gamespeed_fps);
