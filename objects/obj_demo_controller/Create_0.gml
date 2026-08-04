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
global.demo_booms  = [];      // live explosions; drawn in Draw End so they sit in FRONT of
                              // the characters rather than behind them at this depth
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
///
/// `life` is seconds remaining for a temporary lamp, or -1 for one that stays. An explosion
/// adds a real light rather than faking a flash, so its glare drives the same shadow pass
/// everything else does: every character in reach throws a hard shadow away from the blast
/// for as long as it burns.
/// `col` is what the lamp throws: the tint of its floor pool, and of the sheen it puts on
/// characters standing in it. Dim on purpose -- it is ADDED to the scene, so a saturated
/// tint at full value washes the floor out rather than lighting it.
///
/// `fx` names a pattern painted on the ground beneath it, or "" for a plain lamp. `ft` is
/// that pattern's own clock, seeded at random so two of the same kind never run in lockstep.
function demo_add_light(_x, _y, _rise = false, _life = -1, _r = 340, _h = LIGHT_H_MID) {
    // Room for a couple of blasts on top of the room's own lamps. The ceiling is cost, not
    // taste: shadow work is per caster PER LIGHT, so each one is a full silhouette pass for
    // every character in range.
    if (array_length(global.demo_lights) >= 8) return undefined;
    var _L = { x: _x, y: _y, h: _h, r: _r, rise: _rise, t: 0,
               life: _life, life0: max(_life, 0.001), r0: _r,
               col: LIGHT_COL_WARM, fx: "", ft: random(20) };
    array_push(global.demo_lights, _L);
    return _L;
}

/// One of the three effect lamps. They are ORDINARY lights -- same struct, same attenuation,
/// same cast-shadow pass -- carrying a tint and a pattern painted on the floor. Nothing about
/// them is special-cased in the renderer, so a disco ball throws real shadows off every
/// character in reach, coloured light onto the ones close to it, and the shadows swing.
function demo_fx_light(_x, _y, _fx) {
    var _L = demo_add_light(_x, _y);
    if (_L == undefined) return undefined;      // at the lamp ceiling; see demo_add_light
    _L.fx = _fx;
    switch (_fx) {
        // Hung high and reaching wide, like a ball over a floor: height is what stretches
        // the shadows it throws, and what flings its spots out into a ring worth seeing.
        case "disco":  _L.h = 150; _L.r = 420; _L.col = make_colour_rgb(74, 40, 96);  break;
        // Low and cool -- a projector sitting just above the floor it is aimed at.
        case "water":  _L.h =  44; _L.r = 400; _L.col = make_colour_rgb(26, 76, 104); break;
        case "galaxy": _L.h = 120; _L.r = 460; _L.col = make_colour_rgb(56, 34, 92);  break;
    }
    _L.r0 = _L.r;                               // only read by the temporary-light decay
    return _L;
}

/// A fireball's colour at `_p` of its life: white-hot, through yellow and orange, to a deep
/// red as it burns out. Ramped rather than a single tint because a fire that holds one
/// colour reads as a coloured blob; the travel from white to red is what makes it fire.
function demo_fire_col(_p) {
    if (_p < 0.30) return merge_colour(make_colour_rgb(255, 255, 236),
                                       make_colour_rgb(255, 216,  72), _p / 0.30);
    if (_p < 0.62) return merge_colour(make_colour_rgb(255, 216,  72),
                                       make_colour_rgb(255, 116,  20), (_p - 0.30) / 0.32);
    return merge_colour(make_colour_rgb(255, 116, 20),
                        make_colour_rgb(196,  28,  8), (_p - 0.62) / 0.38);
}

/// Scale a colour's brightness. Under additive blending dimming toward black IS an alpha --
/// black adds nothing -- which is why the fire fades by scaling colour instead of by
/// draw_set_alpha: the gradient shapes already spend the alpha channel on their soft edges.
/// Clamped because the light pools scale UP (a low lamp concentrates its pool).
function demo_col_scale(_c, _f) {
    return make_colour_rgb(min(255, colour_get_red(_c)   * _f),
                           min(255, colour_get_green(_c) * _f),
                           min(255, colour_get_blue(_c)  * _f));
}

