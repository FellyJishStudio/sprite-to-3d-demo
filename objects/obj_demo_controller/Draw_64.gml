/// HUD. fps_real is the one that tells you what the animation actually costs -- fps is
/// capped at the room speed, fps_real is how many frames the machine could have managed.
draw_set_colour(c_white);
if (!global.anim_ready) {
    draw_text(16, 12, global.anim_error != ""
        ? ("Failed to load " + global.anim_error)
        : ("Loading" + string_repeat(".", 1 + (get_timer() div 400000) mod 3)));
    exit;
}
// edge K/L is the resting gap the band fills across the ray; min w M/N is the hard floor
// under any shadow's width, the ring's diameter in anim_shadow_paint. O/P is the old
// blanket fold, kept at zero.
draw_text(16, 12, "fps " + string(fps) + "     fps_real " + string(fps_real)
                + "     skeletons " + string(instance_number(obj_demo_skeleton))
                + "     zoom " + string_format(zoom, 1, 1)
                + "     shadow O/P " + string_format(global.anim_shadow_min_fold, 1, 3)
                + "     edge K/L +" + string_format(global.anim_shadow_edge, 2, 0)
                + "   min w M/N " + string_format(global.anim_shadow_thin, 2, 1));

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
          "click to move   WASD/Shift also move   wheel zooms   Space sword   R shuffle look   B light   M/N thin band   O/P fold   K/L edge gap   F3 cast overlay");
draw_text(16 + array_length(buttons) * 92, 62,
          "right-click or hold left on a horse to ride");

if (menu_open) {
    var _label = (obj_demo_player.mount == noone) ? "Ride" : "Dismount";
    draw_set_colour(c_black);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, false);
    draw_set_colour(c_white);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, true);
    draw_text(menu_x + 10, menu_y + 5, _label);
}



