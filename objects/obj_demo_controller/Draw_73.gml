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
var _nb = array_length(global.demo_booms);
if (_nb == 0) exit;

gpu_set_blendmode(bm_add);
for (var b = 0; b < _nb; b++) {
    var _B = global.demo_booms[b];
    var _u = _B.t / _B.dur;                        // 0 at ignition, 1 at burnout
    if (_u >= 1) continue;

    // Ground flash: a 2:1 ellipse, the iso circle-on-the-floor this whole demo draws light
    // pools with. First and fastest -- the floor lights up before the fireball has grown.
    var _gu = _u / 0.30;
    if (_gu < 1) {
        var _gr = 26 + 190 * _gu;
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
        var _cr = 14 + 74 * _cu;
        draw_circle_colour(_B.x, _B.y - 20 * _cu, _cr,
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
            demo_col_scale(demo_fire_col(_pu), 1 - _pu * _pu), c_black, false);
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
gpu_set_blendmode(bm_normal);
