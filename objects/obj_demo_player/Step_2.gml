/// Seat the rider on the mount, after the mount has moved.
///
/// GameMaker applies `speed`/`direction` motion between Step and End Step, so reading the
/// horse's position in Step alone leaves the rider one frame behind it -- up to 3.3 px at a
/// gallop, worst where the horse's motion is most vertical. The client has the same
/// structural lag; this costs three lines to remove.
///
/// The seat offset and its tilt-follow factor come from the MOUNT's rig file
/// (horse.rig.json `mount.seat`), so they can be tuned in the editor and saved.
if (mount != noone) {
    var _horse = mount;
    var _seat  = anim_mount_state(_horse.rig, _horse.direction);
    x     = _horse.x;
    y     = _horse.y + _seat.dy;
    depth = _horse.depth;        // the horse draws the rider, so this only has to match
}
