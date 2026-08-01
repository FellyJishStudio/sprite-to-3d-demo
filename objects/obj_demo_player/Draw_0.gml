// While mounted the horse draws this rider, interleaved with its own parts.
if (mount != noone) exit;
anim_draw(rig, global.clips[$ clip], play, x, y, direction, look, true);
