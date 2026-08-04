if (keyboard_check_pressed(vk_f1)) {
    global.anim_debug_depth = variable_global_exists("anim_debug_depth")
        ? !global.anim_debug_depth : true;   // F1: paint-order + depth overlay
}

// F3: the cast-geometry overlay -- the measured shadow edges and the lamp's two rays
// through them. Drawn in Draw_0; see the note there.
if (keyboard_check_pressed(vk_f3)) {
    global.anim_debug_cast = variable_global_exists("anim_debug_cast")
        ? !global.anim_debug_cast : true;
}

// F2: the exhaustive flicker/mirror sweep, at the CURRENT dial setting among the rest.
// It is off the boot path because it takes about forty seconds (see Create), so it is worth
// saying so on screen first -- otherwise the freeze it causes looks like the bug.
if (keyboard_check_pressed(vk_f2)) {
    shadow_sweep = "running...";
} else if (shadow_sweep == "running...") {
    var _t0 = get_timer();
    var _err = anim_shadow_flicker_test();
    var _ms  = string_format((get_timer() - _t0) / 1000, 1, 0) + " ms";
    shadow_sweep = (_err == "") ? ("sweep PASS (" + _ms + ")") : ("sweep FAIL " + _err);
    show_debug_message("SHADOW " + shadow_sweep);
}
// Nothing exists until the data is in. The room holds only this controller, so no object
// can read a rig before it is loaded -- which is what makes async loading safe.
if (!global.anim_ready) exit;
if (!spawned) {
    spawned = true;
    var _pl = instance_create_depth(room_width / 2, room_height / 2, 0, obj_demo_player);
    var _ho = instance_create_depth(room_width / 2 + 240, room_height / 2 - 60, 0, obj_demo_horse);
    // Start mounted -- exactly the pair of assignments the ride menu makes below, and for
    // the same reason both go through locals: `some_instance.field = x` is not a valid
    // assignment target in GML. Nothing here places or poses the rider; it pulls itself
    // onto the saddle and swaps to its ride clip on its own next Step.
    _ho.rider = _pl.id;
    _pl.mount = _ho;
    view_object[0] = obj_demo_player;      // the room's follow target, now that it exists
    demo_spawn(3);
    demo_add_light(room_width / 2 - 150, room_height / 2 - 90);
    // Close enough to the horse's spawn that it casts from the first frame -- the iso
    // metric doubles the y separation, so a light "just below" is further than it looks.
    // This is the one that rises and sinks; the other stays put to compare against.
    demo_add_light(room_width / 2 + 250, room_height / 2 + 10, true);
}

// Height is what sets shadow length, so the rising lamp is the whole demonstration: its
// shadows stretch as it sinks and pull in as it climbs. Eased with a sine so it lingers at
// both ends rather than sweeping through them.
for (var i = 0; i < array_length(global.demo_lights); i++) {
    var _L = global.demo_lights[i];
    if (!_L.rise) continue;
    _L.t += LIGHT_RISE_SPEED * (delta_time / 1000000);
    _L.h = LIGHT_H_MIN + (LIGHT_H_MAX - LIGHT_H_MIN) * (0.5 - 0.5 * cos(_L.t));
}

// B, not N or L: those keys move shadow settings below, and a key that both spawned a lamp
// and moved a shadow setting made every experiment with one contaminate the other.
if (keyboard_check_pressed(ord("B"))) demo_add_light(mouse_x, mouse_y);

// The shadow tuning keys are RETIRED. The width minimum stopped being a global dial and
// became a property of the horse instance (`shadow_minw`, obj_demo_horse/Create_0), the
// fold rests at zero and the edge gap at its macro -- and live keys on those values meant
// every screenshot came from unknown settings, which repeatedly turned tuning sessions
// into ghost hunts. The blocks are kept, disabled, so re-enabling one for an experiment
// is uncommenting it rather than re-deriving it.
//
// M/N minimum width -- superseded by per-instance shadow_minw:
//     var _thin_step = keyboard_check(vk_shift) ? 2 : 0.5;
//     if (keyboard_check(ord("M"))) {
//         global.anim_shadow_thin = max(0, global.anim_shadow_thin - _thin_step);
//     }
//     if (keyboard_check(ord("N"))) {
//         global.anim_shadow_thin = min(31, global.anim_shadow_thin + _thin_step);
//     }
// O/P blanket fold -- stays at zero, the lean it dialled is what caused the mirrors:
//     var _fold_step = keyboard_check(vk_shift) ? 0.02 : 0.005;
//     if (keyboard_check(ord("O"))) {
//         global.anim_shadow_min_fold = max(0, global.anim_shadow_min_fold - _fold_step);
//     }
//     if (keyboard_check(ord("P"))) {
//         global.anim_shadow_min_fold = min(1.2, global.anim_shadow_min_fold + _fold_step);
//     }

// THRONE_SHOTS=<n>: contact-sheet mode. Clears the room to one horse under one lamp, steps
// it through n evenly spaced facings, saves a screenshot of each and quits. Shadow bugs are
// reported from the screen and argued about from numbers, and the numbers kept agreeing
// with a model that did not match the renderer -- so being able to LOOK at a full turn,
// cheaply and identically each time, is worth the twenty lines it costs. Inert without the
// variable set -- and it has to genuinely survive that, since this runs on every launch:
// environment_get_variable returns "" for a variable that is not set and real("") THROWS,
// which took down the ordinary demo on the first frame the horse existed.
var _shots_env = environment_get_variable("THRONE_SHOTS");
var _shots = (_shots_env != "" && string_digits(_shots_env) == _shots_env)
           ? real(_shots_env) : 0;
