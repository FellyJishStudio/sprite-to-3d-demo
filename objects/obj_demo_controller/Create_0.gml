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
global.demo_booms  = [];      // live explosions, strikes and smoke: all drawn in Draw End so
global.demo_bolts  = [];      // they sit in FRONT of the characters rather than behind them
global.demo_smoke  = [];      // at this depth
global.demo_cracks  = [];     // ...and fissures, which are the exception: a crack is IN the
                              // floor, so it is drawn under everything and the horse
                              // standing over it covers it. Only embers rise into Draw End.
global.demo_rain    = false;  // Z toggles the weather
global.demo_drops   = [];     // in the air, drawn in front of everything
global.demo_ripples = [];     // where they landed, drawn on the floor with the fissures
// Snow (V) settles and STAYS. One layer only: the ground is divided into cells and a cell
// either holds a flake or it does not, so falling snow builds a covering rather than an
// ever-thickening drift. The map is cell key -> index into demo_settled, which is what makes
// clearing a footprint cheap: a step touches a dozen cells, and looking those up beats
// scanning a field of two thousand flakes by three orders of magnitude.
global.demo_fires     = [];   // G: bonfires, which burn until cleared
global.demo_meteors   = [];   // V: falling, until they hit
global.demo_glaciers  = [];   // H: a block of ice on its way down
global.demo_shards    = [];   // ...and what is left of it, under real physics
// Burn palettes, hottest first. Anything that burns walks one of these (demo_ramp); a
// meteor picks one at random on the way down and its blast and crater keep it, so the
// impact belongs to the thing that made it.
global.pal_fire = [make_colour_rgb(255, 255, 236), make_colour_rgb(255, 216, 72),
                   make_colour_rgb(255, 116,  20), make_colour_rgb(196,  28,  8)];
global.pal_red  = [make_colour_rgb(255, 242, 232), make_colour_rgb(255, 130, 96),
                   make_colour_rgb(232,  42,  30), make_colour_rgb(126,  10,  10)];
global.pal_blue = [make_colour_rgb(238, 250, 255), make_colour_rgb(150, 208, 255),
                   make_colour_rgb( 56, 124, 255), make_colour_rgb( 22,  34, 160)];
// Unit circle for demo_blob/demo_blob_verts. See the note there.
//
// EIGHT segments, not twelve. These are soft blobs with the rim at zero alpha -- the
// silhouette is a gradient, so nobody can see the polygon, and every one of them was costing
// a third more vertices than it needed. That matters: a single bonfire pushes fifty blobs a
// frame, and a shared primitive that overruns the batch drops whatever comes after it.
#macro BLOB_SEGS 8
global.blob_cos = array_create(BLOB_SEGS + 1);
global.blob_sin = array_create(BLOB_SEGS + 1);
for (var i = 0; i <= BLOB_SEGS; i++) {
    global.blob_cos[i] = dcos(i * (360 / BLOB_SEGS));
    global.blob_sin[i] = dsin(i * (360 / BLOB_SEGS));
}
global.demo_snow      = false;
global.demo_flakes    = [];   // still falling
global.demo_settled   = [];   // {x, y, k, a, live} lying on the floor
global.demo_snowmap   = ds_map_create();
global.demo_snow_dead = 0;    // marked-dead entries awaiting a sweep; see demo_snow_compact
// Uniform handles for sh_caustics, looked up once. They are stable for the life of the
// shader, and the water lamp sets five of them every frame.
caustic_u = {
    centre : shader_get_uniform(sh_caustics, "u_centre"),
    radius : shader_get_uniform(sh_caustics, "u_radius"),
    time   : shader_get_uniform(sh_caustics, "u_time"),
    tint   : shader_get_uniform(sh_caustics, "u_tint"),
    fade   : shader_get_uniform(sh_caustics, "u_fade")
};
shadow_surfs = [];            // one scratch surface PER LIGHT for the cast-shadow layer:
                              // a pool fades other lights' shadows, never its own (Draw)
// One reusable card receives the exact assembled palette before each cast projection.
// It is shared serially by every character/light; only the per-light destination persists.
caster_size = 256;
caster_surf = -1;
light_cache = [];             // rebuilt each frame in Draw; see demo_light_cache
batch_n     = 0;              // vertices in the open primitive; see demo_batch_room
// THRONE_PROF=1: a per-section timing breakdown on the HUD. Off by default and costing
// nothing then -- but with a dozen systems drawing every frame, "which one is slow" is a
// question worth being able to answer with a number instead of a guess.
prof_on = (environment_get_variable("THRONE_PROF") == "1");
prof_ground = 0; prof_pools = 0; prof_shadow = 0; prof_front = 0;
view_x0     = 0;              // the camera rect, cached once a frame; see demo_view_cache
view_y0     = 0;
view_x1     = 0;
view_y1     = 0;
beam_cache  = [];             // ...and every live laser beam, as a 3D segment
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
/// `tint` says the colour is the point: it then reaches the SHEEN as well, so characters
/// standing in the light take its colour instead of the fixed warm an ordinary lamp throws.
///
/// `fx` names a pattern painted on the ground beneath it, or "" for none. `ft` is that
/// pattern's own clock, seeded at random so two of the same kind never run in lockstep.
///
/// `glyph` draws the stem-and-bulb fixture. A blast or a lightning strike IS the light --
/// there is no lamp standing there -- so they turn it off.
///
/// `pool` draws the round glow on the floor. A fissure turns it off: its light comes out of
/// a ragged split, and a smooth ellipse centred on it announced itself as a circle that had
/// nothing to do with the shape actually glowing. The bloom along its own seams lights the
/// ground instead, in the shape of the thing doing the lighting.
///
/// `smax` caps how far a shadow may be thrown, as a multiple of the caster's height. The
/// cap exists because length is ground-distance over lamp height, which runs away as a
/// lamp approaches the floor. A blast sitting ON the floor is exactly that case and wants
/// the long raking shadows it implies, so it raises its own ceiling rather than everyone's.
///
/// `pow` is how BRIGHT the light is, as a multiple of an ordinary lamp, and it does two
/// things: it deepens the shadows this light stamps, and -- as a RATIO against the other
/// lamp's -- it decides how far another light may wash them out. So a strike drives its
/// shadows straight through the room's lamps while erasing theirs. Reach (`r`) is a poor
/// stand-in for it: under a 1 - d/r falloff a bigger radius mostly means further rather
/// than brighter, and an explosion is overwhelmingly the second thing.
///
/// UNCAPPED, by request. There used to be a ceiling of eight, and what it actually bought
/// was silent failure: past it, every W/E/R/Q/A did nothing at all with no way to tell why.
/// The cost it was guarding is real and unchanged -- shadow work is per caster PER LIGHT,
/// so each light is a full silhouette pass for every character in range, plus one
/// view-sized surface -- so the light count is on the HUD next to fps_real, where the price
/// can be watched instead of guessed at.
function demo_add_light(_x, _y, _rise = false, _life = -1, _r = 340, _h = LIGHT_H_MID) {
    var _L = { x: _x, y: _y, h: _h, r: _r, rise: _rise, t: 0,
               life: _life, life0: max(_life, 0.001), r0: _r,
               col: LIGHT_COL_WARM, tint: false, fx: "", ft: random(20),
               glyph: true, pool: true, smax: 1.6, pow: 1, pow0: 1 };
    array_push(global.demo_lights, _L);
    return _L;
}

/// One of the three effect lamps. They are ORDINARY lights -- same struct, same attenuation,
/// same cast-shadow pass -- carrying a tint and a pattern painted on the floor. Nothing about
/// them is special-cased in the renderer, so a disco ball throws real shadows off every
/// character in reach, coloured light onto the ones close to it, and the shadows swing.
function demo_fx_light(_x, _y, _fx) {
    var _L = demo_add_light(_x, _y);
    _L.fx   = _fx;
    _L.tint = true;
    switch (_fx) {
        // Hung high and reaching wide, like a ball over a floor: height is what stretches
        // the shadows it throws, and what flings its spots out into a ring worth seeing.
        case "disco":  _L.h = 150; _L.r = 420; _L.col = make_colour_rgb(74, 40, 96);  break;
        // Low and cool -- a projector sitting just above the floor it is aimed at.
        case "water":  _L.h =  44; _L.r = 400; _L.col = make_colour_rgb(26, 76, 104); break;
        case "galaxy": _L.h = 120; _L.r = 460; _L.col = make_colour_rgb(56, 34, 92);
                       _L.stars = demo_galaxy_stars();                               break;
        // A rig hung as high as it will go: the beams are drawn from the head down to the
        // floor, so the head's height IS how much beam there is to see.
        case "laser":  _L.h = 168; _L.r = 430; _L.col = make_colour_rgb(58, 24, 76);  break;
    }
    _L.r0 = _L.r;                               // only read by the temporary-light decay
    return _L;
}

/// A four-stop ramp, walked by `_p` from 0 to 1. Burning things are ramped rather than
/// tinted because anything that holds ONE colour reads as a coloured blob; the travel from
/// white-hot through the body colour to a dark ember is what makes it read as burning.
///
/// Every palette starts near-white for the same reason -- whatever is actually on fire, the
/// hottest part of it is white, and the hue only shows as it cools.
function demo_ramp(_pal, _p) {
    if (_p < 0.30) return merge_colour(_pal[0], _pal[1], _p / 0.30);
    if (_p < 0.62) return merge_colour(_pal[1], _pal[2], (_p - 0.30) / 0.32);
    return merge_colour(_pal[2], _pal[3], (_p - 0.62) / 0.38);
}

/// Ordinary fire. Kept as its own name because most callers want exactly this.
function demo_fire_col(_p) { return demo_ramp(global.pal_fire, _p); }

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
        // Only the beams that land BEHIND the characters. The rest are drawn over them in
        // Draw End, by demo_fx_paint_front.
        case "laser":  demo_fx_laser(_L, false); break;
    }
}

/// The part of the effect lamps that belongs in FRONT of the characters -- only the laser
/// beams that land nearer the camera than anyone who could cover them. Called from Draw End,
/// already inside its additive pass.
function demo_fx_paint_front() {
    var _n = array_length(global.demo_lights);
    for (var i = 0; i < _n; i++) {
        var _L = global.demo_lights[i];
        if (_L.fx == "laser") demo_fx_laser(_L, true);
    }
}

/// A rave rig: laser beams stabbing down from the emitter head onto points that sweep the
/// floor, each on its own arc at its own rate.
///
/// Drawn as beams from the HEAD rather than as marks on the ground. What reads as a laser is
/// the beam in the air; a bright line lying on the floor reads as a painted stripe, which is
/// what the first pass of this looked like. The floor hit gets its own hot spot so both ends
/// of the beam agree about where it lands.
/// Where beam `_i` of rig `_L` lands, and what colour it is. Shared by both passes, so the
/// beams drawn behind the characters and the ones drawn in front cannot disagree about
/// where they are.
function demo_laser_beam(_L, _i) {
    var _p   = _i / 9;
    // Own arc, own rate, own phase. One shared sweep is a rigid fan turning on the spot.
    var _ang = _p * 360 + 54 * dsin(_L.ft * (34 + _i * 9) + _i * 61);
    var _rr  = _L.r * 0.5 * (0.62 + 0.38 * dsin(_L.ft * (21 + _i * 5) + _i * 23));
    return { x : _L.x + dcos(_ang) * _rr,
             y : _L.y + dsin(_ang) * _rr * 0.5,
             c : make_colour_hsv((_p * 255 + _L.ft * 44) mod 256, 245, 255) };
}

