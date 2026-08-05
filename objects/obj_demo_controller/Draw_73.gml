/// Explosions. DRAW END, not Draw: this controller sits at depth 20000 so its grid lands
/// behind every character, and fire drawn there would be hidden by the very things it is
/// meant to be going off in front of. Draw End runs after every instance's Draw, still in
/// world coordinates, so the blast lands on top of the scene without the controller having
/// to leave the back of the depth order.
///
/// Everything here is ADDITIVE, which is what makes it read as light rather than as paint:
/// overlapping puffs pile toward white-hot instead of muddying, and each shape's own
/// centre-to-black gradient gives a soft edge for free -- black adds nothing, so there is
/// no rim and no need for a sprite.
///
/// The light is not drawn here at all. demo_boom adds a real one to global.demo_lights, so
/// the glare drives the same cast-shadow pass as every other lamp.

if (!variable_global_exists("demo_booms")) exit;

var _pt = get_timer();
gpu_set_blendmode(bm_add);

// Laser beams landing NEARER the camera than anyone who could cover them. The rest were
// drawn down on the ground; demo_beam_front owns the split.
demo_fx_paint_front();

// Rain, in front of everything. Each drop takes the colour of the light it is falling
// through -- the same sampling the smoke uses, at the drop's own height -- so a shower
// crossing the fissure comes down red and crossing the water projector comes down cyan.
//
// All of them in ONE primitive. Two hundred drops as two hundred draw_line calls cost more
// than every other effect in the demo combined -- a line list submits the same geometry as
// a single batch, and it is the call count that hurts, not the pixels.
//
// Drops sample the lighting in GROUPS rather than one at a time. Two hundred drops each
// asking every light was most of what this pass cost, and a raindrop is a two-pixel streak:
// nobody can tell that the one beside it took its colour from a point a few units away.
// One sample per eight drops, reused, and they are scattered through the shower anyway.
var _nd = array_length(global.demo_drops);
if (_nd > 0) {
    draw_primitive_begin(pr_linelist);
    var _dc = c_white;
    for (var d = 0; d < _nd; d++) {
        var _D  = global.demo_drops[d];
        var _sy = _D.y - _D.z;
        if ((d & 7) == 0) _dc = demo_smoke_light(_D.x, _D.y, _D.z);
        draw_vertex_colour(_D.x, _sy, _dc, 0.22);
        draw_vertex_colour(_D.x + 1.5, _sy + _D.len, _dc, 0.8);
    }
    draw_primitive_end();
}

// Snow still in the air, in front of everything, one batch again. Each flake sways as it
// comes down and is drawn as an iso diamond, the same shape it will be once it lands.
var _nf = array_length(global.demo_flakes);
if (_nf > 0) {
    var _fc = make_colour_rgb(238, 246, 255);
    demo_batch_begin();
    for (var f = 0; f < _nf; f++) {
        var _F  = global.demo_flakes[f];
        var _fx = _F.x + dsin(_F.ph) * _F.sw;
        var _fy = _F.y - _F.z + dcos(_F.ph * 0.7) * 2;
        demo_batch_room(6);
        draw_vertex_colour(_fx,       _fy - 1.7, _fc, 0.85);
        draw_vertex_colour(_fx + 3.4, _fy,       _fc, 0.85);
        draw_vertex_colour(_fx,       _fy + 1.7, _fc, 0.85);
        demo_batch_room(6);
        draw_vertex_colour(_fx,       _fy - 1.7, _fc, 0.85);
        draw_vertex_colour(_fx,       _fy + 1.7, _fc, 0.85);
        draw_vertex_colour(_fx - 3.4, _fy,       _fc, 0.85);
    }
    draw_primitive_end();
}

demo_fires_paint(true);         // the fires nobody is standing in front of
demo_meteors_paint();
demo_glaciers_paint();
demo_shards_paint(true);        // ...and the ice still in the air

