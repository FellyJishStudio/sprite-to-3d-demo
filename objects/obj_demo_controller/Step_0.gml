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

var _dt = delta_time / 1000000;               // seconds since the last step

// The one-shot effects, all at the cursor.
if (keyboard_check_pressed(ord("Q"))) demo_boom(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("A"))) demo_bolt(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("D"))) demo_smoke_gun(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("F"))) demo_crack(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("G"))) demo_fire(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("V"))) demo_meteor(mouse_x, mouse_y);
if (keyboard_check_pressed(ord("H"))) demo_glacier(mouse_x, mouse_y);

// Falling ice. Same analytic path as the meteor -- position is a function of t, so it
// cannot miss the spot it is going to shatter on.
for (var g = array_length(global.demo_glaciers) - 1; g >= 0; g--) {
    var _G = global.demo_glaciers[g];
    _G.t += _dt;
    var _gu = min(1, _G.t / _G.dur);
    var _GP = demo_meteor_at(_G, _gu);
    if (_G.light != undefined) {
        _G.light.x = _GP.x;
        _G.light.y = _GP.y;
        _G.light.h = max(12, _GP.z);
    }
    if (_G.t < _G.dur) continue;
    array_delete(global.demo_glaciers, g, 1);
    if (_G.light != undefined) {
        // Handed to the impact rather than deleted, same as the meteor: killing it on the
        // frame of the hit puts a hole in the light exactly when the scene is brightest.
        _G.light.life  = 1.1;
        _G.light.life0 = 1.1;
        _G.light.r0    = 520;
        _G.light.r     = 520;
        _G.light.pow   = 2.4;
        _G.light.pow0  = 2.4;
        _G.light.h     = 26;
    }
    demo_glacier_shatter(_G.tx, _G.ty, _G.size);
}

// Shard physics: gravity, a bounce that keeps about a third of the impact, friction while
// sliding, and spin that dies with the motion. Nothing here is scripted -- which is the
// point, since a scripted spread looks identical every time it is set off.
for (var s = array_length(global.demo_shards) - 1; s >= 0; s--) {
    var _S = global.demo_shards[s];
    _S.t += _dt;
    if (_S.t >= _S.life) { array_delete(global.demo_shards, s, 1); continue; }
    _S.ang += _S.spin * _dt;
    if (_S.rest) {
        // Skating to a halt: velocity and spin bleed away together, so a chip that is still
        // turning is still travelling, which is what a real one does.
        var _fr = power(0.02, _dt);
        _S.vx  *= _fr;
        _S.vy  *= _fr;
        _S.spin *= _fr;
        _S.x   += _S.vx * _dt;
        _S.y   += _S.vy * 0.5 * _dt;         // iso: ground travel is halved on screen
        continue;
    }
    _S.vz -= SHARD_GRAVITY * _dt;
    _S.z  += _S.vz * _dt;
    _S.x  += _S.vx * _dt;
    _S.y  += _S.vy * 0.5 * _dt;
    if (_S.z > 0) continue;
    _S.z = 0;
    if (_S.vz < -45) {
        _S.vz    = -_S.vz * 0.34;            // most of the energy goes into the ground
        _S.vx   *= 0.62;
        _S.vy   *= 0.62;
        _S.spin *= 0.5;
    } else {
        _S.vz   = 0;                         // too slow to leave the ground again
        _S.rest = true;
    }
}

// Meteors. The light rides down with the head, so the ground brightens as it comes in
// rather than only when it lands.
for (var m = array_length(global.demo_meteors) - 1; m >= 0; m--) {
    var _M = global.demo_meteors[m];
    _M.t += _dt;
    var _u = min(1, _M.t / _M.dur);
    var _P = demo_meteor_at(_M, _u);
    if (_M.light != undefined) {
        _M.light.x = _P.x;
        _M.light.y = _P.y;
        _M.light.h = max(12, _P.z);       // never at floor level, or shadow length runs away
    }
    if (_M.t < _M.dur) continue;
    // IMPACT. The crater and the blast both inherit the meteor's palette, so a blue one
    // leaves a blue-hot crack in the ground and a blue fireball over it.
    array_delete(global.demo_meteors, m, 1);
    if (_M.light != undefined) {
        // Hand the travelling light over to the blast rather than deleting it: killing it on
        // the frame of impact puts a hole in the light exactly when the scene is brightest.
        _M.light.life  = 0.45;
        _M.light.life0 = 0.45;
    }
    demo_crack(_M.tx, _M.ty, _M.pal, _M.lcol, 0.1);   // a crater, not a fissure
    demo_boom(_M.tx, _M.ty, _M.pal, _M.lcol);
}