/// Is something standing at ground point (_gx, _gy) in front of everyone who could cover it?
///
/// Same rule the whole demo sorts by: greater screen y is nearer the camera. Anything that
/// stands UP off the floor -- a laser beam, a bonfire -- takes the depth of the point it
/// stands on, so anyone nearer than that point covers it and anyone further away is covered
/// by it. `_rx` is how wide the thing is, `_up` how far a character's drawn body can reach
/// up into it.
///
/// Conservative when unsure: anything overlapping someone nearer goes behind EVERYTHING,
/// which costs a little (it is then also behind characters further away than it) but never
/// draws a flame over a character standing in front of the fire, which is the error that
/// actually looks wrong.
function demo_front_of(_gx, _gy, _rx, _up) {
    var _f = true;
    with (obj_demo_player)   if (y > _gy && y < _gy + _up && abs(x - _gx) < _rx +  4) _f = false;
    with (obj_demo_horse)    if (y > _gy && y < _gy + _up && abs(x - _gx) < _rx + 12) _f = false;
    with (obj_demo_skeleton) if (y > _gy && y < _gy + _up && abs(x - _gx) < _rx) _f = false;
    return _f;
}

/// One bucket of a rig's beams: `_front` true for the ones drawn over the characters in
/// Draw End, false for the ones drawn down on the ground. See demo_beam_front for the split.
function demo_fx_laser(_L, _front) {
    var _hy = _L.y - _L.h;                       // the head: height is straight screen-y
    // The whole rig blinks together now and then, the way one actually runs. Beams that
    // only ever sweep read as a lighthouse. Multiplied up and clamped so it snaps between
    // on and off instead of easing, which is what makes it read as switched rather than dimmed.
    var _blink = 0.5 + 0.5 * clamp(dsin(_L.ft * 200) * 3.5, -1, 1);
    for (var i = 0; i < 9; i++) {
        var _B = demo_laser_beam(_L, i);
        if (demo_front_of(_B.x, _B.y, 50, 80) != _front) continue;
        var _c = _B.c;
        // Dim at the head, bright where it lands: a beam is only visible in the air by what
        // it scatters off, and there is more of everything to scatter off near the floor.
        draw_line_width_colour(_L.x, _hy, _B.x, _B.y, 5,
                               demo_col_scale(_c, 0.16 * _blink),
                               demo_col_scale(_c, 0.34 * _blink));
        draw_line_width_colour(_L.x, _hy, _B.x, _B.y, 1,
                               demo_col_scale(_c, 0.55 * _blink),
                               demo_col_scale(_c, _blink));
        var _dr = 3 + 2 * _blink;
        draw_ellipse_colour(_B.x - _dr, _B.y - _dr * 0.5, _B.x + _dr, _B.y + _dr * 0.5,
                            demo_col_scale(_c, _blink), c_black, false);
    }
}

/// Build the soft-blob sprite: a radial gradient, opaque at the centre and zero at the rim.
///
/// Every soft round thing in this demo -- smoke, flame parcels, fireballs, crack bloom,
/// meteor trails -- used to be an eight-segment triangle fan, twenty-four vertices apiece,
/// for what is visually just a gradient. As a sprite it is FOUR, GameMaker batches every
/// draw of it together because they all share one texture, and it looks better besides: the
/// fan was an octagon with linear interpolation across each sector, and this is smooth.
///
/// Generated at boot rather than shipped as an asset, so there is nothing to keep in sync
/// and nothing for an export to strip. Sixty-four segments, which at any size these are
/// drawn is indistinguishable from a circle.
function demo_make_blob_sprite() {
    var _s = surface_create(BLOB_TEX, BLOB_TEX);
    surface_set_target(_s);
    draw_clear_alpha(c_black, 0);
    var _h = BLOB_TEX * 0.5;
    // One pixel in from the edge, or the sprite's own bilinear filtering samples past the
    // rim and leaves a faint square outline on every blob in the game.
    var _r = _h - 1;
    draw_primitive_begin(pr_trianglefan);
    draw_vertex_colour(_h, _h, c_white, 1);
    for (var i = 0; i <= 64; i++) {
        draw_vertex_colour(_h + dcos(i * 360 / 64) * _r,
                           _h + dsin(i * 360 / 64) * _r, c_white, 0);
    }
    draw_primitive_end();
    surface_reset_target();
    blob_spr = sprite_create_from_surface(_s, 0, 0, BLOB_TEX, BLOB_TEX, false, false, _h, _h);
    surface_free(_s);
}
#macro BLOB_TEX 64

/// A soft round blob, fading to nothing at its rim. `_sq` squashes it vertically -- 0.5 for
/// anything lying on the isometric floor, 1 for anything standing in the air.
function demo_blob(_x, _y, _r, _sq, _col, _a) {
    if (_a <= 0.004 || _r <= 0.5) return;
    var _k = _r / (BLOB_TEX * 0.5);
    draw_sprite_ext(blob_spr, 0, _x, _y, _k, _k * _sq, 0, _col, min(1, _a));
}

/// How many vertices one immediate-mode primitive may hold before it has to be flushed.
///
/// This limit is REAL and it fails silently, which is what made it expensive to find. Two
/// bonfires batched into one primitive drew only the first -- the second's vertices were
/// simply discarded -- and before that, at a slightly larger per-fire count, the overflow
/// came out as a long thin garbage triangle stretched between the two fires. That was the
/// "strange rays between two flames". Everything that batches goes through demo_batch_room,
/// so nothing can quietly run past the end again.
#macro BATCH_MAX 1200

/// How many lights may cast shadows in one frame, however many are lit. See the ranking in
/// Draw for why this exists and what it costs.
#macro SHADOW_LIGHTS_MAX 5

/// Open a batch, and reserve room in it. `demo_batch_room` flushes and reopens when the next
/// item will not fit -- always on an item boundary, never mid-shape.
function demo_batch_begin() {
    draw_primitive_begin(pr_trianglelist);
    batch_n = 0;
}
function demo_batch_room(_v) {
    if (batch_n + _v <= BATCH_MAX) { batch_n += _v; return; }
    draw_primitive_end();
    draw_primitive_begin(pr_trianglelist);
    batch_n = _v;
}
function demo_batch_end() {
    draw_primitive_end();
    batch_n = 0;
}

/// Kept as a separate name because callers used to care whether they were inside an open
/// primitive. They no longer are -- both are sprite draws now, and GameMaker batches them by
/// texture on its own -- so this is simply demo_blob. Anything that still opens a primitive
/// around a run of these must stop: a sprite cannot be drawn mid-primitive.
function demo_blob_verts(_x, _y, _r, _sq, _col, _a) {
    demo_blob(_x, _y, _r, _sq, _col, _a);
}

/// The colour of the light reaching a point in the AIR at (_px, _py) and height _pz. Sums
/// every lamp in range by the same falloff the shadows use, over the scene's own dim key.
///
/// This is what makes the smoke worth having: a puff samples this at its own position each
/// frame, so a cloud drifting across the room goes red under the red lamp, cyan over the
/// water and dark between them, and the room's lighting becomes something you can watch
/// rather than something only the floor shows.
/// CULLING. Fun mode scatters standing effects over the whole map and throws one-shots
/// around the rider, so at any moment most of what exists is nowhere near the camera. An
/// effect nobody can see should cost nothing -- no vertices, no shader, and above all no
/// silhouette pass, since shadow work is per caster PER LIGHT and dwarfs everything else.
///
/// The view rect is cached once a frame by demo_view_cache (called at the top of Draw) and
/// read by every draw below. Generous by design: `_r` is the effect's whole reach, so
/// anything that could put a single pixel on screen is kept.
function demo_view_cache() {
    var _c = view_camera[0];
    view_x0 = camera_get_view_x(_c);
    view_y0 = camera_get_view_y(_c);
    view_x1 = view_x0 + camera_get_view_width(_c);
    view_y1 = view_y0 + camera_get_view_height(_c);
}
function demo_on_screen(_x, _y, _r) {
    return (_x + _r > view_x0 && _x - _r < view_x1
         && _y + _r > view_y0 && _y - _r < view_y1);
}

/// Flatten the light list into plain numbers, once per frame.
///
/// demo_smoke_light below runs for every raindrop and every puff of smoke -- several hundred
/// calls a frame, each looping every light -- and taking each light's colour apart with
/// colour_get_* inside that loop cost more than everything else the weather does put
/// together (a shower alone took fps_real from 77 to 31). Nothing here changes per sample,
/// so none of it belongs in the sample.
/// Also flattens every live LASER BEAM into a 3D segment, so smoke and rain can be lit by
/// the individual beams passing through them rather than only by the rig's overall glow.
/// A beam runs from the emitter head down to the point it lands on; anything close to that
/// LINE catches its colour, which is what makes a cloud drifting through a rig light up
/// green here and magenta there instead of one averaged violet.
///
/// Ground units throughout: y doubled, height straight, the same metric the shadows use.
function demo_light_cache() {
    var _n = array_length(global.demo_lights);
    var _c = [];
    var _b = [];
    for (var i = 0; i < _n; i++) {
        var _L = global.demo_lights[i];
        // Only lights whose reach touches the view. This list is walked once per raindrop
        // and once per puff of smoke -- hundreds of times a frame -- so dropping the lamps
        // on the far side of the map from it is worth more than it looks.
        if (!demo_on_screen(_L.x, _L.y, _L.r)) continue;
        var _k = _L.tint ? demo_col_boost(_L.col) : make_colour_rgb(255, 236, 170);
        array_push(_c, { x: _L.x, y: _L.y, h: _L.h, r: _L.r, r2: _L.r * _L.r, pw: _L.pow,
                  inf: _L.pow * _L.r,       // for the trim below
                  cr: colour_get_red(_k), cg: colour_get_green(_k), cb: colour_get_blue(_k) });
        if (_L.fx != "laser") continue;
        var _blink = 0.5 + 0.5 * clamp(dsin(_L.ft * 200) * 3.5, -1, 1);
        if (_blink < 0.05) continue;               // the rig is between blinks
        for (var j = 0; j < 9; j++) {
            var _B = demo_laser_beam(_L, j);
            var _vx = _B.x - _L.x;
            var _vy = (_B.y - _L.y) * 2;
            var _vz = -_L.h;
            array_push(_b, {
                ax: _L.x, ay: _L.y * 2, az: _L.h,
                vx: _vx,  vy: _vy,      vz: _vz,
                // 1 / |v|^2, so the projection along the beam below is a multiply.
                iv: 1 / max(1, _vx * _vx + _vy * _vy + _vz * _vz),
                k : _blink,
                cr: colour_get_red(_B.c), cg: colour_get_green(_B.c), cb: colour_get_blue(_B.c)
            });
        }
    }
    // Keep only the strongest few for PARTICLE lighting. This list is walked hundreds of
    // times a frame; the pools, the sheen and the shadows all still use the full set. A
    // fifteenth lamp contributing a few percent to the colour of a raindrop is not worth
    // what it costs to ask it.
    if (array_length(_c) > PARTICLE_LIGHTS_MAX) {
        var _top = [];
        repeat (PARTICLE_LIGHTS_MAX) {
            var _bi = -1, _bv = -1;
            for (var i = 0; i < array_length(_c); i++) {
                if (_c[i].inf > _bv) { _bv = _c[i].inf; _bi = i; }
            }
            if (_bi < 0) break;
            array_push(_top, _c[_bi]);
            _c[_bi].inf = -1;
        }
        _c = _top;
    }
    light_cache = _c;
    beam_cache  = _b;
}
#macro PARTICLE_LIGHTS_MAX 8

/// How wide a beam's glow reaches, in ground units, and how hard it lights what it passes
/// through. Generous on both counts: a mathematically thin beam lights nothing, and the
/// point of the effect is the shaft you can see IN the smoke.
#macro BEAM_REACH 46
#macro BEAM_GAIN  1.5

