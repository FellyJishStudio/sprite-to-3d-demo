/// Loads the pipeline data, owns the HUD, the camera zoom, the spawner and the ride menu.
/// Created first (see the room's instanceCreationOrder) so the rigs exist for everyone else.

anim_boot();          // asynchronous; the cast is spawned in Step once it finishes
randomize();
// Timed, and the time is reported: this runs before the first frame, so its cost is dead
// air on a black window. Only the cheap projection sweep is on this path. The exhaustive
// flicker/mirror grid is 173,000 samples with a search inside each -- about forty seconds
// in the VM, which read as a hang at "About to startroom" -- so it runs on demand instead:
// F2 here, or THRONE_TEST=1 in the environment for an automated run. It keeps its full
// resolution that way rather than being thinned until it stops catching things.
var _t0 = get_timer();
var _shadow_test_error = anim_shadow_regression_test();
var _shadow_test_ms = (get_timer() - _t0) / 1000;
shadow_sweep = "";            // last exhaustive-sweep result, shown on the HUD

if (_shadow_test_error == "" && environment_get_variable("THRONE_TEST") == "1") {
    _shadow_test_error = anim_shadow_flicker_test();
    var _w = global.anim_shadow_worst;
    show_debug_message("SHADOW worst jump " + string_format(_w.jump, 1, 2) + "px ("
                     + _w.where + ")   narrowest x-scale "
                     + string_format(_w.xscale, 1, 2) + " (" + _w.xwhere + ")"
                     + "   narrow " + string_format(100 * _w.narrow / max(1, _w.total), 1, 1)
                     + "% of " + string(_w.total));
}
if (_shadow_test_error != "") {
    // Logged BEFORE the dialog: show_error puts up a modal window and writes nothing to
    // stdout, so a headless or automated run just stops dead at "About to startroom" with
    // no reason given. The message is the whole value of the check.
    show_debug_message("SHADOW regression=FAIL " + _shadow_test_error);
    show_error("Shadow projection regression: " + _shadow_test_error, true);
} else {
    show_debug_message("SHADOW regression=PASS  projection 1441 samples ("
                     + string_format(_shadow_test_ms, 1, 0) + " ms)"
                     + "  -- F2 for the exhaustive flicker/mirror sweep");
}

global.anim_debug_cast = (environment_get_variable("THRONE_SHOTS") != "");
spawned = false;

// Point lights: each casts an animated shadow of every character in range (see
// anim_cast_shadows) and paints a 2:1 isometric glow pool on the ground. `h` is the
// light's height above the ground plane -- what shadow length is projected against.
global.demo_lights = [];
shadow_surfs = [];            // one scratch surface PER LIGHT for the cast-shadow layer:
                              // a pool fades other lights' shadows, never its own (Draw)
// One reusable card receives the exact assembled palette before each cast projection.
// It is shared serially by every character/light; only the per-light destination persists.
caster_size = 256;
caster_surf = -1;
caster_cam = camera_create();
/// `h` is the lamp's height above the ground plane, and it is the only thing that sets how
/// long a shadow gets: anim_light_shadow casts a caster's height times ground-distance over
/// h. `rise` makes this one climb and sink so that relationship is visible -- shadows
/// stretching out as it drops, pulling in as it lifts. Exactly one lamp in the room gets
/// it; a second, fixed one is left alone as a reference to compare against.
function demo_add_light(_x, _y, _rise = false) {
    if (array_length(global.demo_lights) >= 6) return;      // enough for a demo room
    array_push(global.demo_lights,
        { x: _x, y: _y, h: LIGHT_H_MID, r: 340, rise: _rise, t: 0 });
}

/// The band the rising lamp travels through, and how fast. The floor is kept well clear of
/// zero: h divides into the shadow length, so a lamp at ground level would ask for an
/// infinite one (the 1.6 cap in anim_light_shadow is what actually stops it, but a lamp
/// that low reads as broken rather than as low).
#macro LIGHT_H_MIN 26
#macro LIGHT_H_MAX 150
#macro LIGHT_H_MID 60
#macro LIGHT_RISE_SPEED 0.55        // radians per second

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