// C: back to the room's own two lamps, and clear the air. With no ceiling on the light
// count it is easy to bury the scene -- shadow work is per caster PER LIGHT, and the
// framerate on the HUD is what notices first.
if (keyboard_check_pressed(ord("C"))) { demo_clear_all(); global.demo_fun = false; }

// Fun mode keeps throwing one-shots at the rider. THREE at a time, two seconds apart: one
// at a time reads as an occasional event rather than as a place where things are happening.
if (global.demo_fun) {
    fun_t -= _dt;
    if (fun_t <= 0) {
        fun_t = 2;
        var _fp = instance_find(obj_demo_player, 0);
        if (_fp != noone) {
            repeat (3) {
                var _fa = random(360), _fd = 90 + random(200);
                demo_fun_burst(_fp.x + lengthdir_x(_fd, _fa),
                               _fp.y + lengthdir_y(_fd, _fa) * 0.5);   // iso, on the floor
            }
        }
    }
}

// Z: weather. Drops are spawned across the CAMERA rect only -- rain over the rest of the
// room is rain nobody can see, and the budget is better spent on the part in view.
if (keyboard_check_pressed(ord("Z"))) global.demo_rain = !global.demo_rain;
if (global.demo_rain) {
    var _rc = view_camera[0];
    var _rx = camera_get_view_x(_rc), _ry = camera_get_view_y(_rc);
    var _rw = camera_get_view_width(_rc), _rh = camera_get_view_height(_rc);
    repeat (min(7, RAIN_MAX - array_length(global.demo_drops))) {
        array_push(global.demo_drops, {
            x  : _rx + random(_rw),
            // A drop lands where it started but is DRAWN a height above that, so the band
            // it is seeded in has to run past the bottom edge or the top of the screen has
            // no rain falling through it.
            y  : _ry + random(_rh + 260),
            z  : 170 + random(170),
            vz : 620 + random(240),
            len: 7 + random(10)
        });
    }
}
for (var d = array_length(global.demo_drops) - 1; d >= 0; d--) {
    var _D = global.demo_drops[d];
    _D.z -= _D.vz * _dt;
    if (_D.z > 0) continue;
    array_delete(global.demo_drops, d, 1);
    if (array_length(global.demo_ripples) < RAIN_MAX) {
        // col -1 means "not sampled yet"; demo_rain_paint fills it in on the first frame.
        array_push(global.demo_ripples, { x: _D.x, y: _D.y, t: 0, dur: 0.42, col: -1 });
    }
}
for (var k = array_length(global.demo_ripples) - 1; k >= 0; k--) {
    var _K = global.demo_ripples[k];
    _K.t += _dt;
    if (_K.t >= _K.dur) array_delete(global.demo_ripples, k, 1);
}