function demo_smoke_light(_px, _py, _pz) {
    var _r = 0, _g = 0, _b = 0, _w = 0;
    var _n = array_length(light_cache);
    for (var i = 0; i < _n; i++) {
        var _L  = light_cache[i];
        var _dx = _px - _L.x;
        // Cheap rejects BEFORE the square root. This runs for every raindrop, every ripple,
        // every ice shard and every puff of smoke, against every light -- some twelve
        // thousand times a frame in fun mode -- and most of those pairs are nowhere near
        // each other. Two compares and a squared-distance test throw them out for a
        // fraction of what the sqrt costs.
        if (abs(_dx) >= _L.r) continue;
        var _dy = (_py - _L.y) * 2;                   // iso 1:2, as everywhere
        if (abs(_dy) >= _L.r) continue;
        var _dz = _pz - _L.h;                         // and smoke has real height
        var _q  = _dx * _dx + _dy * _dy + _dz * _dz;
        if (_q >= _L.r2) continue;
        var _d  = sqrt(_q);
        // Squared, so a puff has to be genuinely IN a pool to take its colour. Linear made
        // every cloud the average of the whole room, which is a grey-brown wash.
        var _f = (1 - _d / _L.r);
        _f = _f * _f * _L.pw;
        _r += _L.cr * _f;
        _g += _L.cg * _f;
        _b += _L.cb * _f;
        _w += _f;
    }
    // ...and every laser beam passing nearby, each on its own. Distance to the SEGMENT, not
    // to the rig: a beam only lights what it actually passes through, which is the whole
    // point -- two beams crossing one cloud leave two differently coloured shafts in it.
    var _nb = array_length(beam_cache);
    var _py2 = _py * 2;
    for (var i = 0; i < _nb; i++) {
        var _B  = beam_cache[i];
        var _wx = _px - _B.ax, _wy = _py2 - _B.ay, _wz = _pz - _B.az;
        // Project onto the beam and clamp to its ends, so the glow stops at the floor and
        // at the emitter instead of running on down the infinite line.
        var _t  = clamp((_wx * _B.vx + _wy * _B.vy + _wz * _B.vz) * _B.iv, 0, 1);
        var _ex = _wx - _B.vx * _t, _ey = _wy - _B.vy * _t, _ez = _wz - _B.vz * _t;
        var _d  = sqrt(_ex * _ex + _ey * _ey + _ez * _ez);
        if (_d >= BEAM_REACH) continue;
        var _f  = 1 - _d / BEAM_REACH;
        _f = _f * _f * _B.k * BEAM_GAIN;
        _r += _B.cr * _f;
        _g += _B.cg * _f;
        _b += _B.cb * _f;
        _w += _f;
    }
    // A weighted AVERAGE scaled by how much light there is in total -- NOT the raw sum.
    // Summing pinned every channel at 255 as soon as two lamps were in range and turned
    // every cloud into a white ball, which is the one thing smoke must never be. This keeps
    // the hue of whichever lamp dominates and lets the total decide only the brightness.
    if (_w <= 0.001) return SMOKE_AMBIENT;
    var _k = min(1, _w) / _w;
    return make_colour_rgb(min(255, 30 + _r * _k),
                           min(255, 32 + _g * _k),
                           min(255, 38 + _b * _k));
}
#macro SMOKE_AMBIENT make_colour_rgb(30, 32, 38)

/// G: a bonfire at (_x, _y). Burns until cleared, and smokes the whole time.
///
/// Its smoke goes into the ordinary smoke system rather than being drawn as part of the
/// fire, which is what makes it worth having: the puffs are then lit by every light in the
/// room INCLUDING this fire's own, so the column glows orange at the bottom where it leaves
/// the flames and turns whatever colour it drifts into further up.
function demo_fire(_x, _y) {
    var _t = [];
    // Tongues, each with its own seed, rate, phase, lean and reach. Flames read as alive
    // because no two parts of one are ever doing the same thing at the same moment.
    repeat (6) array_push(_t, {
        seed: random(1),
        rate: 0.85 + random(0.55),        // how many parcels leave the fuel per second
        ph  : random(360),
        spd : 55 + random(70),
        lean: random_range(-9, 9),
        h   : 46 + random(32),
        w   : 7 + random(5)
    });
    // Half the tint it used to carry: the pool was denser than a plain lamp's, which is
    // backwards for a campfire. The flames are the bright thing; the light it lays on the
    // ground should be a soft wash.
    var _F = { x: _x, y: _y, t: 0, tongue: _t, emit: 0,
               lcol: make_colour_rgb(52, 25, 8), light: undefined };
    array_push(global.demo_fires, _F);
    // Low and warm, and DIM AND TIGHT: a campfire lights a circle a few paces across, not
    // half the field. Height sets shadow length, and a fire on the ground throws long ones.
    // HIGHER, and with a much shorter shadow ceiling than the blast effects use. Shadow
    // length is ground distance over lamp height, so a fire sitting almost on the floor with
    // a generous ceiling threw a long thin streak of every character -- and with three or
    // four fires around someone, those streaks came out as a star of dark rays radiating
    // off them. A campfire should put a soft shadow behind things, not a searchlight.
    var _L = demo_add_light(_x, _y, false, -1, 200, 48);
    _L.col   = _F.lcol;
    _L.tint  = true;
    _L.glyph = false;
    _L.smax  = 1.3;
    _L.pow   = 1.35;
    _L.pow0  = 1.35;
    _F.light = _L;
    demo_snow_clear(_x, _y, 62);
}

/// How many parcels of burning gas are in the air per tongue at any moment. Kept modest
/// deliberately: every fire in a bucket shares one primitive, and a fat one crowds out
/// whatever is drawn after it in the same batch.
#macro FIRE_PARCELS 8

/// The bonfires. Drawn in Draw End with the rest of the burning things.
///
/// A tongue is NOT a shape that gets wobbled. That was the first version and it looked
/// wrong for a reason worth writing down: a fixed chain of blobs from the fuel to a fixed
/// tip is a rigid object, and animating it can only ever stretch and lean it. Real flame is
/// not an object at all -- it is a stream of hot gas being continuously created at the fuel,
/// rising, cooling, thinning and going out. Nothing about it persists.
///
/// So each parcel here runs its own life from 0 to 1 on a repeating cycle, offset from its
/// neighbours so one leaves the fuel as the one ahead of it dies. Over that life it climbs
/// (fast at first, the way hot gas accelerates), swells and then shrinks, cools down the
/// white-yellow-orange-red ramp, and fades to nothing before it reaches the top. The
/// silhouette you see is emergent -- no part of it is drawn.
///
/// `_front` selects which bucket to draw: flames standing in front of everyone who could
/// cover them (Draw End) or the rest (down on the ground). A fire stands UP off the floor,
/// so it takes the depth of the spot it burns on -- see demo_front_of, which the lasers use
/// for the same reason. Drawn only in Draw End, a campfire covered whoever walked in front
/// of it, which is the one thing depth ordering exists to prevent.
///
/// Does NOT touch the blend mode: both callers are inside an additive pass.
///
/// ONE primitive for every fire in the bucket, not one each. Opening and closing a primitive
/// per fire drew a long thin sliver between each pair of them -- a triangle with two corners
/// on one fire and the third on the next, which is what a batch seam looks like when it goes
/// wrong. With a single primitive there is no seam to go wrong, and it is fewer draw calls
/// besides. Any effect here that draws per-item MUST batch the same way.
///
/// The depth test is resolved for every fire BEFORE the primitive is opened. It walks the
/// characters with `with`, which changes `self`, and doing that in the middle of an open
/// primitive is asking for trouble -- nothing that touches instance scope belongs between a
/// begin and an end.
function demo_fires_paint(_front) {
    var _nf = array_length(global.demo_fires);
    if (_nf == 0) return;
    var _mine = array_create(_nf);
    for (var f = 0; f < _nf; f++) {
        var _FB = global.demo_fires[f];
        _mine[f] = demo_on_screen(_FB.x, _FB.y, 130)
                && (demo_front_of(_FB.x, _FB.y, 26, 74) == _front);
    }
    for (var f = 0; f < _nf; f++) {
        if (!_mine[f]) continue;
        var _F = global.demo_fires[f];
        // Two flickers at unrelated rates, so the fire never settles into a pulse.
        var _fl = 0.84 + 0.1 * dsin(_F.t * 330) + 0.06 * dsin(_F.t * 137);
        // The bed: a broad, dim, hot pool at the foot of the flames, so they rise out of
        // something instead of appearing in mid-air.
        demo_blob(_F.x, _F.y - 3, 22 * _fl, 0.5, make_colour_rgb(255, 122, 26), 0.5);
        demo_blob(_F.x, _F.y - 3, 12 * _fl, 0.5, make_colour_rgb(255, 226, 160), 0.6);
        for (var i = 0; i < array_length(_F.tongue); i++) {
            var _T = _F.tongue[i];
            for (var k = 0; k < FIRE_PARCELS; k++) {
                var _p = frac(_F.t * _T.rate + _T.seed + k / FIRE_PARCELS);
                // Climbing, fast off the fuel and easing as it cools.
                var _z = _T.h * power(_p, 0.78) * _fl;
                // Swelling then thinning: widest a third of the way up, gone by the top.
                var _r = _T.w * (0.5 + 1.5 * _p - 1.6 * _p * _p) * _fl;
                // The sway travels UP with the parcel -- the phase runs on its height and
                // back on time -- so the column bends as one thing instead of every parcel
                // jittering on its own. Barely moves at the fuel, whips at the top.
                var _wb = dsin(_T.ph + _p * 210 - _F.t * _T.spd) * (1.2 + 11 * _p * _p);
                demo_blob(_F.x + _wb + _T.lean * _p, _F.y - 3 - _z, _r, 1,
                          demo_fire_col(_p * 0.95),
                          power(1 - _p, 1.5) * 0.6 * _fl);
            }
        }
    }
}

#macro SMOKE_MAX 300

/// Add one puff, filling in the bookkeeping fields every puff needs whatever spawned it.
///
/// Three places make smoke -- the gun, a bonfire, a glacier impact -- and each used to write
/// the record out by hand. When the draw started caching each puff's lit colour, two of them
/// gained the fields it needed and the third did not, and the draw crashed the moment a
/// glacier landed. One door in is worth more than three tidy copies.
function demo_smoke_add(_p) {
    if (array_length(global.demo_smoke) >= SMOKE_MAX) return false;
    _p.ci  = 0;                   // frames until its light is resampled; see Draw End
    _p.col = c_white;
    array_push(global.demo_smoke, _p);
    return true;
}
#macro RAIN_MAX  220
// A snow cell is about ten ground units square -- SNOW_CELL_Y is half SNOW_CELL_X because
// screen y is half ground y under the 2:1 projection, so a square cell on the FLOOR is a
// squat rectangle in these coordinates.
#macro SNOW_CELL_X 9
#macro SNOW_CELL_Y 5
#macro SNOW_SETTLED_MAX 2600
#macro SNOW_FALLING_MAX 260

/// The cell a world point falls in, as one number. Cheaper by a wide margin than a string
/// key, and this is looked up for every flake that lands and every cell a footstep touches.
function demo_snow_key(_x, _y) {
    return floor(_x / SNOW_CELL_X) * 65536 + floor(_y / SNOW_CELL_Y);
}

