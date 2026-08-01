/// SAMPLING
///
/// This is the entire runtime cost of "playing" an animation, and it is the point of the
/// whole pipeline: the baker already sampled the curves and composed every parent chain
/// into root-relative world space, so at runtime there is no sequence to evaluate, no
/// hierarchy to walk, no matrix stack, no IK and no interpolation.
///
/// A frame is an array index. One bone is six floats at
///
///     clip.data[ anim_frame_base(clip, play) + clip.row[bone.slot] + ANIM_<component> ]
///
/// which is what the renderer's inner loop does, inline.

#macro ANIM_X      0
#macro ANIM_Y      1
#macro ANIM_ANGLE  2
#macro ANIM_XSCALE 3
#macro ANIM_YSCALE 4
#macro ANIM_ALPHA  5

/// Index of the first float of the frame a playhead is on. `play` is in sequence seconds;
/// frame = floor(play * sampleRate) mod totalFrames -- a plain wrap, exactly as
/// armature_update_player_baked.gml:26-27 does it. Note that clips authored as `pingpong`
/// (anim_idle, anim_ride) wrap here too: the v3 binary has no playback field and the game's
/// runtime does not honour the mode either, so the manifest carries it for reference only.
function anim_frame_base(_clip, _play) {
    var _f = floor(_play * _clip.rate) % _clip.frames;
    if (_f < 0) _f += _clip.frames;
    return _f * _clip.stride;
}