// V: snow. It falls, it lands, and it STAYS -- one layer, because the ground is cell-mapped
// and a cell either holds a flake or it does not. What clears it is being walked on or
// being blown up; see demo_snow_clear.
// X, not V: V is the meteor now.
if (keyboard_check_pressed(ord("X"))) global.demo_snow = !global.demo_snow;
if (global.demo_snow) {
    var _sc = view_camera[0];
    var _sx = camera_get_view_x(_sc), _sy = camera_get_view_y(_sc);
    var _sw = camera_get_view_width(_sc), _sh = camera_get_view_height(_sc);
    repeat (min(4, SNOW_FALLING_MAX - array_length(global.demo_flakes))) {
        array_push(global.demo_flakes, {
            x  : _sx + random(_sw),
            y  : _sy + random(_sh + 220),      // seeded past the bottom; see the rain note
            z  : 150 + random(190),
            vz : 48 + random(46),              // slow: this is snow, not sleet
            ph : random(360),                  // its own phase in the sway
            sw : 7 + random(13)                // and its own width of sway
        });
    }
}
for (var f = array_length(global.demo_flakes) - 1; f >= 0; f--) {
    var _F = global.demo_flakes[f];
    _F.z -= _F.vz * _dt;
    // Drifting as it falls. Tied to its own height rather than to a clock, so a flake traces
    // one continuous wander down instead of jittering in place.
    _F.ph += 52 * _dt;
    if (_F.z > 0) continue;
    array_delete(global.demo_flakes, f, 1);
    var _k = demo_snow_key(_F.x, _F.y);
    // Occupied cell, or a full field: the flake simply lands and is gone. That refusal IS
    // the one-layer rule -- snow accumulates over AREA here, never in depth.
    if (ds_map_exists(global.demo_snowmap, _k)) continue;
    if (array_length(global.demo_settled) >= SNOW_SETTLED_MAX) continue;
    global.demo_snowmap[? _k] = array_length(global.demo_settled);
    array_push(global.demo_settled, { x: _F.x, y: _F.y, k: _k, a: 0, live: true });
}
if (array_length(global.demo_settled) > 0) {
    // Fading in rather than appearing: a flake landing at full brightness pops, and at this
    // scale a field of popping flakes reads as static.
    for (var i = array_length(global.demo_settled) - 1; i >= 0; i--) {
        var _S = global.demo_settled[i];
        if (_S.a < 1) _S.a = min(1, _S.a + 3 * _dt);
    }
    // Footprints. Positions are collected first because demo_snow_clear lives on THIS
    // instance, and inside a `with` the name would be looked up on the character instead.
    var _feet = [];
    with (obj_demo_player)   if (mount == noone) array_push(_feet, [x, y, 15]);
    with (obj_demo_horse)    array_push(_feet, [x, y, 26]);
    with (obj_demo_skeleton) array_push(_feet, [x, y, 14]);
    for (var i = 0; i < array_length(_feet); i++) {
        demo_snow_clear(_feet[i][0], _feet[i][1], _feet[i][2]);
    }
    demo_snow_compact();
}

// Height is what sets shadow length, so the rising lamp is the whole demonstration: its
// shadows stretch as it sinks and pull in as it climbs. Eased with a sine so it lingers at
// both ends rather than sweeping through them.
//
// Backwards, because temporary lamps are DELETED from this array as they burn out and
// deleting during a forward walk skips the next entry. The shadow surfaces are indexed by
// position and are scratch -- cleared and restamped every frame -- so the indices shifting
// underneath them costs nothing.
for (var i = array_length(global.demo_lights) - 1; i >= 0; i--) {
    var _L = global.demo_lights[i];
    _L.ft += _dt;                             // every lamp's own effect clock
    if (_L.fx == "disco") {
        // The pool cycles with the ball. Left fixed, the floor stays one violet wash while
        // the spots on it run through the spectrum, and the two read as unrelated. This is
        // also what the sheen samples, so a character under it changes colour as it turns.
        _L.col = make_colour_hsv((_L.ft * 30) mod 256, 205, 104);
    }
    if (_L.rise) {
        _L.t += LIGHT_RISE_SPEED * _dt;
        _L.h = LIGHT_H_MIN + (LIGHT_H_MAX - LIGHT_H_MIN) * (0.5 - 0.5 * cos(_L.t));
    }
    if (_L.life < 0) continue;                // a permanent lamp
    _L.life -= _dt;
    if (_L.life <= 0) { array_delete(global.demo_lights, i, 1); continue; }
    // Full glare on the first frame, then decay. BOTH reach and strength fade, and both are
    // needed: reach alone only pulls the light in, so a blast at strength 3 kept stamping
    // solid black shadows inside an ever-smaller circle and then vanished mid-stroke. Power
    // is what actually dims it, so the last thing that happens is the light going out rather
    // than being switched off.
    var _k = power(_L.life / _L.life0, 0.55);
    _L.r   = _L.r0   * _k;
    _L.pow = _L.pow0 * _k;
}

// Explosions and strikes age out on the same clock. Drawn in Draw End, not here.
for (var b = array_length(global.demo_booms) - 1; b >= 0; b--) {
    var _B = global.demo_booms[b];
    _B.t += _dt;
    if (_B.t >= _B.dur) array_delete(global.demo_booms, b, 1);
}
for (var b = array_length(global.demo_bolts) - 1; b >= 0; b--) {
    var _B = global.demo_bolts[b];
    _B.t += _dt;
    // The strike's light follows the STROBE, not the smooth life decay every other
    // temporary light uses -- so the ground goes dark between strokes and blazes again with
    // each one, shadows and all. Written after the light loop above on purpose: this is the
    // same field, and the strobe is what should win for a bolt.
    // MULTIPLIES the smooth decay above rather than replacing it. Overwriting r with the
    // strobe meant the light was still at a third of full reach on the frame its life ran
    // out, and it snapped off; composing them lets it strobe on the way down and still
    // arrive at nothing.
    if (_B.light != undefined) {
        _B.light.r *= 0.34 + 0.66 * demo_bolt_env(_B, _B.t / _B.dur);
    }
    if (_B.t >= _B.dur) array_delete(global.demo_bolts, b, 1);
}

