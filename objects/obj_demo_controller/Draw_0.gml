/// Ground lattice: isometric diamonds, 2 wide to 1 tall, matching the projection the rig is
/// drawn with. Two families of parallel lines, slope +/-0.5, so a diamond is TILE*2 x TILE.
/// Drawn in world space at depth 20000, behind every character, and bounded to the camera
/// rect rather than the whole room -- an infinite lattice needs no more than the view.
/// (The characters themselves are NOT culled; see the note atop scr_anim_render.)
#macro GRID_TILE 32

var _cam = view_camera[0];
var _x0  = camera_get_view_x(_cam), _y0 = camera_get_view_y(_cam);
var _x1  = _x0 + camera_get_view_width(_cam), _y1 = _y0 + camera_get_view_height(_cam);
var _col = make_colour_rgb(58, 84, 56);

// y = x/2 + c, visible while c is in [y0 - x1/2, y1 - x0/2]
var _c = floor((_y0 - _x1 * 0.5) / GRID_TILE) * GRID_TILE;
while (_c <= _y1 - _x0 * 0.5) {
    draw_line_colour(_x0, _x0 * 0.5 + _c, _x1, _x1 * 0.5 + _c, _col, _col);
    _c += GRID_TILE;
}

// y = -x/2 + c, visible while c is in [y0 + x0/2, y1 + x1/2]
_c = floor((_y0 + _x0 * 0.5) / GRID_TILE) * GRID_TILE;
while (_c <= _y1 + _x1 * 0.5) {
    draw_line_colour(_x0, _c - _x0 * 0.5, _x1, _c - _x1 * 0.5, _col, _col);
    _c += GRID_TILE;
}

// Fissures go down FIRST, straight onto the bare grid. They are in the floor, and every
// other effect in the demo is above them -- pools, caustics, laser beams, the characters
// themselves, smoke. Rain ripples land on top of them for the same reason.
var _pt = get_timer();
demo_view_cache();       // the rect every cull below tests against; see demo_on_screen
demo_light_cache();      // once a frame, for everything that samples the lighting per particle
demo_snow_paint();       // the covering goes down before the cracks that scorch it away
gpu_set_blendmode(bm_add);
demo_shards_paint(false);   // ice that has come to rest lies ON the floor, with the snow
gpu_set_blendmode(bm_normal);
demo_cracks_paint();
demo_rain_paint();

if (prof_on) { prof_ground = lerp(prof_ground, get_timer() - _pt, 0.08); _pt = get_timer(); }

// Light pools: a 2:1 ellipse per light -- a circle of reach on the 1:2 isometric ground.
// Additive blending with a centre-to-black gradient is a free radial falloff: black adds
// nothing, so there is no visible rim. The bright dot is the lamp itself.
gpu_set_blendmode(bm_add);
for (var i = 0; i < array_length(global.demo_lights); i++) {
    var _L = global.demo_lights[i];
    // Nothing to draw for a lamp whose entire reach is off screen -- and that includes its
    // floor pattern, which for the water projector is a full-screen-quad shader pass.
    if (!demo_on_screen(_L.x, _L.y, _L.r)) continue;
    // Height spreads the pool and thins it: the same light falling on more floor. Squared
    // because it is spread over an area, which is also what keeps a low lamp reading as
    // bright and tight rather than merely smaller.
    var _hf = _L.h / LIGHT_H_MID;
    var _w  = _L.r * 0.5 * (0.55 + 0.45 * _hf);
    var _k  = clamp(1 / (_hf * _hf), 0.18, 1.6);
    if (_L.pool) {
        draw_ellipse_colour(_L.x - _w, _L.y - _w * 0.5, _L.x + _w, _L.y + _w * 0.5,
                            demo_col_scale(_L.col, _k), c_black, false);
    }
    // An effect lamp's pattern goes on the floor, in this same additive pass, before the
    // fixture -- so the stem and bulb sit on top of what they are throwing.
    if (_L.fx != "") demo_fx_paint(_L);
    // The lamp itself is drawn UP at its height -- height is straight screen-y, the one
    // axis the isometric projection does not halve -- with a stem down to the ground point
    // its pool and its shadows are actually measured from. A blast or a lightning strike
    // has no fixture: it IS the light, and drawing a lamp on a stem inside a fireball is
    // the sort of thing that only becomes obvious once it is on screen.
    if (_L.glyph) {
        var _ly = _L.y - _L.h;
        draw_line_colour(_L.x, _L.y, _L.x, _ly, make_colour_rgb(30, 26, 12),
                                                make_colour_rgb(90, 80, 40));
        draw_circle_colour(_L.x, _L.y - 2, 3, make_colour_rgb(40, 36, 18), c_black, false);
        draw_circle_colour(_L.x, _ly, 4, _L.tint ? demo_col_boost(_L.col)
                                                 : make_colour_rgb(255, 236, 170),
                           c_black, false);
    }
}
// Bonfires that someone is standing in FRONT of belong under the characters -- but ON TOP
// of the light pools, which is why this sits at the end of the additive pass rather than
// with the other ground work above it. Drawn before the pools, a fire was painted over by
// its OWN pool: the flames vanished and left a bright ellipse sitting on the grass.
demo_fires_paint(false);
gpu_set_blendmode(bm_normal);
if (prof_on) { prof_pools = lerp(prof_pools, get_timer() - _pt, 0.08); _pt = get_timer(); }

