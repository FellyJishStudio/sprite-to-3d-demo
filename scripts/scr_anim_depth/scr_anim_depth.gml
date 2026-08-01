/// DEPTH
///
/// Within one character the parts have to be painted in the right order, and the order
/// changes as the character turns. Ported from pose.js computeDepths (player) and
/// computeHorseDepths (any rig with an isometric tilt).
///
/// Both tables collapse to one linear form, so the table itself lives in
/// datafiles/rigs/<rig>.demo.json and this evaluates it:
///
///     depth = base + (facing_down ? down : up)
///                  + mirror * X                    X = +/-1, the left/right flip
///                  + dirDep * P * X                P = the 45-degree-snapped facing step
///                  + legOff                        3 on whichever leg is furthest away
///
/// `base` is 0 for the humanoid. Rigs with an isometric tilt split their body into a near
/// and a far half instead, which is what stops a horse's far legs drawing over its near
/// ones as it turns:  front = y_adjust * 100,  back = facing_down ? 100 : 0.  Note which of
/// those two is nearer the camera swaps as the rig turns -- facing away, the "front" half is
/// the far one -- which is exactly why a rider must resolve against the same pair rather
/// than against a constant offset.
///
/// Every value is an offset around 0; the instance's own `depth = -y * 100` handles
/// ordering between characters.
///
/// `_e` is the entry prepared by anim_depth_entry() at load time -- plain numeric fields,
/// so this does no string lookups. `_front` and `_back` are the two resolved bases; a rider
/// is handed its MOUNT's pair, which is what sandwiches it between the horse's halves.
function anim_depth(_e, _f, _front, _back, _head_depth) {
    var _d = _f.down ? _e.down : _e.up;

    if      (_e.base == 1) _d += _front;                   // the tilted half
    else if (_e.base == 2) _d += _back;                    // the other half

    _d += _e.mirror * _f.mirror + _e.dirDep * _f.dirDep * _f.mirror;

    // The leg of a pair that is furthest from camera drops back, so the two cannot z-fight.
    if (_e.leg >= 0 && ((_e.leg == 1) == _f.right)) _d += 3;

    // Facing left pulls the sword arm in front of the head (pose.js:403-404).
    if (_e.clamped && _f.left) _d = min(_d, _head_depth + _e.clampOff);

    return _d;
}