var _nb = array_length(global.demo_booms);
for (var b = 0; b < _nb; b++) {
    var _B = global.demo_booms[b];
    var _u = _B.t / _B.dur;                        // 0 at ignition, 1 at burnout
    if (_u >= 1) continue;
    if (!demo_on_screen(_B.x, _B.y, 240)) continue;

    // Ground flash: a 2:1 ellipse, the iso circle-on-the-floor this whole demo draws light
    // pools with. First and fastest -- the floor lights up before the fireball has grown.
    //
    // Deliberately TIGHT and short. This is drawn over the finished shadow layer, so every
    // pixel of floor it covers is floor whose shadows cannot be seen; at its first size it
    // blanketed a wider circle than the blast's own shadows reach and hid the lot.
    var _gu = _u / 0.22;
    if (_gu < 1) {
        var _gr = 20 + 88 * _gu;
        draw_ellipse_colour(_B.x - _gr, _B.y - _gr * 0.5, _B.x + _gr, _B.y + _gr * 0.5,
            demo_col_scale(merge_colour(make_colour_rgb(255, 246, 214),
                                        make_colour_rgb(255, 150,  40), _gu),
                           (1 - _gu) * (1 - _gu)),
            c_black, false);
    }

    // Core: the white-hot heart, lifting as it goes. Brief -- it is what the eye reads as
    // the detonation itself, and holding it any longer makes the blast look slow.
    var _cu = _u / 0.24;
    if (_cu < 1) {
        var _cr = 12 + 52 * _cu;
        draw_circle_colour(_B.x, _B.y - 34 * _cu, _cr,
            demo_col_scale(merge_colour(c_white, make_colour_rgb(255, 224, 130), _cu),
                           1 - _cu * _cu),
            c_black, false);
    }

    // Fireballs. Each runs its own clock from its own start delay, so the cluster blooms
    // outward instead of appearing at once, and each travels its own way and cools through
    // the white-yellow-orange-red ramp as it goes.
    var _np = array_length(_B.puff);
    for (var i = 0; i < _np; i++) {
        var _P  = _B.puff[i];
        var _pu = (_u - _P.t0) / (1 - _P.t0);
        if (_pu <= 0 || _pu >= 1) continue;
        // Fast out of the blast, then settling: most of the travel is spent in the first
        // third of its life, which is what a real fireball does.
        var _e  = 1 - power(1 - _pu, 2.4);
        var _px = _B.x + lengthdir_x(_P.dist * _e, _P.ang);
        var _py = _B.y + lengthdir_y(_P.dist * _e, _P.ang) * 0.5   // iso: y spread halved
                       - _P.rise * _e;                            // ...and it rises
        draw_circle_colour(_px, _py, _P.size * (0.35 + 0.95 * _e),
            demo_col_scale(demo_ramp(_B.pal, _pu), 1 - _pu * _pu), c_black, false);
    }

    // Sparks: thrown out fast, slowed, and pulled back down. Kept pale so they stay
    // legible as points against the fireballs they are flying out of.
    var _ns = array_length(_B.spark);
    for (var i = 0; i < _ns; i++) {
        var _S  = _B.spark[i];
        var _su = (_u - _S.t0) / (1 - _S.t0);
        if (_su <= 0 || _su >= 1) continue;
        var _d  = _S.spd * _su * (1 - 0.45 * _su);
        var _sx = _B.x + lengthdir_x(_d, _S.ang);
        var _sy = _B.y + lengthdir_y(_d, _S.ang) * 0.5
                       - (_S.up * _su - 150 * _su * _su);          // up, then gravity
        draw_circle_colour(_sx, _sy, _S.size + 0.6,
            demo_col_scale(make_colour_rgb(255, 242, 186), 1 - _su), c_black, false);
    }
}