// Cast-shadow layer: every character's silhouettes composited into ONE surface, then
// subtracted from the scene once. The surface is what makes each shadow UNIFORM -- parts
// stamp opaque grey (fog trick; brightness = the light's edge fade), so overlaps inside a
// silhouette cannot double-darken, and two characters' crossing shadows take the darker
// stamp instead of stacking. Scratch, not a cache: remade when lost or when the zoom
// resizes the view, cleared and restamped every frame.
if (global.anim_ready) {
    var _nl = array_length(global.demo_lights);
    var _sw = round(camera_get_view_width(_cam)), _sh = round(camera_get_view_height(_cam));
    if (!surface_exists(caster_surf)) caster_surf = surface_create(caster_size, caster_size);
    // CULL FIRST. This is the most expensive thing in the demo by a wide margin -- a surface
    // plus a silhouette pass per caster, PER LIGHT -- and in fun mode most lamps are on the
    // far side of the map. A light whose whole reach misses the view can put nothing on
    // screen, so it is skipped here and skipped again in the composite below.
    //
    // ...and then only the STRONGEST FEW of what survives actually casts. This is the whole
    // cost of the demo: a surface plus a silhouette pass per caster per light. Fun mode runs
    // sixteen lights, which is eighty silhouette passes a frame, and it does not look four
    // times better than five would -- a dim lamp's shadow lying under four brighter ones is
    // not visible in the first place. The pools, the sheen and the particle lighting are
    // unaffected; every light still lights. Only casting is rationed.
    var _act = array_create(_nl, false);
    var _sco = array_create(_nl, -1);
    var _cx  = (view_x0 + view_x1) * 0.5, _cy = (view_y0 + view_y1) * 0.5;
    for (var l = 0; l < _nl; l++) {
        var _LC = global.demo_lights[l];
        if (!demo_on_screen(_LC.x, _LC.y, _LC.r)) continue;
        // Bright and near beats dim and far. Distance is measured in the iso ground metric,
        // the same one the shadows themselves are cast in.
        var _dx = _LC.x - _cx, _dy = (_LC.y - _cy) * 2;
        _sco[l] = (_LC[$ "pow"] ?? 1) * _LC.r / max(120, sqrt(_dx * _dx + _dy * _dy));
    }
    repeat (min(SHADOW_LIGHTS_MAX, _nl)) {
        var _best = -1, _bs = 0;
        for (var l = 0; l < _nl; l++) {
            if (_sco[l] > _bs) { _bs = _sco[l]; _best = l; }
        }
        if (_best < 0) break;
        _act[_best] = true;
        _sco[_best] = -1;
    }
    // Grow the surface list to match, EXPLICITLY, before anything is skipped. Filling it
    // lazily inside the loop broke as soon as culling was added: skipping light 0 and
    // touching light 1 makes GML widen the array to reach index 1, and it fills the hole it
    // just made with 0 -- not -1. Surface id 0 is the APPLICATION SURFACE, so the trim below
    // saw a live surface at a dead index and tried to free the screen out from under itself.
    while (array_length(shadow_surfs) < _nl) array_push(shadow_surfs, -1);
    for (var l = 0; l < _nl; l++) {
        if (!_act[l]) continue;
        // One surface per light, so each pool can fade OTHER lights' shadows crossing it
        // without touching its own -- a character inside a pool blocks that pool's light,
        // and its shadow there must stay strong, anchored at the stable object origin.
        if (!surface_exists(shadow_surfs[l]) || surface_get_width(shadow_surfs[l]) != _sw
                                             || surface_get_height(shadow_surfs[l]) != _sh) {
            if (surface_exists(shadow_surfs[l])) surface_free(shadow_surfs[l]);
            shadow_surfs[l] = surface_create(_sw, _sh);
        }
        var _dst = shadow_surfs[l], _cs = caster_surf, _cc = caster_cam;
        surface_set_target(_dst);
        draw_clear_alpha(c_black, 0);
        camera_apply(_cam);    // world coordinates land on the surface as they do on screen
        var _L = global.demo_lights[l];
        var _pw = instance_find(obj_demo_player, 0);
        if (_pw != noone && _pw.mount == noone) {
            anim_shadow_char(_L, _pw.rig, _pw.clip, _pw.play, _pw.x, _pw.y,
                             _pw.direction, _pw.look, true, _dst, _cam, _cs, _cc);
        }
        with (obj_demo_skeleton) anim_shadow_char(_L, rig, clip, play, x, y, direction,
                                                   look, false, _dst, _cam, _cs, _cc);
        with (obj_demo_horse)    anim_shadow_pair(_L, self, _dst, _cam, _cs, _cc);
        // LIGHT WASHES SHADOW: every OTHER lamp's illumination is subtracted from this
        // lamp's shadows, per pixel, using the SAME falloff the stamps themselves carry --
        // a shadow is only dark where no other light reaches, so where pools overlap it
        // fades, and one long cast brightens and darkens along its length as it crosses
        // them. Never this light's own pool: the caster is blocking that light, which is
        // the whole reason its shadow exists.
        //
        // The wash is the lamp's TRUE profile, not a flat core. An earlier flat oversized
        // fade carved invisible holes into shadows far from any visible glow (a missing
        // horse head, with the culprit light off-screen); a wash that follows the real
        // attenuation is by construction strong only where the glow is visibly strong, so
        // it cannot punch holes where the ground reads dark. Centre strength matches the
        // stamp formula -- 255*(1 - h/r), a raised lamp washes less -- and the ellipse
        // ends where its light does, at the ground reach sqrt(r*r - h*h). The gradient is
        // linear in ground distance where the stamps fade by through-the-air distance; the
        // difference is a few percent, flattest near the centre, and not worth a shader.
        //
        // ANIM_SHADOW_WASH scales the whole wash. At 1, two equally-lit overlapping pools
        // erase each other's shadows completely at the midpoint; physically about half the
        // darkness should survive there, so the wash runs below full strength.
        //
        // STRONGER LIGHT, STRONGER SHADOW. The wash is scaled by how bright the other lamp
        // is RELATIVE to this one (`pow`, see demo_add_light), so a blast or a strike drives
        // its shadows straight through the room's lamps while erasing theirs. Without the
        // ratio the comparison was absolute, and a dim lamp on the far side of the room
        // cancelled a lightning strike's shadow exactly as effectively as the strike
        // cancelled the lamp's -- which is backwards, and it is what made the loudest
        // lights in the demo the ones that moved the fewest shadows.
        gpu_set_blendmode(bm_subtract);
        var _pw = max(0.01, _L[$ "pow"] ?? 1);
        for (var j = 0; j < _nl; j++) {
            if (j == l || !_act[j]) continue;     // a lamp off screen washes nothing on it
            var _L2 = global.demo_lights[j];
            var _c0 = min(255, 255 * (1 - _L2.h / _L2.r) * ANIM_SHADOW_WASH
                               * ((_L2[$ "pow"] ?? 1) / _pw));
            if (_c0 <= 0) continue;
            var _fw = sqrt(max(0, _L2.r * _L2.r - _L2.h * _L2.h));
            draw_ellipse_colour(_L2.x - _fw, _L2.y - _fw * 0.5,
                                _L2.x + _fw, _L2.y + _fw * 0.5,
                                make_colour_rgb(_c0, _c0, _c0), c_black, false);
        }
        gpu_set_blendmode(bm_normal);
        surface_reset_target();
    }
    // Give back the surfaces of lights that have gone. With no ceiling on the light count
    // these are transient -- every blast and every strike brings one and takes it away
    // again -- and a surface per light ever created, kept forever, is a leak the old cap
    // was quietly preventing.
    for (var l = array_length(shadow_surfs) - 1; l >= _nl; l--) {
        var _old = shadow_surfs[l];
        // `> 0` and not merely `surface_exists`: id 0 is the application surface and must
        // never be freed here whatever ends up in this slot.
        if (_old > 0 && surface_exists(_old)) surface_free(_old);
        array_delete(shadow_surfs, l, 1);
    }
    // Composite each light's shadows as one full-strength CENTER tap plus four 1px
    // diagonal offsets at low strength: the offsets soften every outline (no rectangle
    // corners), while the center tap guarantees that even a THIN covered strip reads at
    // nearly full strength. Four offset-only taps once eroded 1px from every edge --
    // which deleted the pair's narrow waist between horse-back and rider (the
    // reported "middle body gap") and blurred away the head's small shadow lobe.
    gpu_set_blendmode(bm_subtract);
    var _scC = make_colour_rgb(112, 112, 112);
    var _scO = make_colour_rgb(8, 8, 8);
    for (var l = 0; l < _nl; l++) {
        if (!_act[l]) continue;      // its surface holds last frame's stamps; do not use it
        if (l >= array_length(shadow_surfs) || !surface_exists(shadow_surfs[l])) continue;
        draw_surface_ext(shadow_surfs[l], _x0,     _y0,     1, 1, 0, _scC, 1);
        draw_surface_ext(shadow_surfs[l], _x0 - 1, _y0 - 1, 1, 1, 0, _scO, 1);
        draw_surface_ext(shadow_surfs[l], _x0 + 1, _y0 - 1, 1, 1, 0, _scO, 1);
        draw_surface_ext(shadow_surfs[l], _x0 - 1, _y0 + 1, 1, 1, 0, _scO, 1);
        draw_surface_ext(shadow_surfs[l], _x0 + 1, _y0 + 1, 1, 1, 0, _scO, 1);
    }
    gpu_set_blendmode(bm_normal);
}
if (prof_on) prof_shadow = lerp(prof_shadow, get_timer() - _pt, 0.08);

