// A ridden horse takes the rider's heading directly (obj_horse/Step_0.gml:571); a loose one
// eases into its turns: `direction += angle_difference(target, direction) *
// (1 - power(1 - 0.1, dt * 60))`, which is 0.1 per step at 60fps (:584-585).
if (rider == noone) {
    if (irandom(160) == 0) { face = irandom(359); speed = choose(0, 0, 1.4); }
    if (x < 96 || x > room_width - 96 || y < 96 || y > room_height - 96) {
        face = point_direction(x, y, room_width / 2, room_height / 2);
    }
    direction += angle_difference(face, direction) * 0.1;
}

// Gait threshold is the midpoint between walk and run speed (obj_horse/Step_0.gml:7, :636).
clip  = (speed <= 0.1) ? rig.gait.idle : ((speed >= 2.2) ? rig.gait.run : rig.gait.walk);
play += clip.speed / game_get_speed(gamespeed_fps);
depth = -y * 100;