/// LIGHTNING.
///
/// Every path is drawn in three passes -- a wide dim halo, a mid glow, then a thin white
/// core over the top. That stack is the whole trick: one line of any width reads as a line
/// that has been drawn, and three concentric ones read as something incandescent, because
/// what the eye actually looks for is the falloff around the channel rather than the
/// channel itself.
var _nz = array_length(global.demo_bolts);
for (var z = 0; z < _nz; z++) {
    var _Z = global.demo_bolts[z];
    var _u = _Z.t / _Z.dur;
    if (_u >= 1) continue;
    var _e = demo_bolt_env(_Z, _u);                        // the strobe; see demo_bolt_env
    if (_e <= 0.01) continue;
    if (!demo_on_screen(_Z.x, _Z.y - 200, 420)) continue;

    var _halo = demo_col_scale(make_colour_rgb( 70, 118, 255), _e * 0.42);
    var _mid  = demo_col_scale(make_colour_rgb(168, 206, 255), _e * 0.85);
    var _core = demo_col_scale(make_colour_rgb(255, 255, 255), _e);

    // Ground discharge first, so the bolt itself lands on top of it.
    for (var a = 0; a < array_length(_Z.arc); a++) {
        var _p = _Z.arc[a];
        for (var i = 0; i < array_length(_p) - 1; i++) {
            var _x0 = _Z.x + _p[i][0],     _y0 = _Z.y + _p[i][1];
            var _x1 = _Z.x + _p[i + 1][0], _y1 = _Z.y + _p[i + 1][1];
            draw_line_width_colour(_x0, _y0, _x1, _y1, 4, _halo, _halo);
            draw_line_width_colour(_x0, _y0, _x1, _y1, 1, _mid,  _mid);
        }
    }

    // The strike: forks under the main channel, so the channel stays the brightest thing.
    for (var f = 0; f <= array_length(_Z.fork); f++) {
        var _p  = (f < array_length(_Z.fork)) ? _Z.fork[f] : _Z.main;
        var _w  = (f < array_length(_Z.fork)) ? 0.55 : 1;   // branches are thinner
        for (var i = 0; i < array_length(_p) - 1; i++) {
            var _x0 = _Z.x + _p[i][0],     _y0 = _Z.y + _p[i][1];
            var _x1 = _Z.x + _p[i + 1][0], _y1 = _Z.y + _p[i + 1][1];
            draw_line_width_colour(_x0, _y0, _x1, _y1, 11 * _w, _halo, _halo);
            draw_line_width_colour(_x0, _y0, _x1, _y1,  5 * _w, _mid,  _mid);
            draw_line_width_colour(_x0, _y0, _x1, _y1,  2 * _w, _core, _core);
        }
    }

    // Impact: a hot core on the floor, and a shockwave running out of it. The wave runs on
    // the strike's own clock rather than the strobe, so it keeps expanding through the dark
    // between strokes instead of stalling and restarting with each one.
    var _ir = 14 + 40 * _e;
    draw_ellipse_colour(_Z.x - _ir, _Z.y - _ir * 0.5, _Z.x + _ir, _Z.y + _ir * 0.5,
                        demo_col_scale(make_colour_rgb(226, 240, 255), _e), c_black, false);
    // FIVE nested outlines on a falling curve, dim. One hard ellipse read as drawn geometry
    // -- its edge was exactly as sharp as the HUD's, which is the giveaway -- and stacking a
    // few at falling strength is the cheapest edge that falls off.
    //
    // It also runs on its OWN clock, a third of the strike's, and eases out on a cubic. Left
    // on the full life it crawled outward for two seconds and then blinked off, and a ring
    // that is still visible when it stops is a ring that pops. Dimmer than the bolt
    // throughout, on purpose: the channel has to stay the brightest thing in the strike.
    var _ru = _u / 0.34;
    if (_ru < 1) {
        var _rr = 30 + 260 * (1 - power(1 - _ru, 1.7));
        var _rf = power(1 - _ru, 2.6) * 0.5;
        for (var k = 0; k < 5; k++) {
            var _kr = _rr + k * 2.5;
            var _kc = demo_col_scale(make_colour_rgb(150, 200, 255), _rf * (1 - k * 0.19));
            draw_ellipse_colour(_Z.x - _kr, _Z.y - _kr * 0.5,
                                _Z.x + _kr, _Z.y + _kr * 0.5, _kc, _kc, true);
        }
    }
}

