if (keyboard_check_pressed(vk_f1)) {
    global.anim_debug_depth = variable_global_exists("anim_debug_depth")
        ? !global.anim_debug_depth : true;   // F1: paint-order + depth overlay
}
// Nothing exists until the data is in. The room holds only this controller, so no object
// can read a rig before it is loaded -- which is what makes async loading safe.
if (!global.anim_ready) exit;
if (!spawned) {
    spawned = true;
    instance_create_depth(room_width / 2, room_height / 2, 0, obj_demo_player);
    instance_create_depth(room_width / 2 + 240, room_height / 2 - 60, 0, obj_demo_horse);
    view_object[0] = obj_demo_player;      // the room's follow target, now that it exists
    demo_spawn(3);
}

var _gx = device_mouse_x_to_gui(0), _gy = device_mouse_y_to_gui(0);

/// Mouse wheel zoom, from obj_camera/Step_0.gml: 0.1 per notch, floor 0.2. Its ceiling is a
/// flat 5; here it is whatever still fits inside the room.
var _wheel = mouse_wheel_down() - mouse_wheel_up();
if (_wheel != 0) {
    zoom = clamp(zoom + _wheel * 0.1, 0.2, zoom_max);
    camera_set_view_size(view_camera[0], round(base_w * zoom), round(base_h * zoom));
}

if (mouse_check_button_pressed(mb_left)) {
    click_used = false;

    for (var i = 0; i < array_length(buttons); i++) {
        if (point_in_rectangle(_gx, _gy, 16 + i * 92, 44, 96 + i * 92, 74)) {
            click_used = true;
            var _n = buttons[i][1];
            if      (_n == 0) { demo_kill(instance_number(obj_demo_skeleton)); demo_spawn(3); }
            else if (_n > 0)    demo_spawn(_n);
            else                demo_kill(-_n);
        }
    }

    if (!click_used && menu_open) {
        click_used = true;
        if (point_in_rectangle(_gx, _gy, menu_x, menu_y, menu_x + 96, menu_y + 26)) {
            // Both ends of the link go through a local: `some_instance_var.field = x`
            // is not a valid assignment target in GML.
            var _p = instance_find(obj_demo_player, 0);
            var _h = _p.mount;
            if (_h != noone) { _h.rider = noone; _p.mount = noone; }
            else {
                var _t = menu_target;
                _t.rider = _p.id;
                _p.mount = _t;
            }
        }
        menu_open = false;
    }

}

// Anything not taken by the UI steers. The client re-reads the HELD button rather than the
// press edge (obj_player/Step_0.gml:1509), so dragging the cursor keeps the character
// chasing it; a click closer than min_ground_click_distance means "stop here" (:1680-1693).
if (mouse_check_button(mb_left) && !click_used) {
    var _pl  = instance_find(obj_demo_player, 0);
    var _far = (point_distance(_pl.x, _pl.y, mouse_x, mouse_y) >= 6);
    _pl.target_x = _far ? mouse_x : _pl.x;
    _pl.target_y = _far ? mouse_y : _pl.y;
}

if (mouse_check_button_pressed(mb_right)) {
    // These characters are drawn bone by bone, not from sprite_index, so their collision
    // masks bear no relation to what is on screen -- spr_horse_body_middle's is 21x17px and
    // sits *below* the drawn horse, so instance_position() almost never hits it. Pick the
    // nearest horse to the cursor instead.
    var _near = instance_nearest(mouse_x, mouse_y, obj_demo_horse);
    menu_open = (_near != noone)
             && (point_distance(mouse_x, mouse_y, _near.x, _near.y - 18) <= 34);
    if (menu_open) { menu_target = _near; menu_x = _gx; menu_y = _gy; }
}
