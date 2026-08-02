/// Deliberately dumb flee AI -- no pathfinding, so the frame-rate reading is about the
/// animation and nothing else.
///
/// FLEE_NEAR and FLEE_FAR are deliberately not the same number. With one threshold the
/// skeleton runs to just past it, stops, drifts back inside on the next frame and runs
/// again, flipping clip and facing every frame -- which reads as a shake rather than as a
/// decision. Starting at NEAR and only settling once it is FAR away gives the state
/// somewhere to sit. FLEE_HOLD then keeps each run going for a beat regardless, so a
/// player walking the boundary cannot strobe it either.
#macro FLEE_NEAR 220
#macro FLEE_FAR  260
#macro FLEE_HOLD 24

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