// Fissures. Their light flickers like something burning rather than fading off evenly --
// written after the light loop above on purpose, same as the strike's strobe.
for (var c = array_length(global.demo_cracks) - 1; c >= 0; c--) {
    var _C = global.demo_cracks[c];
    _C.t += _dt;
    if (_C.light != undefined) _C.light.r *= 0.78 + 0.22 * dsin(_C.t * 210);
    if (_C.t >= _C.dur) array_delete(global.demo_cracks, c, 1);
}

// Bonfires: flicker the light, and keep smoking. The puffs go into the ordinary smoke
// system so this fire's own light is one of the lights that lights them.
for (var f = 0; f < array_length(global.demo_fires); f++) {
    var _F = global.demo_fires[f];
    _F.t += _dt;
    // Flicker BRIGHTNESS, never reach. Reach was what flickered before, and reach is what
    // sets the size of the pool on the ground -- so the lit circle throbbed in and out like
    // a heartbeat, which no fire does. A fire lights the same patch of ground the whole
    // time and only varies in how brightly. Colour drives the pool and the sheen, `pow` the
    // shadows, so both move together and the circle stays put.
    if (_F.light != undefined) {
        var _fk = 0.84 + 0.1 * dsin(_F.t * 300) + 0.06 * dsin(_F.t * 131);
        _F.light.col = demo_col_scale(_F.lcol, _fk);
        _F.light.pow = _F.light.pow0 * _fk;
    }
    _F.emit -= _dt;
    if (_F.emit > 0) continue;
    _F.emit = 0.15 + random(0.13);
    demo_smoke_add({
        x  : _F.x + random_range(-5, 5),
        y  : _F.y + random_range(-3, 3),
        // Released from the TOP of the flames, not the base -- smoke off a fire appears
        // where the fire stops being bright, and starting it lower just draws grey over
        // the flames.
        z  : 50 + random(16),
        vx : random_range(-14, 14), vy: random_range(-14, 14), vz: 30 + random(20),
        r  : 7 + random(6), grow: 12 + random(11),
        t  : 0, life: 4.5 + random(2.2)
    });
}

// Smoke. Ground travel is halved on screen by the 2:1 metric; height is not, which is why
// z is subtracted straight off the screen y when it is drawn.
for (var s = array_length(global.demo_smoke) - 1; s >= 0; s--) {
    var _P = global.demo_smoke[s];
    _P.t += _dt;
    if (_P.t <  0)       continue;                    // not released yet; see demo_smoke_gun
    if (_P.t >= _P.life) { array_delete(global.demo_smoke, s, 1); continue; }
    _P.x += _P.vx * _dt;
    _P.y += _P.vy * 0.5 * _dt;
    _P.z += _P.vz * _dt;
    // The air takes the shot out of it quickly while the climb persists and slowly wins.
    // That order is what makes a puff read as FIRED -- punched out, then hanging and rising
    // -- rather than simply dropped where the cursor was.
    var _drag = power(0.16, _dt);
    _P.vx *= _drag;
    _P.vy *= _drag;
    _P.vz  = _P.vz * power(0.5, _dt) + 7 * _dt;
    _P.r  += _P.grow * _dt;
}

// B, not N or L: those keys move shadow settings below, and a key that both spawned a lamp
// and moved a shadow setting made every experiment with one contaminate the other.
if (keyboard_check_pressed(ord("B"))) demo_add_light(mouse_x, mouse_y);

// The three effect lamps, at the cursor. W and R used to be player keys (walk up, shuffle
// look) -- movement is on the arrows now and the shuffle moved to T, because a key that
// both walked and dropped a disco ball spawned one every time you stepped north.
if (keyboard_check_pressed(ord("W"))) demo_fx_light(mouse_x, mouse_y, "disco");
if (keyboard_check_pressed(ord("E"))) demo_fx_light(mouse_x, mouse_y, "water");
if (keyboard_check_pressed(ord("R"))) demo_fx_light(mouse_x, mouse_y, "galaxy");
if (keyboard_check_pressed(ord("S"))) demo_fx_light(mouse_x, mouse_y, "laser");

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