/// The same hue at full brightness, for the bulb itself. Pool tints are deliberately dim
/// (see demo_add_light); the fixture throwing them should still be the brightest thing in
/// the frame, so it takes the hue and drops the dimming.
function demo_col_boost(_c) {
    var _m = max(colour_get_red(_c), colour_get_green(_c), colour_get_blue(_c));
    return (_m < 1) ? c_white : demo_col_scale(_c, 255 / _m);
}

/// Paint one effect lamp's pattern on the ground. Called from the light loop in Draw, inside
/// the same ADDITIVE pass as the pools -- which is what lets these overlap each other and the
/// warm lamps without any of them muddying: light adds, and each shape's own centre-to-black
/// gradient is a free radial falloff, so nothing needs a sprite or shows a rim.
///
/// All of it is drawn on the 2:1 isometric floor, y spread halved, like every other ground
/// figure in the demo -- these are patterns lying ON the ground, not billboards standing on it.
function demo_fx_paint(_L) {
    switch (_L.fx) {
        case "disco":  demo_fx_disco(_L);  break;
        case "water":  demo_fx_water(_L);  break;
        case "galaxy": demo_fx_galaxy(_L); break;
    }
}

/// A mirror ball: coloured spots flung across the floor, sweeping round.
///
/// Two counter-turning rings rather than one. A single ring of evenly spaced spots reads as
/// a wheel -- the eye locks onto it and it stops looking like scattered light -- and each
/// spot breathes on its own frequency so the pattern never quite repeats.
function demo_fx_disco(_L) {
    var _R = _L.r * 0.44, _spin = _L.ft * 46;
    for (var i = 0; i < 14; i++) {
        var _p   = i / 14;
        var _in  = (i mod 2);                        // the inner ring, turning the other way
        var _ang = _p * 720 + _spin * (_in ? -0.6 : 1);
        var _rad = _R * (_in ? 0.52 : 1) * (0.84 + 0.16 * dsin(_spin * 2.7 + i * 57));
        var _sx  = _L.x + dcos(_ang) * _rad;
        var _sy  = _L.y + dsin(_ang) * _rad * 0.5;
        var _sz  = 8 + 4.5 * dsin(_spin * 3.4 + i * 91);
        // Round the wheel by position, and the whole wheel drifts through the spectrum -- so
        // one spot is never the same colour twice on consecutive passes.
        var _c   = make_colour_hsv((_p * 255 + _L.ft * 30) mod 256, 232, 255);
        draw_ellipse_colour(_sx - _sz, _sy - _sz * 0.5, _sx + _sz, _sy + _sz * 0.5,
                            _c, c_black, false);
    }
}

/// A water projector: caustics. Rings running outward, and a mesh of cells crawling beneath
/// them. Both together are what reads as light through a moving surface -- rings alone are a
/// sonar ping, cells alone are static.
function demo_fx_water(_L) {
    var _R = _L.r * 0.5, _cw = make_colour_rgb(96, 196, 240);
    for (var i = 0; i < 5; i++) {
        // Five rings a fifth of a cycle apart on one sweep, so a ring is always arriving.
        var _p  = frac(_L.ft * 0.4 + i / 5);
        var _rr = _R * (0.1 + 0.9 * _p);
        var _f  = (1 - _p) * min(1, _p * 5);         // in off the middle, out at the rim
        var _rc = demo_col_scale(_cw, _f * 0.62);
        draw_ellipse_colour(_L.x - _rr, _L.y - _rr * 0.5,
                            _L.x + _rr, _L.y + _rr * 0.5, _rc, _rc, true);
    }
    for (var i = 0; i < 16; i++) {
        // Fixed seats on the floor -- golden-ratio radii, so they never line themselves up
        // into rings of their own -- each drifting on its own pair of frequencies.
        var _rr = _R * (0.2 + 0.66 * frac(i * 0.618));
        var _cx = _L.x + dcos(i * 22.5) * _rr       + dsin(_L.ft * 74 + i * 41) * 13;
        var _cy = _L.y + dsin(i * 22.5) * _rr * 0.5 + dcos(_L.ft * 61 + i * 27) * 6;
        var _s  = 5 + 3 * dsin(_L.ft * 96 + i * 63);
        draw_ellipse_colour(_cx - _s * 1.6, _cy - _s * 0.6,
                            _cx + _s * 1.6, _cy + _s * 0.6,
                            demo_col_scale(_cw, 0.55), c_black, false);
    }
}