/// Sweep settled snow out of an iso ellipse: a footprint, or the scorch of a blast.
///
/// Walks the CELLS the ellipse covers and looks each one up, rather than scanning the
/// snowfall. A field holds a couple of thousand flakes and a step touches about a dozen
/// cells, so this is the difference between a footprint costing nothing and costing more
/// than everything else in the frame.
///
/// Entries are marked dead rather than spliced out, because the map holds indices into the
/// array and removing one would invalidate every index after it. demo_snow_compact sweeps.
function demo_snow_clear(_x, _y, _rx) {
    if (ds_map_size(global.demo_snowmap) == 0) return;
    var _ry = _rx * 0.5;                              // iso 2:1
    var _c0 = floor((_x - _rx) / SNOW_CELL_X), _c1 = floor((_x + _rx) / SNOW_CELL_X);
    var _r0 = floor((_y - _ry) / SNOW_CELL_Y), _r1 = floor((_y + _ry) / SNOW_CELL_Y);
    for (var cx = _c0; cx <= _c1; cx++) {
        for (var cy = _r0; cy <= _r1; cy++) {
            var _k = cx * 65536 + cy;
            var _i = global.demo_snowmap[? _k];
            if (_i == undefined) continue;
            var _S  = global.demo_settled[_i];
            var _dx = (_S.x - _x) / _rx, _dy = (_S.y - _y) / _ry;
            if (_dx * _dx + _dy * _dy > 1) continue;  // the cell is in the box, not the ellipse
            _S.live = false;
            ds_map_delete(global.demo_snowmap, _k);
            global.demo_snow_dead++;
        }
    }
}

/// Sweep up the dead once a third of the field is gone, rebuilding the index map with it.
/// Amortised: walking two thousand flakes every frame to delete four of them would cost far
/// more than doing it in one pass occasionally.
function demo_snow_compact() {
    var _n = array_length(global.demo_settled);
    if (global.demo_snow_dead * 3 < _n) return;
    var _out = [];
    ds_map_clear(global.demo_snowmap);
    for (var i = 0; i < _n; i++) {
        var _S = global.demo_settled[i];
        if (!_S.live) continue;
        global.demo_snowmap[? _S.k] = array_length(_out);
        array_push(_out, _S);
    }
    global.demo_settled   = _out;
    global.demo_snow_dead = 0;
}

/// The settled covering, drawn on the floor under everything with the fissures.
///
/// Every flake in ONE primitive. At two thousand of them a draw call each would cost more
/// than the entire rest of the frame; as a single triangle list it is one batch. Each is a
/// small DIAMOND rather than a square -- the iso lattice everything else here is drawn on.
function demo_snow_paint() {
    var _n = array_length(global.demo_settled);
    if (_n == 0) return;
    var _cam = view_camera[0];
    var _x0 = camera_get_view_x(_cam) - 8, _y0 = camera_get_view_y(_cam) - 8;
    var _x1 = _x0 + camera_get_view_width(_cam) + 16;
    var _y1 = _y0 + camera_get_view_height(_cam) + 16;
    var _c  = make_colour_rgb(226, 238, 250);
    demo_batch_begin();
    for (var i = 0; i < _n; i++) {
        var _S = global.demo_settled[i];
        if (!_S.live) continue;
        if (_S.x < _x0 || _S.x > _x1 || _S.y < _y0 || _S.y > _y1) continue;
        var _a = _S.a * 0.85;
        var _w = 3.2, _h = 1.6;
        demo_batch_room(6);
        draw_vertex_colour(_S.x,      _S.y - _h, _c, _a);
        draw_vertex_colour(_S.x + _w, _S.y,      _c, _a);
        draw_vertex_colour(_S.x,      _S.y + _h, _c, _a);
        demo_batch_room(6);
        draw_vertex_colour(_S.x,      _S.y - _h, _c, _a);
        draw_vertex_colour(_S.x,      _S.y + _h, _c, _a);
        draw_vertex_colour(_S.x - _w, _S.y,      _c, _a);
    }
    draw_primitive_end();
}

/// Rain ripples, on the ground with the fissures. The drops themselves fall in Draw End,
/// in front of everything; what they leave behind belongs on the floor.
///
/// A ripple takes the colour of the light reaching the spot it landed on -- the same
/// sampling the smoke uses -- so rain falling through the red fissure light rings red and
/// rings cyan over the water projector.
function demo_rain_paint() {
    var _n = array_length(global.demo_ripples);
    if (_n == 0) return;
    gpu_set_blendmode(bm_add);
    // Ripples sample the lighting ONCE, when they land, and keep it. They live under half a
    // second and never move, so re-asking every light every frame bought nothing.
    for (var i = 0; i < _n; i++) {
        var _K  = global.demo_ripples[i];
        var _u  = _K.t / _K.dur;
        if (_K.col < 0) _K.col = demo_smoke_light(_K.x, _K.y, 2);
        // Small and faint. At three times this they read as soap bubbles blowing across the
        // field -- a raindrop's ring is a few pixels wide and gone before it is noticed.
        var _rr = 1 + 5.5 * _u;
        var _c  = demo_col_scale(_K.col, (1 - _u) * 0.3);
        draw_ellipse_colour(_K.x - _rr, _K.y - _rr * 0.5,
                            _K.x + _rr, _K.y + _rr * 0.5, _c, _c, true);
    }
    gpu_set_blendmode(bm_normal);
}

/// A shot of smoke at (_x, _y): a cone of puffs that spreads, climbs, swells and lingers.
///
/// Lingering is the point. These are slow and long-lived so a cloud has time to drift
/// through the room's lamps and be lit by each in turn -- a short puff is gone before it
/// has been anywhere. Capped, because the per-puff lighting is a loop over every light.
function demo_smoke_gun(_x, _y) {
    var _aim = random(360);                           // the barrel, rolled per shot
    repeat (26) {
        var _a  = _aim + random_range(-34, 34);
        var _sp = 30 + random(190);
        if (!demo_smoke_add({
            x  : _x + random_range(-6, 6),
            y  : _y + random_range(-3, 3),
            z  : 4 + random(10),
            vx : lengthdir_x(_sp, _a), vy: lengthdir_y(_sp, _a), vz: 14 + random(30),
            r  : 8 + random(12), grow: 10 + random(22),
            // NEGATIVE: the puff does not exist yet, and the update skips it until its
            // clock reaches zero. Released together they arrive as one ball travelling
            // outwards; released over a quarter of a second they arrive as a cloud with a
            // head and a tail, which is what a shot of smoke actually looks like.
            // Long-lived on purpose. The whole point of the smoke is that it drifts THROUGH
            // the room's lighting -- and through the laser beams, one at a time -- and none
            // of that can happen inside a puff that is gone in three seconds.
            t  : -random(0.28), life: 6.5 + random(1.6)
        })) break;                     // the cloud is full; the rest of this shot is lost
    }
}

/// F: the ground splits at (_x, _y) and something under it is burning.
///
/// The network is built from the same midpoint-displaced paths the lightning uses -- a
/// crack and a bolt are the same shape, a jagged line that forks, and the only real
/// difference is that this one lies on the floor and so is squashed 2:1 like everything
/// else on the ground.
/// `_scale` shrinks the whole network. A meteor leaves a CRATER -- a tight knot of splits
/// where it struck -- not the field-wide fissure the F key opens, and the two want an order
/// of magnitude between them.
function demo_crack(_x, _y, _pal = undefined, _lcol = undefined, _scale = 1) {
    if (_pal  == undefined) _pal  = global.pal_fire;
    if (_lcol == undefined) _lcol = make_colour_rgb(158, 34, 12);
    var _arms = [];
    // FOUR to five arms, not eight or nine. A dense web reads as a texture; a few strong
    // splits read as ground that broke.
    var _n = 4 + irandom(1);
    // Headings clustered to the SIDES. These four ground bearings come out as shallow
    // diagonals running left and right across the screen -- the 2:1 projection halves the
    // vertical component, so an arm aimed at 30 degrees on the floor travels about four
    // times as far sideways as it does up or down. Aiming them up and down the screen
    // instead made the network look like it was climbing out of the floor toward the camera.
    var _base = [30, 150, 210, 330];
    for (var i = 0; i < _n; i++) {
        var _a = _base[i mod 4] + random_range(-24, 24);
        // Reach cut to a third of what it was, and the gashes narrower again on top of that.
        // At full size the network crossed most of the view, which made it read as terrain
        // rather than as something that had just happened to one spot on the floor.
        demo_crack_branch(_arms, 0, 0, _a,
                          (29 + random(56)) * _scale,
                          (2.2 + random(2.2)) * _scale, 1);
    }
    // Normalise the root distances to 0..1 so the paint can stagger the reveal by them.
    var _far = 1;
    for (var i = 0; i < array_length(_arms); i++) _far = max(_far, _arms[i].d0);
    for (var i = 0; i < array_length(_arms); i++) _arms[i].d0 /= _far;
    // NO starburst. A fan of spikes was tried twice here and it is the wrong effect: it
    // reads as an explosion that happens to sit on top of some cracks, and what is wanted is
    // the FLOOR BREAKING. Everything this draws is the split itself.
    //
    // Vents: fixed points along the network that jet embers upward, on their own repeating
    // clocks, so the fissure keeps venting for as long as it is open rather than puffing once.
    var _vent = [];
    repeat (22) {
        var _p = _arms[irandom(array_length(_arms) - 1)].p;
        var _q = _p[irandom(array_length(_p) - 1)];
        // Embers keep a floor under their scaling -- a crater a tenth the size still throws
        // sparks a person could see, and at a literal tenth they would be sub-pixel.
        array_push(_vent, { x: _q.x * max(0.3, _scale), y: _q.y * max(0.3, _scale) * 0.5,
                            up : (50 + random(110)) * max(0.4, _scale),
                            spd: 0.45 + random(0.8), size: 1.2 + random(2.4),
                            t0 : random(1) });
    }
    array_push(global.demo_cracks,
        { x: _x, y: _y, t: 0, dur: 6.5, arms: _arms, vent: _vent, pal: _pal,
          sc: max(0.3, _scale), light: undefined });
    // Lit from BELOW: the light is in the floor, which is why it sits so low. That height
    // is also what throws the long shadows -- everything standing near a fissure is lit
    // from underneath and casts away from it across the ground.
    var _L = demo_add_light(_x, _y, false, 6.5, 460 * max(0.42, _scale), 16);
    _L.col   = _lcol;                                  // furnace red, unless tinted
    _L.tint  = true;
    _L.glyph = false;
    _L.pool  = false;      // its own seams light the ground; see demo_add_light
    _L.smax  = 2.6;
    _L.pow   = 2.2;
    _L.pow0  = 2.2;
    global.demo_cracks[array_length(global.demo_cracks) - 1].light = _L;
    demo_snow_clear(_x, _y, 280 * max(0.3, _scale));
}

