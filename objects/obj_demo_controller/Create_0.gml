/// Loads the pipeline data, owns the HUD, the camera zoom, the spawner and the ride menu.
/// Created first (see the room's instanceCreationOrder) so the rigs exist for everyone else.

anim_boot();          // asynchronous; the cast is spawned in Step once it finishes
randomize();

spawned = false;

// Point lights: each casts an animated shadow of every character in range (see
// anim_cast_shadows) and paints a 2:1 isometric glow pool on the ground. `h` is the
// light's height above the ground plane -- what shadow length is projected against.
global.demo_lights = [];
function demo_add_light(_x, _y) {
    if (array_length(global.demo_lights) >= 6) return;      // enough for a demo room
    array_push(global.demo_lights, { x: _x, y: _y, h: 60, r: 340 });
}

depth       = 20000;          // the ground grid draws behind every character
// Numeric second element = spawner action; the string "wave" starts the player's wave.
buttons     = [["+10", 10], ["+50", 50], ["-10", -10], ["reset", 0], ["wave", "wave"]];
menu_open   = false;
menu_x      = 0;
menu_y      = 0;
menu_target = noone;
click_used  = false;      // a press the HUD took stays taken until release
hold        = 0;          // frames the current left press has survived, for the long press

// Camera, from obj_camera/Create_0.gml: an orthographic view `base_height` tall scaled by
// `zoom_level`, defaulting to 0.6 -- which is the framing the real game plays at. The room
// view supplies the aspect ratio, and the room itself supplies the zoom-out limit.
base_h   = 600;
zoom     = 0.6;
base_w   = base_h * (camera_get_view_width(view_camera[0])
                   / camera_get_view_height(view_camera[0]));
zoom_max = min(room_width / base_w, room_height / base_h);
camera_set_view_size(view_camera[0], round(base_w * zoom), round(base_h * zoom));

function demo_spawn(_n) {
    repeat (max(0, _n)) {
        instance_create_depth(irandom_range(48, room_width  - 48),
                              irandom_range(48, room_height - 48), 0, obj_demo_skeleton);
    }
}

/// The horse under a world point, or noone.
///
/// These characters are drawn bone by bone, not from sprite_index, so their collision masks
/// bear no relation to what is on screen -- spr_horse_body_middle's is 21x17px and sits
/// *below* the drawn horse, so instance_position() almost never hits it. Pick the nearest
/// horse to the cursor and test against the drawn body instead.
function demo_horse_at(_mx, _my) {
    var _near = instance_nearest(_mx, _my, obj_demo_horse);
    if (_near == noone) return noone;
    return (point_distance(_mx, _my, _near.x, _near.y - 18) <= 34) ? _near : noone;
}

function demo_kill(_n) {
    var _all = [];
    with (obj_demo_skeleton) array_push(_all, id);
    for (var i = 0; i < min(_n, array_length(_all)); i++) instance_destroy(_all[i]);
}

