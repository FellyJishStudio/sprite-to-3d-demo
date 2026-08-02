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

anim_paint(_parts);