/// The fissures. Drawn at the very BOTTOM of the ground pass -- before every light pool and
/// every projected pattern -- because a crack is in the floor and everything else in the
/// demo is above it: pools, caustics, laser beams, characters, smoke. Only the embers rise
/// out of it and into Draw End.
///
/// One arm as a ribbon, with a colour gradient ACROSS its width: `_ce` at both edges, `_cm`
/// down the middle, and alphas to match. `_wf` scales the width, `_oy` shifts the whole band
/// down the screen (for the near lip), and `_fade` says whether the band thins out along the
/// arm with the light or holds its own width to the tip (the rock does).
///
/// Each end uses its OWN point's normal, so consecutive quads share an edge exactly and the
/// band is continuous. Per-segment normals make neighbouring quads disagree at the joint and
/// the ribbon comes apart into a row of slabs.
function demo_crack_ribbon(_C, _p, _e, _wf, _oy, _ce, _cm, _ae, _am, _fade) {
    var _sc = _C.sc, _sg = array_length(_p) - 1;
    for (var i = 0; i < _e; i++) {
        var _A = _p[i], _B = _p[i + 1];
        var _t0 = _fade ? (1 - i / _sg)       : 1;
        var _t1 = _fade ? (1 - (i + 1) / _sg) : 1;
        var _aw = _A.w * _wf * _sc, _bw = _B.w * _wf * _sc;
        var _ax = _C.x + _A.x * _sc, _ay = _C.y + _A.y * _sc * 0.5 + _oy;
        var _bx = _C.x + _B.x * _sc, _by = _C.y + _B.y * _sc * 0.5 + _oy;
        var _a1x = _ax + _A.nx * _aw, _a1y = _ay + _A.ny * _aw * 0.5;
        var _a2x = _ax - _A.nx * _aw, _a2y = _ay - _A.ny * _aw * 0.5;
        var _b1x = _bx + _B.nx * _bw, _b1y = _by + _B.ny * _bw * 0.5;
        var _b2x = _bx - _B.nx * _bw, _b2y = _by - _B.ny * _bw * 0.5;
        var _e0 = _ae * _t0, _e1 = _ae * _t1;
        var _m0 = _am * _t0, _m1 = _am * _t1;
        demo_batch_room(12);
        draw_vertex_colour(_a1x, _a1y, _ce, _e0);
        draw_vertex_colour(_ax,  _ay,  _cm, _m0);
        draw_vertex_colour(_b1x, _b1y, _ce, _e1);
        draw_vertex_colour(_ax,  _ay,  _cm, _m0);
        draw_vertex_colour(_bx,  _by,  _cm, _m1);
        draw_vertex_colour(_b1x, _b1y, _ce, _e1);
        draw_vertex_colour(_ax,  _ay,  _cm, _m0);
        draw_vertex_colour(_a2x, _a2y, _ce, _e0);
        draw_vertex_colour(_bx,  _by,  _cm, _m1);
        draw_vertex_colour(_a2x, _a2y, _ce, _e0);
        draw_vertex_colour(_b2x, _b2y, _ce, _e1);
        draw_vertex_colour(_bx,  _by,  _cm, _m1);
    }
}

/// How far along an arm the split has run, given the crack's overall growth `_g` and how far
/// out this arm's root sits. A branch cannot start opening before the arm it comes off has
/// reached it.
function demo_crack_reveal(_g, _d0) {
    var _s = _d0 * 0.75;
    return clamp((_g - _s) / max(0.05, 1 - _s), 0, 1);
}

/// Each arm is drawn as a RIBBON with a gradient ACROSS its width: dark torn edges, a
/// white-hot middle. That cross-section is the whole thing. Every earlier version drew the
/// crack as a line -- however thin, however coloured, however bloomed -- and a line can only
/// ever be a wire lying on the grass. What the reference shows is a torn opening: broad
/// where it starts, tapering to a point, and lit from inside.
function demo_cracks_paint() {
    var _nc = array_length(global.demo_cracks);
    for (var c = 0; c < _nc; c++) {
        var _C = global.demo_cracks[c];
        var _u = _C.t / _C.dur;
        if (_u >= 1) continue;
        if (!demo_on_screen(_C.x, _C.y, 140 * _C.sc)) continue;
        var _g   = min(1, _u / 0.10);                  // how far the split has run
        var _hot = power(1 - _u, 0.8) * (0.86 + 0.14 * dsin(_C.t * 260));
        var _na  = array_length(_C.arms);
        var _sc  = _C.sc;

        // A crack is built in three layers, in this order, and the order is the point.
        //
        //   1. THE OPENING -- the ground broken away, in rock. Full width, normal blending.
        //   2. THE NEAR LIP -- the rim closest to the camera, catching the light from below.
        //   3. THE DEPTH -- red light shining up out of it, NARROWER than the opening so the
        //      broken edges stay visible either side of it.
        //
        // Drawing only step 3 is what every earlier attempt did, and a glow with no opening
        // around it is a wire lying on the grass however it is coloured. The rock is dark
        // warm brown rather than black: a hole cut in the picture reads as a hole in the
        // picture, whereas earth in shadow reads as earth.
        var _rock = make_colour_rgb(30, 21, 17);
        var _lip  = make_colour_rgb(104, 54, 32);
        var _g1   = _C.pal[3];      // deep ember, down at the bottom of the gap
        var _g3   = _C.pal[0];      // and the hot core of it

        demo_batch_begin();
        for (var a = 0; a < _na; a++) {
            var _AR = _C.arms[a];
            var _e  = ceil((array_length(_AR.p) - 1) * demo_crack_reveal(_g, _AR.d0));
            // The rock holds its width to the tip -- ground stays broken after it has
            // stopped glowing, which is what leaves a crack behind rather than a fading light.
            demo_crack_ribbon(_C, _AR.p, _e, 1.15, 0, _rock, _rock, 0.5, 0.95, false);
        }
        draw_primitive_end();

        // The lip: a narrow band offset DOWN the screen. On an isometric floor you look
        // slightly into the gap, so the near edge is the one whose inner face you can see,
        // and it is lit from inside. Fades along the arm with the light that lights it.
        demo_batch_begin();
        for (var a = 0; a < _na; a++) {
            var _AR = _C.arms[a];
            var _e  = ceil((array_length(_AR.p) - 1) * demo_crack_reveal(_g, _AR.d0));
            demo_crack_ribbon(_C, _AR.p, _e, 0.55, 1.6 * _sc,
                              _rock, _lip, 0.2 * _hot, 0.85 * _hot, true);
        }
        draw_primitive_end();

        gpu_set_blendmode(bm_add);
        // Bloom spilling out onto the ground either side, as blobs rather than a wide line:
        // draw_line_width lays down a rotated rectangle per segment with no join between
        // them, and at this width the corners showed as a chain of bricks down every crack.
        // Every OTHER point only -- the blobs are wide enough to cover two segments.
        for (var a = 0; a < _na; a++) {
            var _AR = _C.arms[a];
            var _p  = _AR.p;
            var _sg = array_length(_p) - 1;
            var _e  = ceil(_sg * demo_crack_reveal(_g, _AR.d0));
            for (var i = 0; i < _e; i += 2) {
                var _A  = _p[i];
                demo_blob(_C.x + _A.x * _sc, _C.y + _A.y * _sc * 0.5,
                          (3 + _A.w * 2.6) * _sc, 0.5,
                          demo_col_scale(_g1, 0.3 * _hot * (1 - i / _sg)), 0.5);
            }
        }

        // The depth. Narrow, so it sits INSIDE the opening with rock showing either side --
        // that margin is what makes it light coming up out of a gap rather than the gap
        // itself being made of light.
        demo_batch_begin();
        for (var a = 0; a < _na; a++) {
            var _AR = _C.arms[a];
            var _e  = ceil((array_length(_AR.p) - 1) * demo_crack_reveal(_g, _AR.d0));
            demo_crack_ribbon(_C, _AR.p, _e, 0.6, 0, _g1, _g3, 0.35 * _hot, 1.1 * _hot, true);
        }
        draw_primitive_end();

        demo_crack_burst(_C, _u);
        gpu_set_blendmode(bm_normal);
    }
}

/// The flash ON the floor as the fissure opens: the hot mouth, and the sheet of light
/// running outward over the ground. The fire itself does not live here -- it comes UP out of
/// the splits, and that is drawn in Draw End (demo_cracks_burst_paint) where it can stand in
/// front of the characters instead of underneath them.
///
/// Called inside the additive pass demo_cracks_paint has already opened.
function demo_crack_burst(_C, _u) {
    var _bu = _u / 0.16;
    if (_bu >= 1) return;
    var _cf = (1 - _bu) * (1 - _bu);
    // Light flooding out of the splits as they open, and the hot mouth at the middle. Two
    // soft ellipses, and deliberately nothing else: every attempt to put a SHAPE here -- a
    // fan of blades, a ring of spikes -- ended up reading as an explosion sitting on top of
    // some cracks. The cracks are the effect. This is only the flash they let out.
    var _sr = (16 + 76 * (1 - power(1 - _bu, 2))) * _C.sc;
    draw_ellipse_colour(_C.x - _sr, _C.y - _sr * 0.5, _C.x + _sr, _C.y + _sr * 0.5,
                        demo_col_scale(_C.pal[2], _cf * 0.5), c_black, false);
    var _cr = (8 + 20 * _bu) * _C.sc;
    draw_ellipse_colour(_C.x - _cr, _C.y - _cr * 0.5, _C.x + _cr, _C.y + _cr * 0.5,
                        demo_col_scale(_C.pal[0], _cf * 0.8), c_black, false);
}

/// A meteor: falls onto (_x, _y) from off to one side, lighting the ground on the way down,
/// and leaves a blast and a glowing crater in its own colour.
///
/// The path is computed from `t` rather than integrated, so it CANNOT miss: the ground
/// position is a straight interpolation onto the target and only the height is eased. A
/// meteor that lands next to its crater is the one thing this must never do.
function demo_meteor(_x, _y) {
    // Red, orange or blue, rolled per meteor. `_lc` is what the light it carries throws on
    // the ground -- dim, like every pool tint.
    var _fam = irandom(2);
    var _pal, _lc;
    if (_fam == 0) {
        _pal = global.pal_red;
        _lc  = make_colour_rgb(140, 34, 26);
    } else if (_fam == 1) {
        _pal = global.pal_fire;
        _lc  = make_colour_rgb(132, 66, 20);
    } else {
        _pal = global.pal_blue;
        _lc  = make_colour_rgb(34, 74, 150);
    }
    // Kept STEEP. The lateral run is short against the drop, so the path on screen is well
    // past forty-five degrees from any approach bearing -- a long run with a shallow drop
    // reads as something gliding in rather than falling.
    var _ang = random(360);
    var _d   = 130 + random(130);
    var _M = {
        tx : _x, ty: _y,
        ox : lengthdir_x(_d, _ang), oy: lengthdir_y(_d, _ang) * 0.5,   // iso, on the floor
        z0 : 560 + random(200),
        t  : 0, dur: 0.9 + random(0.3),
        pal: _pal, lcol: _lc, light: undefined
    };
    array_push(global.demo_meteors, _M);
    var _L = demo_add_light(_x + _M.ox, _y + _M.oy, false, -1, 380, _M.z0);
    _L.col   = _lc;
    _L.tint  = true;
    _L.glyph = false;
    _L.smax  = 2.4;
    _L.pow   = 1.8;
    _L.pow0  = 1.8;
    _M.light = _L;
    return _M;
}

/// Where a meteor is at `_u` of its fall, as {x, y, z}. Shared by the update, the draw and
/// the trail, so the light, the head and the streak cannot disagree about where it is.
function demo_meteor_at(_M, _u) {
    var _k = 1 - _u;
    return { x: _M.tx + _M.ox * _k,
             y: _M.ty + _M.oy * _k,
             // ACCELERATING: dz/du is zero at the top and steepest at the ground, so the
             // drop gathers pace the whole way down. The obvious-looking z0*k*k does the
             // exact opposite -- it falls fastest at the start and coasts at the end -- and
             // since the ground travel is linear throughout, the path flattened out just
             // before impact and the meteor appeared to bank and fly sideways into its own
             // crater. This is that bug, and this is the fix.
             z: _M.z0 * (1 - _u * _u) };
}

#macro SHARD_MAX     420
#macro SHARD_GRAVITY 900      // screen units per second per second

/// Put one flake of ground cover at (_x, _y), if that cell is free. The one-layer rule lives
/// here: a cell either holds cover or it does not, so both snowfall and the frost thrown out
/// by a glacier build over AREA and never in depth, and both are walked off and blasted away
/// by exactly the same code.
function demo_snow_settle(_x, _y) {
    if (array_length(global.demo_settled) >= SNOW_SETTLED_MAX) return false;
    var _k = demo_snow_key(_x, _y);
    if (ds_map_exists(global.demo_snowmap, _k)) return false;
    global.demo_snowmap[? _k] = array_length(global.demo_settled);
    array_push(global.demo_settled, { x: _x, y: _y, k: _k, a: 0, live: true });
    return true;
}

