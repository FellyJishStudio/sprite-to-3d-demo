/// HUD. fps_real is the one that tells you what the animation actually costs -- fps is
/// capped at the room speed, fps_real is how many frames the machine could have managed.
draw_set_colour(c_white);
if (!global.anim_ready) {
    draw_text(16, 12, global.anim_error != ""
        ? ("Failed to load " + global.anim_error)
        : ("Loading" + string_repeat(".", 1 + (get_timer() div 400000) mod 3)));
    exit;
}
// The shadow dials are retired, so the HUD shows the one number still in play: the horse's
// own width floor, read off the instance it now lives on. Everyone else casts unwidened.
var _hm = instance_find(obj_demo_horse, 0);
draw_text(16, 12, "fps " + string(fps) + "     fps_real " + string(fps_real)
                + "     skeletons " + string(instance_number(obj_demo_skeleton))
                + "     zoom " + string_format(zoom, 1, 1)
                + "     horse minw " + ((_hm != noone)
                      ? string_format(_hm[$ "shadow_minw"] ?? 0, 2, 1) : "-"));

// F2's sweep, and the warning that pressing it freezes the demo for about forty seconds.
// "running..." is drawn on the frame BEFORE the sweep starts, so the screen actually shows
// it -- run it in the same step as the keypress and the window is already locked up by the
// time anything is painted, which is indistinguishable from a crash.
if (shadow_sweep != "") {
    var _sc = c_red;
    if (shadow_sweep == "running...")           _sc = c_yellow;
    else if (string_pos("PASS", shadow_sweep))  _sc = c_lime;
    draw_set_colour(_sc);
    draw_text(16, 28, "F2 " + shadow_sweep);
    draw_set_colour(c_white);
}

// A sprite that fails to resolve is only noticed during the final parse, one frame before
// anim_ready goes true -- so the loading screen never gets a chance to show it. Keep it on
// screen instead. This is the only visible symptom of an export having stripped a sprite
// that the rig JSON names as a string; see option_remove_unused_assets in options_main.yy.
if (global.anim_error != "") {
    draw_set_colour(c_red);
    draw_text(16, 28, "MISSING " + global.anim_error);
    draw_set_colour(c_white);
}

for (var i = 0; i < array_length(buttons); i++) {
    var _x = 16 + i * 92;
    draw_set_colour(c_black);  draw_rectangle(_x, 44, _x + 80, 74, false);
    draw_set_colour(c_white);  draw_rectangle(_x, 44, _x + 80, 74, true);
    draw_text(_x + 10, 52, buttons[i][0]);
}

draw_text(16 + array_length(buttons) * 92, 46,
          "click to move   arrows/Shift also move   wheel zooms   Space sword   T shuffle look   F3 cast overlay");
draw_text(16 + array_length(buttons) * 92, 62,
          "right-click or hold left on a horse to ride      at the cursor:  B lamp   W disco   E water   R galaxy   Q explosion");

if (menu_open) {
    var _label = (obj_demo_player.mount == noone) ? "Ride" : "Dismount";
    draw_set_colour(c_black);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, false);
    draw_set_colour(c_white);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, true);
    draw_text(menu_x + 10, menu_y + 5, _label);
}



