/// Deliberately dumb flee AI -- no pathfinding, so the frame-rate reading is about the
/// animation and nothing else.
var _p = instance_nearest(x, y, obj_demo_player);
if (_p != noone && point_distance(x, y, _p.x, _p.y) < 220) {
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

play += global.clips[$ clip].speed / game_get_speed(gamespeed_fps);
depth = -y * 100;
