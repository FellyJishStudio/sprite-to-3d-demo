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

// Light pools: a 2:1 ellipse per light -- a circle of reach on the 1:2 isometric ground.
// Additive blending with a centre-to-black gradient is a free radial falloff: black adds
// nothing, so there is no visible rim. The bright dot is the lamp itself.
gpu_set_blendmode(bm_add);
for (var i = 0; i < array_length(global.demo_lights); i++) {
    var _L = global.demo_lights[i];
    var _w = _L.r * 0.5;
    draw_ellipse_colour(_L.x - _w, _L.y - _w * 0.5, _L.x + _w, _L.y + _w * 0.5,
                        make_colour_rgb(84, 66, 28), c_black, false);
    draw_circle_colour(_L.x, _L.y - 2, 4, make_colour_rgb(255, 236, 170), c_black, false);
}
gpu_set_blendmode(bm_normal);

// Cast-shadow layer: every character's silhouettes composited into ONE surface, then
// subtracted from the scene once. The surface is what makes each shadow UNIFORM -- parts
// stamp opaque grey (fog trick; brightness = the light's edge fade), so overlaps inside a
// silhouette cannot double-darken, and two characters' crossing shadows take the darker
// stamp instead of stacking. Scratch, not a cache: remade when lost or when the zoom
// resizes the view, cleared and restamped every frame.
if (global.anim_ready) {
    var _sw = round(camera_get_view_width(_cam)), _sh = round(camera_get_view_height(_cam));
    if (!surface_exists(shadow_surf) || surface_get_width(shadow_surf) != _sw
                                     || surface_get_height(shadow_surf) != _sh) {
        if (surface_exists(shadow_surf)) surface_free(shadow_surf);
        shadow_surf = surface_create(_sw, _sh);
    }
    surface_set_target(shadow_surf);
    draw_clear_alpha(c_black, 0);
    camera_apply(_cam);        // world coordinates land on the surface as they do on screen
    var _pw = instance_find(obj_demo_player, 0);
    if (_pw != noone && _pw.mount == noone) {
        anim_shadow_char(_pw.rig, _pw.clip, _pw.play, _pw.x, _pw.y, _pw.direction, _pw.look, true);
    }
    with (obj_demo_skeleton) anim_shadow_char(rig, clip, play, x, y, direction, look, false);
    with (obj_demo_horse)    anim_shadow_pair(self);
    // A silhouette lying across a light pool fades where that pool shines: subtract each
    // pool's bright core (about half the attenuation reach) from the stamped greys.
    gpu_set_blendmode(bm_subtract);
    for (var i = 0; i < array_length(global.demo_lights); i++) {
        var _L2 = global.demo_lights[i];
        var _fw = _L2.r * 0.55;
        draw_ellipse_colour(_L2.x - _fw, _L2.y - _fw * 0.5,
                            _L2.x + _fw, _L2.y + _fw * 0.5,
                            make_colour_rgb(90, 90, 90), c_black, false);
    }
    gpu_set_blendmode(bm_normal);
    surface_reset_target();
    // Composite four times at 1px diagonal offsets, quarter strength each: the interior
    // (where all four overlap) reaches full darkness, every edge gets a graduated
    // penumbra. The soft edge is what stops the silhouette reading as the rectangles the
    // sprites are actually made of -- a hard-edged stamp shows every art corner as a
    // block, worst when a toward-camera shadow compresses the figure.
    gpu_set_blendmode(bm_subtract);
    var _sc = make_colour_rgb(35, 35, 35);
    draw_surface_ext(shadow_surf, _x0 - 1, _y0 - 1, 1, 1, 0, _sc, 1);
    draw_surface_ext(shadow_surf, _x0 + 1, _y0 - 1, 1, 1, 0, _sc, 1);
    draw_surface_ext(shadow_surf, _x0 - 1, _y0 + 1, 1, 1, 0, _sc, 1);
    draw_surface_ext(shadow_surf, _x0 + 1, _y0 + 1, 1, 1, 0, _sc, 1);
    gpu_set_blendmode(bm_normal);
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
