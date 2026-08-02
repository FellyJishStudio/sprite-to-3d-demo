/// HUD. fps_real is the one that tells you what the animation actually costs -- fps is
/// capped at the room speed, fps_real is how many frames the machine could have managed.
draw_set_colour(c_white);
if (!global.anim_ready) {
    draw_text(16, 12, global.anim_error != ""
        ? ("Failed to load " + global.anim_error)
        : ("Loading" + string_repeat(".", 1 + (get_timer() div 400000) mod 3)));
    exit;
}
draw_text(16, 12, "fps " + string(fps) + "     fps_real " + string(fps_real)
                + "     skeletons " + string(instance_number(obj_demo_skeleton))
                + "     zoom " + string_format(zoom, 1, 1));

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
          "click to move   WASD/Shift also move   wheel zooms   Space sword   R shuffle look");
draw_text(16 + array_length(buttons) * 92, 62,
          "right-click a horse to ride");

if (menu_open) {
    var _label = (obj_demo_player.mount == noone) ? "Ride" : "Dismount";
    draw_set_colour(c_black);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, false);
    draw_set_colour(c_white);  draw_rectangle(menu_x, menu_y, menu_x + 96, menu_y + 26, true);
    draw_text(menu_x + 10, menu_y + 5, _label);
}