/// H: a slab of ice calves off something out of frame and comes down on (_x, _y).
///
/// Falls almost straight, unlike the meteor. A meteor arrives from somewhere; ice DROPS --
/// it lets go and gravity does the rest -- and the short lateral run is most of what
/// separates the two at a glance.
function demo_glacier(_x, _y) {
    var _ang = random(360);
    var _d   = 50 + random(80);
    var _G = {
        tx : _x, ty: _y,
        ox : lengthdir_x(_d, _ang), oy: lengthdir_y(_d, _ang) * 0.5,
        z0 : 540 + random(170),
        t  : 0, dur: 0.95 + random(0.3),
        size: 34 + random(16),
        ang : random(360), spin: random_range(-110, 110),
        facet: [], light: undefined
    };
    // The block's own ragged outline, rolled once. A slab of ice is not a circle, and the
    // silhouette tumbling is what makes it read as a solid object rather than a glow.
    for (var i = 0; i < 7; i++) {
        array_push(_G.facet, { a: i * (360 / 7) + random_range(-15, 15),
                               r: 0.6 + random(0.55) });
    }
    array_push(global.demo_glaciers, _G);
    var _L = demo_add_light(_x + _G.ox, _y + _G.oy, false, -1, 340, _G.z0);
    _L.col   = make_colour_rgb(46, 92, 140);           // cold, and dim like every pool tint
    _L.tint  = true;
    _L.glyph = false;
    _L.smax  = 2.4;
    _L.pow   = 1.5;
    _L.pow0  = 1.5;
    _G.light = _L;
    return _G;
}

/// It lands, and stops being one thing.
///
/// Shards get REAL physics rather than a scripted spread: launch velocity, gravity, a bounce
/// that loses most of its energy, friction while sliding, and spin that dies with it. That
/// is the whole point of the effect -- a scripted burst looks the same every time, and what
/// sells breaking ice is debris skittering to a halt at its own pace in its own direction.
function demo_glacier_shatter(_x, _y, _size) {
    var _n = 46 + irandom(22);
    repeat (_n) {
        if (array_length(global.demo_shards) >= SHARD_MAX) break;
        var _a  = random(360);
        var _sp = 30 + random(230);
        array_push(global.demo_shards, {
            x : _x + random_range(-9, 9), y: _y + random_range(-5, 5),
            z : 3 + random(22),
            vx: lengthdir_x(_sp, _a), vy: lengthdir_y(_sp, _a),
            vz: 70 + random(270),
            ang: random(360), spin: random_range(-430, 430),
            ci: 0, col: c_white,               // cached lit colour; see demo_shards_paint
            size: _size * (0.05 + random(0.14)),
            thin: 0.22 + random(0.4),          // glass breaks into slivers, not chips
            t : 0, life: 3.6 + random(2.6),
            rest: false
        });
    }
    // No frost left behind. It used to seed the snow grid here, which was neat -- real
    // persistent ground cover for free -- but it read as a white stain the shards were lying
    // on rather than as ice that had shattered, and it outlived the shards by a long way.
    // The debris IS the aftermath.
    //
    // A breath of mist, through the ordinary smoke system so the impact light tints it.
    repeat (7) {
        var _ma = random(360), _md = random(40);
        if (!demo_smoke_add({
            x : _x + lengthdir_x(_md, _ma), y: _y + lengthdir_y(_md, _ma) * 0.5,
            z : 6 + random(12),
            vx: lengthdir_x(50 + random(70), _ma), vy: lengthdir_y(50 + random(70), _ma),
            vz: 12 + random(16),
            r : 10 + random(10), grow: 14 + random(14),
            t : -random(0.1), life: 2.2 + random(1.2)
        })) break;
    }
}

/// One shard's quad, appended to an open pr_trianglelist. A slim diamond, rotated by its
/// spin and squashed toward the ground plane as it comes to rest -- a chip lying flat on an
/// isometric floor is foreshortened, a tumbling one in mid-air is not, and interpolating
/// between the two by HEIGHT is what makes it look like it landed rather than stopped.
function demo_shard_verts(_S, _col, _a) {
    var _sq = 0.5 + 0.5 * clamp(_S.z / 42, 0, 1);
    var _c  = dcos(_S.ang), _sn = dsin(_S.ang);
    var _hw = _S.size, _hh = _S.size * _S.thin;
    var _bx = _S.x, _by = _S.y - _S.z;
    // Corners of the sliver, in its own frame.
    var _lx = [-_hw, 0, _hw, 0];
    var _ly = [0, -_hh, 0, _hh];
    var _px = array_create(4), _py = array_create(4);
    for (var i = 0; i < 4; i++) {
        _px[i] = _bx + (_lx[i] * _c - _ly[i] * _sn);
        _py[i] = _by + (_lx[i] * _sn + _ly[i] * _c) * _sq;
    }
    // Bright along one diagonal and dim along the other, so every shard carries a highlight
    // that swings as it turns. Flat-shaded chips read as paper.
    demo_batch_room(6);
    draw_vertex_colour(_px[0], _py[0], _col, _a);
    draw_vertex_colour(_px[1], _py[1], c_white, _a);
    draw_vertex_colour(_px[2], _py[2], _col, _a * 0.55);
    demo_batch_room(6);
    draw_vertex_colour(_px[0], _py[0], _col, _a);
    draw_vertex_colour(_px[2], _py[2], _col, _a * 0.55);
    draw_vertex_colour(_px[3], _py[3], _col, _a * 0.8);
}

/// The shards, split by HEIGHT rather than by a depth test: anything still in the air is
/// drawn in front of the characters, anything that has come to rest is drawn on the floor
/// with the snow. That is both cheaper than testing each of four hundred chips against every
/// character and more correct -- a chip lying on the ground IS on the ground.
function demo_shards_paint(_air) {
    var _n = array_length(global.demo_shards);
    if (_n == 0) return;
    var _ice = make_colour_rgb(196, 232, 255);
    demo_batch_begin();
    for (var i = 0; i < _n; i++) {
        var _S = global.demo_shards[i];
        if ((_S.z > 1) != _air) continue;
        if (!demo_on_screen(_S.x, _S.y - _S.z, 24)) continue;
        // Ice takes the colour of what is lighting it, over its own pale blue -- but it does
        // not need asking every frame. Four hundred chips each sampling every light was the
        // single most expensive thing on the ground pass. The counter is seeded from the
        // shard's index so the work spreads across frames instead of spiking on one.
        if (_S.ci <= 0) {
            _S.col = merge_colour(_ice, demo_smoke_light(_S.x, _S.y, _S.z), 0.45);
            _S.ci  = 5 + (i mod 7);
        } else {
            _S.ci--;
        }
        var _u = _S.t / _S.life;
        demo_shard_verts(_S, _S.col, 0.85 * min(1, (1 - _u) * 3));
    }
    draw_primitive_end();
}

/// The falling blocks, in Draw End. Tumbling silhouette, a cold core, and a trail of frost
/// shed behind it -- sampled back along its own path, the same trick the meteor uses.
/// One primitive for all of them, for the reason spelled out in demo_fires_paint: a
/// primitive per item leaves a seam between each pair, and the seam draws as a sliver.
function demo_glaciers_paint() {
    var _n = array_length(global.demo_glaciers);
    if (_n == 0) return;
    var _ice = make_colour_rgb(206, 238, 255);
    // The frost trails are SPRITES and the blocks are primitives, so they go in two separate
    // sweeps: a sprite cannot be drawn while a primitive is open.
    for (var g = 0; g < _n; g++) {
        var _G = global.demo_glaciers[g];
        var _u = min(1, _G.t / _G.dur);
        if (!demo_on_screen(_G.tx, _G.ty - _G.z0 * 0.5, _G.z0 * 0.6 + 260)) continue;
        for (var s = 12; s >= 1; s--) {
            var _su = _u - s * 0.02;
            if (_su < 0) continue;
            var _q = s / 12;
            var _P = demo_meteor_at(_G, _su);
            demo_blob(_P.x, _P.y - _P.z, _G.size * (0.5 - 0.3 * _q), 1,
                      _ice, (1 - _q) * (1 - _q) * 0.35);
        }
    }
    demo_batch_begin();
    for (var g = 0; g < _n; g++) {
        var _G = global.demo_glaciers[g];
        var _u = min(1, _G.t / _G.dur);
        if (!demo_on_screen(_G.tx, _G.ty - _G.z0 * 0.5, _G.z0 * 0.6 + 260)) continue;
        var _H  = demo_meteor_at(_G, _u);
        var _hy = _H.y - _H.z;
        var _sp = _G.ang + _G.spin * _G.t;
        // The block itself: a fan over its rolled outline. Drawn twice -- a broad pale body
        // and a small white heart -- so it has some depth in it rather than reading as a
        // flat cutout.
        for (var pass = 0; pass < 2; pass++) {
            var _sc = (pass == 0) ? 1 : 0.5;
            var _ca = (pass == 0) ? 0.62 : 0.95;
            var _cc = (pass == 0) ? _ice : c_white;
            for (var i = 0; i < 7; i++) {
                var _f0 = _G.facet[i], _f1 = _G.facet[(i + 1) mod 7];
                demo_batch_room(3);
                draw_vertex_colour(_H.x, _hy, c_white, _ca);
                draw_vertex_colour(_H.x + dcos(_f0.a + _sp) * _G.size * _f0.r * _sc,
                                   _hy  + dsin(_f0.a + _sp) * _G.size * _f0.r * _sc,
                                   _cc, _ca * 0.55);
                draw_vertex_colour(_H.x + dcos(_f1.a + _sp) * _G.size * _f1.r * _sc,
                                   _hy  + dsin(_f1.a + _sp) * _G.size * _f1.r * _sc,
                                   _cc, _ca * 0.55);
            }
        }
    }
    draw_primitive_end();
}