/// A galaxy: two trailing spiral arms of stars turning about a hot core.
///
/// The arms TRAIL -- a star further out sits further back around the turn -- which is what
/// makes the whole figure read as rotating. Spokes at fixed angles merely spin.
function demo_fx_galaxy(_L) {
    var _R = _L.r * 0.5, _spin = _L.ft * 13;
    var _cr = 12 + 2 * dsin(_L.ft * 90);
    draw_ellipse_colour(_L.x - _cr, _L.y - _cr * 0.5, _L.x + _cr, _L.y + _cr * 0.5,
                        make_colour_rgb(255, 242, 224), c_black, false);
    for (var a = 0; a < 2; a++) {
        for (var i = 1; i <= 34; i++) {
            var _p   = i / 34;
            var _ang = a * 180 + _p * 250 + _spin;
            // Scattered off the arm by a fixed amount per star, so an arm is a smear of
            // stars rather than a drawn line.
            var _rr  = _R * power(_p, 0.78) + dsin(i * 137.5 + a * 61) * _R * 0.07;
            var _sx  = _L.x + dcos(_ang) * _rr;
            var _sy  = _L.y + dsin(_ang) * _rr * 0.5;
            // White-hot at the core, through magenta, to deep blue at the rim.
            var _c   = (_p < 0.45)
                     ? merge_colour(make_colour_rgb(255, 238, 210),
                                    make_colour_rgb(232,  86, 226), _p / 0.45)
                     : merge_colour(make_colour_rgb(232,  86, 226),
                                    make_colour_rgb( 70, 104, 255), (_p - 0.45) / 0.55);
            var _s   = 4.4 - 2.2 * _p;
            draw_ellipse_colour(_sx - _s, _sy - _s * 0.5, _sx + _s, _sy + _s * 0.5,
                                demo_col_scale(_c, 0.9 - 0.35 * _p), c_black, false);
        }
    }
}

/// Set off a blast at (_x, _y): a cluster of fireballs, a spray of sparks, a ground flash,
/// and a strong short-lived light.
///
/// Every puff's angle, distance, size, rise and start delay is rolled ONCE, here, and kept.
/// Rolling them per frame would make the fire boil into noise instead of expanding, and it
/// is the staggered start delays that make it bloom rather than appear all at once.
function demo_boom(_x, _y) {
    var _puff = [];
    repeat (18) array_push(_puff, {
        ang  : random(360),
        dist : 8 + random(52),
        size : 15 + random(30),
        rise : 12 + random(38),        // fire lifts as it expands
        t0   : random(0.18)            // staggered, so it blooms
    });
    var _spark = [];
    repeat (30) array_push(_spark, {
        ang  : random(360),
        spd  : 120 + random(260),
        up   : 40 + random(90),
        size : 1 + random(2),
        t0   : random(0.07)
    });
    array_push(global.demo_booms,
        { x: _x, y: _y, t: 0, dur: 1.25, puff: _puff, spark: _spark });
    // Low and wide: height is what sets shadow length, so a blast near the floor throws the
    // long raking shadows that sell it. Outlives the fire slightly, so the light fades out
    // rather than cutting off while embers are still visible.
    demo_add_light(_x, _y, false, 1.45, 620, 30);
}

/// The band the rising lamp travels through, and how fast. The floor is kept well clear of
/// zero: h divides into the shadow length, so a lamp at ground level would ask for an
/// infinite one (the 1.6 cap in anim_light_shadow is what actually stops it, but a lamp
/// that low reads as broken rather than as low).
#macro LIGHT_H_MIN 26
#macro LIGHT_H_MAX 150
#macro LIGHT_H_MID 60
#macro LIGHT_RISE_SPEED 0.55        // radians per second
#macro LIGHT_COL_WARM make_colour_rgb(84, 66, 28)     // an ordinary lamp's tint

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


