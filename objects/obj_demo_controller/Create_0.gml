/// Loads the pipeline data, owns the HUD, the camera zoom, the spawner and the ride menu.
/// Created first (see the room's instanceCreationOrder) so the rigs exist for everyone else.

anim_boot();          // asynchronous; the cast is spawned in Step once it finishes
randomize();

spawned = false;

depth       = 20000;          // the ground grid draws behind every character
buttons     = [["+10", 10], ["+50", 50], ["-10", -10], ["reset", 0]];
menu_open   = false;
menu_x      = 0;
menu_y      = 0;
menu_target = noone;
click_used  = false;      // a press the HUD took stays taken until release

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

function demo_kill(_n) {
    var _all = [];
    with (obj_demo_skeleton) array_push(_all, id);
    for (var i = 0; i < min(_n, array_length(_all)); i++) instance_destroy(_all[i]);
}

