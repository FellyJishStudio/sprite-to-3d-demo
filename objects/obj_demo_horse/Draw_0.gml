/// A ridden horse draws its rider too, into ONE sorted list.
///
/// The client renders a horse as two depth proxies and slots the rider between them
/// (obj_horse/Step_0.gml:717-727), so its neck stays in front of the rider while its barrel
/// stays behind, at every facing. A separate rider instance cannot do that -- one instance
/// depth cannot sit both in front of and behind another. Merging the two characters into a
/// single depth-sorted list reproduces it exactly: the rider's parts resolve against THIS
/// rig's two bases, using the offsets in its own `mount` block.
var _parts = anim_scratch();

if (rider != noone) {
    var _r = rider;
    anim_build(_parts, _r.rig, _r.clip, _r.play,
               _r.x, _r.y, _r.direction, _r.look, true, anim_mount_state(rig, direction));
}
anim_build(_parts, rig, clip, play, x, y, direction, look, false);

// Cast shadows: horse and rider shear against the SAME ground anchor and light, so the
// pair lies down as one silhouette.
var _nl = array_length(global.demo_lights);
for (var l = 0; l < _nl; l++) {
    var _s = anim_light_shadow(global.demo_lights[l], x, y);
    if (_s == undefined) continue;
    var _first = array_length(_parts);
    if (rider != noone) {
        var _r2 = rider;
        anim_build(_parts, _r2.rig, _r2.clip, _r2.play,
                   _r2.x, _r2.y, _r2.direction, _r2.look, true,
                   anim_mount_state(rig, direction), _s);
    }
    anim_build(_parts, rig, clip, play, x, y, direction, look, false, undefined, _s);
    anim_shadow_tint(_parts, _first, _s.alpha, 999500 - l);
}

anim_paint(_parts);
