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