// THRONE_FX=1: the effects, without a keyboard. Places the three effect lamps around the
// player and then sets off a blast and a strike on a fixed clock, saving a screenshot part
// way through each. The keys they are normally on can only be pressed by hand or by faking
// input, and faking input means stealing the foreground from whatever the machine is doing
// -- which sends the keystrokes into someone else's window when it loses the race.
// THRONE_FX=solo: one fissure on bare ground, nothing else running. When several effects
// overlap it stops being possible to tell which one an artifact belongs to -- an eruption
// was blamed on the lasers and the lasers on the eruption for two builds running.
// THRONE_FX=fire2: TWO bonfires, to reproduce the rays reported between a pair of them.
// One is placed so a character stands in front of it and one so nobody does, which puts
// them in opposite depth buckets -- the case a single fire can never exercise.
// THRONE_FX=fun: fun mode from the first frame, for measuring what it actually costs.
if (environment_get_variable("THRONE_FX") == "fun") {
    if (!variable_instance_exists(id, "fx_t")) { fx_t = 0; demo_fun_toggle(); }
    fx_t++;
    if (fx_t == 260) screen_save("fun_a.png");
    if (fx_t == 500) screen_save("fun_b.png");
    if (fx_t == 520) game_end();
}

if (environment_get_variable("THRONE_FX") == "fire2") {
    if (!variable_instance_exists(id, "fx_t")) { fx_t = 0; fx_shot = 0; }
    fx_t++;
    if (fx_t == 2) {
        global.demo_lights = [];
        var _ps = instance_find(obj_demo_player, 0);
        // Same y on purpose: both land in the SAME depth bucket and both are well inside the
        // view, which separates "the bucket split is dropping one" from "the shared
        // primitive is dropping one". They cannot both be the answer.
        demo_fire(_ps.x - 150, _ps.y + 70);
        demo_fire(_ps.x + 150, _ps.y + 70);
    }
    // THRONE_NOSMOKE=1 empties the cloud every step. The rays only appear once a lot of
    // smoke is in the air, so this splits "the smoke batch is producing them" from "the
    // flame batch is" -- with the scene otherwise identical.
    if (environment_get_variable("THRONE_NOSMOKE") == "1") global.demo_smoke = [];
    if (fx_t > 2 && array_length(global.demo_fires) > 0) {
        var _f2 = global.demo_fires[0].t;
        // Late, so the smoke has had time to build up: the rays were reported after a while
        // of two fires burning, and at half a second there are barely three puffs in the air.
        var _a2 = [3, 7, 11, 15];
        if (fx_shot < 4 && _f2 >= _a2[fx_shot]) {
            screen_save("fire2_" + chr(ord("a") + fx_shot) + ".png");
            fx_shot++;
        }
        if (fx_shot >= 4 && _f2 > 15.4) game_end();
    }
}

// THRONE_FX=fire: one bonfire on bare ground, four frames spread over a couple of seconds.
// A flame is judged by whether it MOVES correctly, which a single frame cannot show -- the
// rigid-tongue version looked defensible in a still and obviously wrong in motion.
if (environment_get_variable("THRONE_FX") == "fire") {
    if (!variable_instance_exists(id, "fx_t")) { fx_t = 0; fx_shot = 0; }
    fx_t++;
    if (fx_t == 2) {
        global.demo_lights = [];
        var _ps = instance_find(obj_demo_player, 0);
        demo_fire(_ps.x + 120, _ps.y + 30);
    }
    if (fx_t > 2 && array_length(global.demo_fires) > 0) {
        var _ft = global.demo_fires[0].t;
        var _at = [0.35, 0.70, 1.05, 1.40];
        if (fx_shot < 4 && _ft >= _at[fx_shot]) {
            screen_save("fire_" + chr(ord("a") + fx_shot) + ".png");
            fx_shot++;
        }
        if (fx_shot >= 4 && _ft > 1.7) game_end();
    }
}

// THRONE_FX=galaxy: one galaxy lamp on bare ground, nothing else drawing over it.
if (environment_get_variable("THRONE_FX") == "galaxy") {
    if (!variable_instance_exists(id, "fx_t")) fx_t = 0;
    fx_t++;
    if (fx_t == 2) {
        global.demo_lights = [];
        var _ps = instance_find(obj_demo_player, 0);
        demo_fx_light(_ps.x + 60, _ps.y + 40, "galaxy");
    }
    if (fx_t == 24) screen_save("gal_a.png");
    if (fx_t == 90) screen_save("gal_b.png");
    if (fx_t == 96) game_end();
}