// Fissure embers. The cracks themselves are drawn down with the ground (demo_cracks_paint);
// only what rises OUT of them belongs up here in front of the characters.
//
// Each vent runs on a repeating fraction of the fissure's clock rather than a one-shot life,
// so it keeps venting for as long as the crack is open -- a stream, not a puff.
var _nk = array_length(global.demo_cracks);
for (var c = 0; c < _nk; c++) {
    var _C = global.demo_cracks[c];
    var _u = _C.t / _C.dur;
    if (_u >= 1 || _u < 0.06) continue;             // nothing vents before it is open
    if (!demo_on_screen(_C.x, _C.y, 220)) continue;
    var _cool = power(1 - _u, 0.7);
    for (var v = 0; v < array_length(_C.vent); v++) {
        var _V  = _C.vent[v];
        var _vu = frac(_C.t * _V.spd + _V.t0);
        var _ex = _C.x + _V.x + dsin(_C.t * 90 + v * 47) * 3 * _vu;   // drifts as it climbs
        var _ey = _C.y + _V.y - _V.up * _vu;
        draw_circle_colour(_ex, _ey, _V.size * (1 - _vu * 0.6),
            demo_col_scale(demo_fire_col(_vu), (1 - _vu) * _cool), c_black, false);
    }
}
gpu_set_blendmode(bm_normal);

/// SMOKE. Two passes over the whole cloud rather than two per puff -- per-puff would be two
/// blend-mode switches each for no difference on screen.
///
/// The BODY comes first, under normal blending: dark and translucent, so the cloud is
/// something in the way. Then the light it catches, additive, sampled per puff from every
/// lamp at that puff's own position and height. Glow alone floats over the scene like a
/// decal; body alone is a grey smear that ignores the room it is drifting through.
var _ns = array_length(global.demo_smoke);
if (_ns > 0) {
    var _body = make_colour_rgb(20, 20, 26);
    for (var s = 0; s < _ns; s++) {
        var _P = global.demo_smoke[s];
        if (_P.t < 0) continue;                       // not released yet; see demo_smoke_gun
        if (!demo_on_screen(_P.x, _P.y - _P.z, _P.r)) continue;
        var _u = _P.t / _P.life;
        demo_blob(_P.x, _P.y - _P.z, _P.r, 0.86, _body,
                  min(1, _u * 7) * (1 - _u) * (1 - _u) * 0.46);
    }
    gpu_set_blendmode(bm_add);
    for (var s = 0; s < _ns; s++) {
        var _P = global.demo_smoke[s];
        if (_P.t < 0) continue;
        if (!demo_on_screen(_P.x, _P.y - _P.z, _P.r)) continue;
        var _u = _P.t / _P.life;
        // Low, because these OVERLAP: two dozen puffs from one shot pile up on each other,
        // and additively a strength that looks right for one is a white ball for the cloud.
        // Puffs cache their lit colour and refresh it on a stagger, like the ice shards do.
        // Smoke drifts slowly and its light changes slowly with it; asking every lamp every
        // frame for every puff bought nothing anyone could see.
        if (_P.ci <= 0) {
            _P.col = demo_smoke_light(_P.x, _P.y, _P.z);
            _P.ci  = 4 + (s mod 5);
        } else {
            _P.ci--;
        }
        demo_blob(_P.x, _P.y - _P.z, _P.r * 0.94, 0.86, _P.col,
                  min(1, _u * 7) * (1 - _u) * (1 - _u) * 0.20);
    }
    gpu_set_blendmode(bm_normal);
}
if (prof_on) prof_front = lerp(prof_front, get_timer() - _pt, 0.08);