/// The meteors, in Draw End. Head, then a streak behind it sampled BACK along its own path
/// rather than stored -- the path is a function of time, so where it was is free, and a
/// recorded trail would lag or gap whenever the frame rate moved.
function demo_meteors_paint() {
    var _n = array_length(global.demo_meteors);
    if (_n == 0) return;
    for (var m = 0; m < _n; m++) {
        var _M = global.demo_meteors[m];
        var _u = min(1, _M.t / _M.dur);
        // Generous: the head can be six hundred pixels above its target early in the fall,
        // and the streak trails behind it, so the whole arc is tested rather than a point.
        if (!demo_on_screen(_M.tx, _M.ty - _M.z0 * 0.5, _M.z0 * 0.6 + 320)) continue;
        // Streak: eighteen samples back down the path, shrinking and cooling. It follows the
        // arc because it IS the arc.
        for (var s = 18; s >= 1; s--) {
            var _su = _u - s * 0.016;
            if (_su < 0) continue;
            var _q  = s / 18;
            var _P  = demo_meteor_at(_M, _su);
            demo_blob_verts(_P.x, _P.y - _P.z, (11 - 8 * _q) * (0.6 + 0.4 * _u), 1,
                            demo_ramp(_M.pal, 0.25 + _q * 0.7),
                            (1 - _q) * (1 - _q) * 0.5);
        }
        var _H = demo_meteor_at(_M, _u);
        demo_blob(_H.x, _H.y - _H.z, 15, 1, _M.pal[0], 0.95);
        demo_blob(_H.x, _H.y - _H.z, 26, 1, _M.pal[1], 0.4);
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

/// A water projector: caustics, per pixel, in sh_caustics. See the shader for what the
/// pattern is and why it is built the way it is.
///
/// Drawn as a bare quad over the pool's footprint with no texture at all. The shader never
/// samples gm_BaseTexture -- it works from the world position, which is what anchors the
/// caustics to the FLOOR rather than to the quad -- so there is no sprite to keep off the
/// shared texture page and no atlas coordinates to fight.
///
/// This is the one effect that had to be a shader. Water is a field, not a set of shapes:
/// the first attempt drew it as rings plus drifting blobs, and it read as a sonar ping over
/// a lava lamp, because the thing that makes caustics look like water is what happens
/// BETWEEN the bright veins -- which is per-pixel work by nature.
function demo_fx_water(_L) {
    var _R = _L.r * 0.5;                   // ground reach of the projection
    var _hw = _R, _hh = _R * 0.5;          // iso 2:1: a circle on the floor is a wide quad
    shader_set(sh_caustics);
    shader_set_uniform_f(caustic_u.centre, _L.x, _L.y);
    shader_set_uniform_f(caustic_u.radius, _R);
    shader_set_uniform_f(caustic_u.time,   _L.ft);
    shader_set_uniform_f(caustic_u.tint,   0.30, 0.72, 0.96);
    shader_set_uniform_f(caustic_u.fade,   1.0);
    draw_primitive_begin(pr_trianglestrip);
    draw_vertex_colour(_L.x - _hw, _L.y - _hh, c_white, 1);
    draw_vertex_colour(_L.x + _hw, _L.y - _hh, c_white, 1);
    draw_vertex_colour(_L.x - _hw, _L.y + _hh, c_white, 1);
    draw_vertex_colour(_L.x + _hw, _L.y + _hh, c_white, 1);
    draw_primitive_end();
    shader_reset();
}

/// A galaxy: two trailing spiral arms of stars turning about a hot core.
///
/// The arms TRAIL -- a star further out sits further back around the turn -- which is what
/// makes the whole figure read as rotating. Spokes at fixed angles merely spin.
function demo_fx_galaxy(_L) {
    // A THIRD of the reach, not half. At half, the figure was over twelve hundred pixels
    // across at the demo's own zoom -- wider than the window -- so only ever a slice of it
    // was on screen at once and the four arms read as one long sweep. The structure was
    // fine; you simply could not see enough of it at a time to tell.
    var _R = _L.r * 0.32, _spin = _L.ft * 13;
    // Core, and a broad dust disc under the whole thing. Arms alone read as a few strings
    // of dots on bare grass; the haze is what fills the space between them and makes it a
    // galaxy rather than a spiral of beads.
    for (var d = 3; d >= 1; d--) {
        var _dr = _R * (0.30 + 0.24 * d);
        draw_ellipse_colour(_L.x - _dr, _L.y - _dr * 0.5, _L.x + _dr, _L.y + _dr * 0.5,
                            demo_col_scale(make_colour_rgb(96, 48, 150), 0.30 / d),
                            c_black, false);
    }
    // Nebula: real cloud INSIDE the spiral, at its own heights, drifting on its own slow
    // orbit. Stars alone leave clear air between them and the thing reads as a pattern of
    // dots; the fog is what gives it depth to have stars in FRONT of and behind.
    for (var f = 0; f < 8; f++) {
        var _fp = f / 8;
        var _fa = _fp * 360 + _spin * 0.55 + f * 23;
        var _fr = _R * (0.14 + 0.58 * frac(f * 0.618));
        var _fz = 12 + 44 * (0.5 + 0.5 * dsin(f * 137 + _L.ft * 17));
        // Thin. At any more than this the fog filled the gaps BETWEEN the arms as brightly
        // as the arms themselves, and the whole figure went back to being one soft disc.
        demo_blob(_L.x + dcos(_fa) * _fr,
                  _L.y + dsin(_fa) * _fr * 0.5 - _fz,
                  22 + 18 * dsin(f * 71 + _L.ft * 21), 0.78,
                  merge_colour(make_colour_rgb(104, 40, 158),
                               make_colour_rgb( 40, 76, 176), _fp), 0.10);
    }
    var _cr = 13 + 2 * dsin(_L.ft * 90);
    draw_ellipse_colour(_L.x - _cr, _L.y - _cr * 0.5 - 22, _L.x + _cr, _L.y + _cr * 0.5 - 22,
                        make_colour_rgb(255, 242, 224), c_black, false);
    // The field is laid out ONCE (demo_galaxy_stars) and only ROTATED here, which is the
    // whole reason six hundred stars are affordable: rotating precomputed ground offsets is
    // one cos and one sin for the entire galaxy, where placing each star from scratch was
    // eight transcendentals apiece and several thousand a frame.
    //
    // All of them in one primitive too, each a small iso diamond -- at four pixels across
    // nobody can tell a diamond from a circle.
    var _st = _L.stars, _n = array_length(_st);
    var _cs = dcos(_spin), _sn = dsin(_spin);
    demo_batch_begin();
    for (var i = 0; i < _n; i++) {
        var _S  = _st[i];
        var _gx = (_S.gx * _cs - _S.gy * _sn) * _R;
        var _gy = (_S.gx * _sn + _S.gy * _cs) * _R;
        var _sx = _L.x + _gx;
        var _sy = _L.y + _gy * 0.5 - _S.z;       // height is straight screen-y
        var _s  = _S.sz, _v = _S.sz * 0.5, _q = _S.q, _c = _S.c;
        demo_batch_room(6);
        draw_vertex_colour(_sx,      _sy - _v, _c, _q);
        draw_vertex_colour(_sx + _s, _sy,      _c, _q);
        draw_vertex_colour(_sx,      _sy + _v, _c, _q);
        demo_batch_room(6);
        draw_vertex_colour(_sx,      _sy - _v, _c, _q);
        draw_vertex_colour(_sx,      _sy + _v, _c, _q);
        draw_vertex_colour(_sx - _s, _sy,      _c, _q);
    }
    draw_primitive_end();
}

/// The star field, in ground offsets scaled to the galaxy's radius. Built once, when the
/// lamp is created, because nothing in it changes -- the figure only turns.
///
/// Three arms, deeply populated, each star scattered off its arm by its own fixed amount so
/// an arm is a SMEAR of stars rather than a line of them, with the scatter widening outward
/// the way arms actually fray at the rim. Heights are thickest through the core and thin to
/// the rim: a galaxy is a bulge with a flat disc around it, and drawn entirely on the floor
/// it was a decal painted on the grass.
function demo_galaxy_stars() {
    var _out = [];
    // FOUR arms, and each winds through only about half a turn. At 250 degrees of sweep the
    // arms wrapped so far that every one of them passed through every part of the disc, and
    // what came out was a single uniform swirl -- the structure was there in the numbers and
    // invisible on screen. Half a turn keeps an arm identifiable along its whole length.
    for (var a = 0; a < 4; a++) {
        for (var i = 1; i <= 162; i++) {
            var _p   = i / 162;
            var _ang = a * 90 + _p * 185 + dsin(i * 61.7 + a * 29) * 5 * _p;
            // Scatter kept well under the gap between arms (90 degrees), or they blur into
            // each other at exactly the radius where they should be clearest.
            var _rr  = power(_p, 0.78) + dsin(i * 137.5 + a * 61) * (0.02 + 0.055 * _p);
            array_push(_out, {
                gx: dcos(_ang) * _rr,
                gy: dsin(_ang) * _rr,
                z : (0.5 + 0.5 * dsin(i * 211.3 + a * 97)) * 56 * (1 - _p * 0.55),
                // White-hot at the core, through magenta, to deep blue at the rim.
                c : (_p < 0.45)
                    ? merge_colour(make_colour_rgb(255, 238, 210),
                                   make_colour_rgb(232,  86, 226), _p / 0.45)
                    : merge_colour(make_colour_rgb(232,  86, 226),
                                   make_colour_rgb( 70, 104, 255), (_p - 0.45) / 0.55),
                // Sizes vary per star rather than only by radius, so the field has depth in
                // it instead of reading as one ring of dots after another.
                sz: (3.6 - 1.7 * _p) * (0.55 + 0.45 * abs(dsin(i * 83 + a * 47))),
                q : 0.9 - 0.35 * _p
            });
        }
    }
    return _out;
}

/// Set off a blast at (_x, _y): a cluster of fireballs, a spray of sparks, a ground flash,
/// and a strong short-lived light.
///
/// Every puff's angle, distance, size, rise and start delay is rolled ONCE, here, and kept.
/// Rolling them per frame would make the fire boil into noise instead of expanding, and it
/// is the staggered start delays that make it bloom rather than appear all at once.
function demo_boom(_x, _y, _pal = undefined, _lcol = undefined) {
    if (_pal  == undefined) _pal  = global.pal_fire;
    if (_lcol == undefined) _lcol = make_colour_rgb(126, 62, 18);
    var _puff = [];
    repeat (18) array_push(_puff, {
        ang  : random(360),
        // Fire CLIMBS more than it spreads. The first version rolled it the other way and
        // the fireball lay across the floor like a blanket -- which buried the blast's own
        // cast shadows under its own glare, since a shadow is at most a couple of times the
        // caster's height long and the fire was wider than that. Rising keeps the light
        // where an explosion's light belongs and leaves the floor clear to be shadowed.
        dist : 6 + random(38),
        size : 12 + random(24),
        rise : 22 + random(58),
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
        { x: _x, y: _y, t: 0, dur: 1.25, puff: _puff, spark: _spark, pal: _pal });
    demo_snow_clear(_x, _y, 150);       // blown off the ground, once, not every frame
    // Sitting ON the floor, and bright. Height is what sets shadow length, so a blast at
    // ground level throws the longest shadows there are -- which is why it raises `smax`:
    // the usual 1.6 ceiling would hold them to barely the caster's own height and leave
    // them entirely underneath the fireball. Outlives the fire slightly, so the light fades
    // out rather than cutting off while embers are still visible.
    // Outliving the fire by a good margin, so what the eye last sees is the glare dying
    // down rather than the effect ending.
    var _L = demo_add_light(_x, _y, false, 2.4, 620, 30);
    _L.col   = _lcol;                              // firelight, on the ground and on skin
    _L.tint  = true;
    _L.glyph = false;                              // a blast is not a lamp on a stem
    _L.smax  = 3.2;
    _L.pow   = 3.2;                                // outshines the room; see demo_add_light
    _L.pow0  = 3.2;
    return _L;
}

/// Midpoint displacement: start from the two endpoints and repeatedly split every segment,
/// pushing each new midpoint sideways by a random amount that halves every pass. Four
/// passes give 17 points -- enough kinks to read as lightning, few enough to draw as lines.
///
/// The push is PERPENDICULAR to the segment. Displacing along a fixed axis makes a run that
/// already lies along that axis wander up and down itself instead of bending.
function demo_bolt_path(_x0, _y0, _x1, _y1, _jag) {
    var _p = [[_x0, _y0], [_x1, _y1]];
    var _amp = _jag;
    repeat (4) {
        var _q = [];
        var _n = array_length(_p);
        for (var i = 0; i < _n - 1; i++) {
            var _a = _p[i], _b = _p[i + 1];
            array_push(_q, _a);
            var _dx = _b[0] - _a[0], _dy = _b[1] - _a[1];
            var _len = max(1, sqrt(_dx * _dx + _dy * _dy));
            var _o = random_range(-_amp, _amp);
            array_push(_q, [(_a[0] + _b[0]) * 0.5 - _dy / _len * _o,
                            (_a[1] + _b[1]) * 0.5 + _dx / _len * _o]);
        }
        array_push(_q, _p[_n - 1]);
        _p = _q;
        _amp *= 0.55;
    }
    return _p;
}

/// A jagged path lying ON the ground, returned as screen-space offsets.
///
/// Built in GROUND units and projected afterwards, and that order is the whole point. The
/// displacement has to be perpendicular in the plane the figure is actually in. Squashing
/// only the ENDPOINTS -- which is what the first fissures did -- leaves every kink between
/// them isotropic on screen, so the wobble comes out twice too tall for the floor it is
/// supposed to be lying on, and the network reads as a flat drawing pasted over the ground
/// instead of as part of it.
function demo_ground_path(_ang, _len, _jag) {
    var _p = demo_bolt_path(0, 0, lengthdir_x(_len, _ang), lengthdir_y(_len, _ang), _jag);
    for (var i = 0; i < array_length(_p); i++) _p[i][1] *= 0.5;      // iso 2:1, at the end
    return _p;
}

/// One crack, as a RIBBON: a chain of {x, y, w} in ground units, tapering from a wide gash
/// at the root to a point at the tip.
///
/// The width is the whole reason this exists. Cracks drawn as lines -- which is what this
/// was through several attempts -- can only ever be glowing wire lying on the grass, however
/// they are coloured. In the reference they are torn GASHES: broad where they start,
/// narrowing to points, and lit across their width with a white-hot middle and a dark red
/// fringe. That cross-section is what the eye reads as an opening rather than a mark.
///
/// The walk turns sharply and irregularly but is pulled back toward its original bearing
/// each step, so an arm wanders convincingly without curling up and heading home.
function demo_crack_walk(_x0, _y0, _ang, _len, _wide, _segs) {
    var _p = [{ x: _x0, y: _y0, w: _wide }];
    var _x = _x0, _y = _y0, _d = _ang;
    for (var i = 1; i <= _segs; i++) {
        _d += random_range(-42, 42);
        _d  = _ang + angle_difference(_d, _ang) * 0.7;      // never strays far from its bearing
        var _l = (_len / _segs) * (0.5 + random(1.1));
        _x += lengthdir_x(_l, _d);
        _y += lengthdir_y(_l, _d);
        // Tapering to nothing. The power keeps it broad for the first half and then closes
        // quickly, which is how a split actually runs out -- not a steady wedge.
        array_push(_p, { x: _x, y: _y, w: _wide * power(1 - i / _segs, 0.85) });
    }
    // A normal PER POINT, averaged from the segments either side of it, rather than one per
    // segment. With per-segment normals each quad computes its own edge and neighbouring
    // quads disagree at the joint, so the ribbon comes apart into a chain of separate slabs
    // with notches and overlaps at every corner. Sharing the normal at the point they meet
    // makes one continuous band, which is the whole difference between a smooth gash and a
    // row of tiles.
    var _n = array_length(_p);
    for (var i = 0; i < _n; i++) {
        var _ax, _ay;
        if (i == 0)           { _ax = _p[1].x - _p[0].x;         _ay = _p[1].y - _p[0].y; }
        else if (i == _n - 1) { _ax = _p[i].x - _p[i - 1].x;     _ay = _p[i].y - _p[i - 1].y; }
        else                  { _ax = _p[i + 1].x - _p[i - 1].x; _ay = _p[i + 1].y - _p[i - 1].y; }
        var _l = max(0.001, sqrt(_ax * _ax + _ay * _ay));
        _p[i].nx = -_ay / _l;
        _p[i].ny =  _ax / _l;
    }
    return _p;
}

/// Grow one arm and, recursively, the arms off it. Branch off branch is what gives the
/// network its several scales -- a single level of forking reads as a diagram of a crack.
/// `d0` is how far the arm's ROOT is from the epicentre. The paint uses it to hold a branch
/// back until the split has actually run out that far -- without it every arm starts growing
/// from its own root at the same instant, and the opening frames are a scatter of
/// disconnected fragments floating where their parents have not reached yet.
function demo_crack_branch(_arms, _x0, _y0, _ang, _len, _wide, _depth) {
    var _p = demo_crack_walk(_x0, _y0, _ang, _len, _wide, 4 + irandom(3));
    array_push(_arms, { p: _p, d0: sqrt(_x0 * _x0 + _y0 * _y0) });
    if (_depth <= 0) return;
    // Two branches near the trunk, one further out: the network is densest where the ground
    // took the blow and thins as it runs away from it.
    for (var b = 0; b < _depth; b++) {
        var _k = irandom_range(1, array_length(_p) - 2);
        var _n = _p[_k];
        // Leaving at a real angle, and thinner and shorter than what it came off.
        var _ba = _ang + ((random(1) < 0.5) ? -1 : 1) * (32 + random(40));
        demo_crack_branch(_arms, _n.x, _n.y, _ba,
                          _len * (0.34 + random(0.28)), _n.w * (0.5 + random(0.24)),
                          _depth - 1);
    }
}

/// A strike's brightness at `_u` through its life: sharp spikes at the rolled flash times
/// over a dim afterglow. Real lightning is several strokes down the same channel a few
/// hundredths of a second apart, and that strobe is most of what sells it -- a single clean
/// fade in and out reads as a drawn shape being revealed, not as a discharge.
function demo_bolt_env(_B, _u) {
    var _e = 0;
    for (var i = 0; i < array_length(_B.flash); i++) {
        var _d = abs(_u - _B.flash[i]);
        if (_d < 0.045) _e = max(_e, 1 - _d / 0.045);
    }
    // The channel glows on between strokes and dies away SLOWLY afterwards. A square
    // falloff snuffed it almost the moment the last stroke was over, which read as the
    // effect being switched off rather than as something cooling.
    return max(_e, 0.34 * power(1 - _u, 1.5));
}

/// Strike at (_x, _y): a forked bolt down out of the sky, discharges crawling away across
/// the floor, and a hard cold light.
///
/// Rolled once, here, like the fire. A path regenerated per frame does not flicker, it
/// boils -- the eye reads redrawn noise as static rather than as one bolt being struck
/// several times, which is exactly what the strobe envelope is for.
function demo_bolt(_x, _y) {
    // Down from well above: height is straight screen-y here, the one axis the isometric
    // projection does not halve, so the bolt is drawn plumb and only the ground work is
    // squashed 2:1.
    var _top  = 300 + random(110);
    var _main = demo_bolt_path(random_range(-80, 80), -_top, 0, 0, 30);
    var _n    = array_length(_main);

    // Branches leave the channel partway down and die in the air -- a fork that reaches the
    // ground reads as a second strike rather than as part of this one.
    var _fork = [];
    repeat (3) {
        var _a  = _main[irandom_range(4, _n - 8)];
        var _fl = 60 + random(120);
        var _fd = 270 + random_range(-58, 58);          // 270 is straight down on screen
        array_push(_fork, demo_bolt_path(_a[0], _a[1],
                                         _a[0] + lengthdir_x(_fl, _fd),
                                         _a[1] + lengthdir_y(_fl, _fd), 16));
    }

    // Ground discharge: short crawls out from the impact. These are the only part of the
    // strike that lies on the floor, so they are the only part built in ground space.
    var _arc = [];
    repeat (6) {
        var _al = 45 + random(95);
        array_push(_arc, demo_ground_path(random(360), _al, _al * 0.16));
    }

    // Enormous, and LOW. The light of a strike is the channel, and the channel's bright end
    // is the bit touching the ground -- put it up where the bolt starts and shadow length
    // (ground distance over height) collapses to nothing, which is what the first attempt
    // did: a strike that lit everything and moved no shadow at all. The reach is driven by
    // the strobe in Step, so the ground darkens and blazes again with each stroke rather
    // than fading off smoothly.
    var _L = demo_add_light(_x, _y, false, BOLT_DUR, 900, 70);
    _L.col   = make_colour_rgb(120, 152, 214);         // cold blue-white
    _L.tint  = true;
    _L.glyph = false;
    _L.smax  = 2.6;
    _L.pow   = 6;      // the brightest thing that happens here; nothing washes it out

    array_push(global.demo_bolts, {
        x: _x, y: _y, t: 0, dur: BOLT_DUR, main: _main, fork: _fork, arc: _arc,
        // Fractions of the whole life, so the strokes stay bunched at the start however
        // long the afterglow is given to burn down.
        flash: [0, 0.06 + random(0.03), 0.15 + random(0.06)],
        light: _L
    });
    demo_snow_clear(_x, _y, 120);
}

/// How long a strike lasts, strokes and afterglow together. The strokes are over in the
/// first fifth of it; the rest is the channel and the lit ground cooling off, which is what
/// wants the time -- at 0.78s the whole thing snapped out while the eye was still on it.
#macro BOLT_DUR 2.1

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
// Numeric second element = spawner action; a string names one of the toggles below.
buttons     = [["+10", 10], ["+50", 50], ["-10", -10], ["reset", 0], ["wave", "wave"],
               ["fun", "fun"]];
global.demo_fun = false;      // see demo_fun_toggle
fun_t           = 0;          // seconds until the next volley
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

/// Back to the room's own two lamps, with the air and the ground cleared. Behind both the C
/// key and the HUD's reset button, so the two cannot drift apart.
function demo_clear_all() {
    if (array_length(global.demo_lights) > 2) array_resize(global.demo_lights, 2);
    global.demo_smoke   = [];
    global.demo_cracks  = [];
    global.demo_fires   = [];
    global.demo_meteors = [];
    global.demo_settled = [];
    global.demo_flakes  = [];
    ds_map_clear(global.demo_snowmap);
    global.demo_snow_dead = 0;
}

/// FUN MODE. Scatters the standing effects over the whole map, turns on both kinds of
/// weather, and then keeps throwing the one-shot ones at the player -- see the Step event
/// for the timer.
///
/// Turning it off clears everything, which is the only sane exit: it spawns lights faster
/// than anyone would want to dismiss by hand, and every light is a full silhouette pass per
/// character.
function demo_fun_toggle() {
    global.demo_fun = !global.demo_fun;
    demo_clear_all();
    if (!global.demo_fun) {
        global.demo_rain = false;
        global.demo_snow = false;
        return;
    }
    var _fx = ["disco", "water", "galaxy", "laser"];
    for (var i = 0; i < array_length(_fx); i++) {
        demo_fx_light(irandom_range(140, room_width  - 140),
                      irandom_range(140, room_height - 140), _fx[i]);
    }
    repeat (2) demo_add_light(irandom_range(140, room_width  - 140),
                              irandom_range(140, room_height - 140));
    repeat (2) demo_fire(irandom_range(140, room_width  - 140),
                         irandom_range(140, room_height - 140));
    // Rain only. Snow settles and STAYS, and fun mode drops a glacier every few seconds --
    // each of which frosts the ground where it lands -- so the field went white inside a
    // minute and nothing else could be seen on it.
    global.demo_rain = true;
}

/// One of the one-shot effects, at (_x, _y). Everything here is transient -- it goes off,
/// it burns down, it removes itself -- which is what makes it safe to fire on a timer.
function demo_fun_burst(_x, _y) {
    switch (irandom(5)) {
        case 0: demo_boom(_x, _y);       break;
        case 1: demo_bolt(_x, _y);       break;
        case 2: demo_meteor(_x, _y);     break;
        case 3: demo_smoke_gun(_x, _y);  break;
        case 4: demo_crack(_x, _y);      break;
        case 5: demo_glacier(_x, _y);    break;
    }
}

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

// LAST, after every function above it exists. Functions declared in an event are created as
// the event runs, in order -- they are not hoisted -- so calling this from the top of Create
// found nothing there and took the whole boot down with it.
demo_make_blob_sprite();      // every soft blob in the demo draws from this one texture