if (_shots > 0) {
    var _h = instance_find(obj_demo_horse, 0);
    if (_h != noone) {
        if (!variable_instance_exists(id, "shot_n")) { shot_n = 0; shot_t = 0; }
        // Unhook the rider BEFORE destroying it. The demo spawns mounted, and a horse still
        // holding a destroyed rider id is not `noone`, so the pair draw reads a dead
        // instance and the run dies before it can save anything.
        _h.rider = noone;
        with (obj_demo_player)   { mount = noone; instance_destroy(); }
        with (obj_demo_skeleton) instance_destroy();
        var _cam = view_camera[0];
        _h.x = camera_get_view_x(_cam) + camera_get_view_width(_cam) * 0.5;
        _h.y = camera_get_view_y(_cam) + camera_get_view_height(_cam) * 0.5;
        // One lamp, close enough to be well inside its radius: the iso metric doubles the y
        // separation, so a light placed by eye is further away than it looks and a caster
        // out of range casts nothing at all.
        global.demo_lights = [];
        var _face;
        if (environment_get_variable("THRONE_ORBIT") == "1") {
            // The reported scenario: RUNNING A LAP AROUND THE LAMP rather than turning on
            // the spot. The lamp stays put in the middle of the view and the horse walks a
            // ground-space circle round it, facing along its own travel -- so its facing
            // and the lamp's direction move together, which is the pairing that inverted
            // the shadow twice a lap. A screen circle would not do: the 2:1 metric makes
            // the ground path an ellipse, and the crossings sit at different places on it.
            var _orb = shot_n * (360 / _shots);
            var _rad = 130;
            demo_add_light(_h.x, _h.y);
            _h.x += _rad * dcos(_orb);
            _h.y += _rad * dsin(_orb) * 0.5;
            _face = point_direction(0, 0, -_rad * dsin(_orb), _rad * dcos(_orb) * 0.5);
        } else {
            demo_add_light(_h.x - 200, _h.y - 30);
            _face = shot_n * (360 / _shots);
        }
        _h.direction = _face;
        _h.face      = _face;
        _h.clip      = _h.rig.gait.idle;
        _h.play      = 0;                      // same pose every shot, so only facing varies
        shot_t++;
        if (shot_t > 3) {                      // a few frames for the facing ease to settle
            // Zero-padded by hand: string_format pads with SPACES, which lands the shots
            // under names like "facing_ 15.png" and sorts them wrongly besides.
            var _tag = string(round(shot_n * (360 / _shots)));
            while (string_length(_tag) < 3) _tag = "0" + _tag;
            screen_save("facing_" + _tag + ".png");
            shot_t = 0;
            shot_n++;
            if (shot_n >= _shots) game_end();
        }
    }
}

// K/L edge gap -- RETIRED with the other shadow dials (see the note above the M/N block);
// the gap holds at ANIM_SHADOW_EDGE. Kept for uncommenting into an experiment:
//     var _edge_step = keyboard_check(vk_shift) ? 4 : 1;
//     if (keyboard_check(ord("K"))) {
//         global.anim_shadow_edge = max(0, global.anim_shadow_edge - _edge_step);
//     }
//     if (keyboard_check(ord("L"))) {
//         global.anim_shadow_edge = min(240, global.anim_shadow_edge + _edge_step);
//     }

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
    hold       = 0;

    for (var i = 0; i < array_length(buttons); i++) {
        if (point_in_rectangle(_gx, _gy, 16 + i * 92, 44, 96 + i * 92, 74)) {
            click_used = true;
            var _n = buttons[i][1];
            if (is_string(_n)) {
                // Two loops of the wave clip; the player Step owns the how and the when.
                var _pw = instance_find(obj_demo_player, 0);
                if (_pw != noone) _pw.wave_t = 2.7;
            }
            else if (_n == 0) { demo_kill(instance_number(obj_demo_skeleton)); demo_spawn(3); }
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

// Holding left on a horse is the second way into the ride menu, for anyone without a right
// button. It fires once, on the frame the press crosses RIDE_HOLD, and then claims the
// press so the drag below stops steering -- otherwise the player would keep walking at the
// horse underneath the open menu.
#macro RIDE_HOLD 24

if (mouse_check_button(mb_left) && !click_used) {
    hold++;
    if (hold == RIDE_HOLD) {
        var _h = demo_horse_at(mouse_x, mouse_y);
        if (_h != noone) {
            menu_open   = true;
            menu_target = _h;
            menu_x      = _gx;
            menu_y      = _gy;
            click_used  = true;
            var _ps = instance_find(obj_demo_player, 0);
            _ps.target_x = _ps.x;      // and stop where it is, rather than walking on
            _ps.target_y = _ps.y;
        }
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
    var _near = demo_horse_at(mouse_x, mouse_y);
    menu_open = (_near != noone);
    if (menu_open) { menu_target = _near; menu_x = _gx; menu_y = _gy; }
}