if (environment_get_variable("THRONE_FX") == "solo") {
    if (!variable_instance_exists(id, "fx_t")) { fx_t = 0; fx_shot = 0; }
    fx_t++;
    if (fx_t == 2) {
        global.demo_lights = [];
        var _ps = instance_find(obj_demo_player, 0);
        demo_add_light(_ps.x - 260, _ps.y - 60);
        demo_crack(_ps.x + 60, _ps.y + 70);
        demo_glacier(_ps.x - 120, _ps.y + 90);
    }
    // Fired off the fissure's OWN clock, not off a frame count. The effect runs on real
    // time, the first frames after a build are slow (shaders, surfaces), and shots taken at
    // fixed frame numbers landed after the eruption was already over -- which read as the
    // eruption barely drawing at all.
    // Two shots on the way down, two after the crater opens, so the whole event is covered.
    if (fx_t > 2) {
        var _mt = 99;
        if (array_length(global.demo_cracks) > 0) _mt = global.demo_cracks[0].t;
        var _at = [0.12, 0.35, 0.75, 1.9];
        if (fx_shot < 4 && _mt >= _at[fx_shot]) {
            screen_save("solo_" + chr(ord("a") + fx_shot) + ".png");
            fx_shot++;
        }
        if (fx_shot >= 4 && _mt > 2.3) game_end();
    }
}

if (environment_get_variable("THRONE_FX") == "1") {
    // Everything is placed around the PLAYER, not around the room. The camera follows the
    // player, who starts mounted and therefore not at the room centre -- room coordinates
    // put the first blast half off the left edge, which is a poor way to look at a blast.
    var _pf  = instance_find(obj_demo_player, 0);
    var _fpx = (_pf != noone) ? _pf.x : room_width  / 2;
    var _fpy = (_pf != noone) ? _pf.y : room_height / 2;
    if (!variable_instance_exists(id, "fx_t")) {
        fx_t = 0;
        demo_fx_light(_fpx - 300, _fpy - 40,  "disco");
        demo_fx_light(_fpx - 10,  _fpy + 190, "water");
        demo_fx_light(_fpx + 300, _fpy - 30,  "galaxy");
        // Close in front of the rider on purpose: its beams sweep across the pair, which is
        // the case the front/behind split has to get right.
        demo_fx_light(_fpx + 30, _fpy - 130, "laser");
        global.demo_snow = true;      // give it the whole run to build a covering
    }
    fx_t++;
    // The one-shots are transient, so each is caught a fixed few frames after it goes off:
    // early enough to be at full brightness, late enough to have opened out. All of them
    // close to the rider, since what they do to its shadow is the thing being looked at.
    if (fx_t == 40)  demo_boom(_fpx + 130, _fpy + 30);
    if (fx_t == 52)  screen_save("fx_boom.png");
    if (fx_t == 110) demo_bolt(_fpx + 140, _fpy + 40);
    if (fx_t == 116) screen_save("fx_bolt.png");
    // Caught EARLY -- the flame burst is over inside a tenth of the fissure's life, and it
    // is the part worth looking at.
    if (fx_t == 168) demo_fire(_fpx - 190, _fpy + 30);
    if (fx_t == 170) demo_crack(_fpx + 140, _fpy + 50);
    if (fx_t == 182) screen_save("fx_crack.png");
    if (fx_t == 250) screen_save("fx_crack_cool.png");
    // Smoke is slow on purpose, so it gets a long run to drift into the lamps and be lit.
    if (fx_t == 200) demo_smoke_gun(_fpx - 40, _fpy + 40);
    if (fx_t == 206) demo_smoke_gun(_fpx + 20, _fpy + 10);
    if (fx_t == 290) screen_save("fx_smoke.png");
    if (fx_t == 300) screen_save("fx_lamps.png");
    if (fx_t == 306) game_end();
}

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
            if (_n == "wave") {
                // Two loops of the wave clip; the player Step owns the how and the when.
                var _pw = instance_find(obj_demo_player, 0);
                if (_pw != noone) _pw.wave_t = 2.7;
            }
            else if (_n == "fun") demo_fun_toggle();
            // Reset is the C key with the cast put back as well -- one behaviour, one place.
            else if (_n == 0) {
                demo_kill(instance_number(obj_demo_skeleton));
                demo_spawn(3);
                demo_clear_all();
                global.demo_fun = false;
            }
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