// F3: the cast's own geometry, drawn over the finished shadows.
//
// Two red dots at the ground points the shadow's width is measured between -- the rig's own
// hoof columns, put back on the floor through the projection -- and the two rays out of the
// NEAREST lamp that graze them. The shadow is meant to be exactly what lies between those
// rays, so this turns that claim into something visible: grey outside the wedge, or wedge
// with no grey in it, is the bug, on screen, at the facing it happens.
//
// Drawn after the composite so it sits on top, and from the same calls the renderer makes
// so it cannot quietly disagree with what was painted.
if (global.anim_ready && variable_global_exists("anim_debug_cast") && global.anim_debug_cast) {
    var _nl2 = array_length(global.demo_lights);
    with (obj_demo_horse) {
        // Nearest lamp only. Every lamp at once is four wedges over one horse and reads as
        // noise; the one throwing the shadow being looked at is the one in question.
        var _best = -1, _bd = 999999;
        for (var i = 0; i < _nl2; i++) {
            var _Ld = global.demo_lights[i];
            var _d2 = point_distance(x, y, _Ld.x, _Ld.y);
            if (_d2 < _bd) { _bd = _d2; _best = i; }
        }
        if (_best >= 0) {
            anim_shadow_debug(global.demo_lights[_best], rig, direction, false, x, y);
        }

        // The two numbers the width rule is decided from, put where they are decided.
        //
        // On the CASTER, its own facing. Over each LAMP, this caster's facing RELATIVE to
        // that lamp -- zero meaning pointed straight at it, which is the alignment that
        // collapses the shadow. Relative rather than absolute because that is the quantity
        // that matters and working it out by eye from two absolute bearings is exactly the
        // sort of arithmetic that has gone wrong repeatedly here.
        //
        // Per lamp, because it is per lamp: the same caster is lined up with one and
        // broadside to another in the same frame, and only the aligned one widens.
        draw_set_halign(fa_center);
        draw_set_colour(c_white);
        draw_text(x, y - 78, string_format(direction, 3, 0));

        for (var i = 0; i < _nl2; i++) {
            var _Ld  = global.demo_lights[i];
            // Bearing from the lamp out to the caster, then how far the caster's own facing
            // sits off it. angle_difference gives the signed -180..180, so +/-180 is
            // pointed dead away and 0 is pointed dead at it.
            var _bear = point_direction(_Ld.x, _Ld.y, x, y);
            var _rel  = angle_difference(direction, _bear);
            // Grey for a lamp too far off to cast at all, so a reading that means nothing
            // is not mistaken for one that does. Nothing else is inferred here: this
            // reports the geometry and makes no claim about what the shadow will do with it.
            var _sd = anim_light_shadow(_Ld, x, y);
            draw_set_colour((_sd == undefined) ? c_gray : c_aqua);
            draw_text(_Ld.x, _Ld.y - _Ld.h - 20, string_format(_rel, 4, 0));
        }
        draw_set_colour(c_white);
        draw_set_halign(fa_left);
    }
}

// Walk destination. The client draws the same thing -- an outlined 10x6 ellipse at
// target_x/target_y, yellow for a ground target (obj_player/Draw_0.gml:63-65). It leaves it
// up permanently; here it goes away on arrival, and sits at this depth so characters walk
// over it rather than behind it.
var _pl = instance_find(obj_demo_player, 0);
if (_pl != noone && point_distance(_pl.x, _pl.y, _pl.target_x, _pl.target_y) > 3) {
    draw_set_colour(c_yellow);
    draw_set_alpha(0.5);
    draw_ellipse(_pl.target_x - 5, _pl.target_y - 3, _pl.target_x + 5, _pl.target_y + 3, true);
    draw_set_alpha(1);
    draw_set_colour(c_white);
}
