/// RENDER
///
/// A transcription of tools/anim_pipeline/src/pose.js renderPose(). The "fake 3D" that
/// gets 360 degrees of facing out of a flat side-on rig is two things, neither of them a
/// projection matrix:
///
///   1. X offsets scaled by cos(direction) -- an orthographic view of the side-view rig
///      rotated about the vertical axis, collapsing to a front view at 90 and 270.
///   2. Each bone sprite rotated to point at the NEXT joint and X-scaled by
///      distance / naturalLength, so segments stay visually connected however they bend.
///
/// Two traps, both of which have cost debugging time before:
///   * single-bone chains take a DIFFERENT path from multi-bone chains (see below);
///   * armature offsets are ROTATED by direction + 90, they are not plain additions.

/// One entry in the flat draw list built below. Plain numbers rather than a struct per
/// part: a humanoid is fourteen parts and a busy room is hundreds of characters, and
/// per-part allocation is the only thing in here that costs measurable time.
enum PART { DEPTH, SPR, SUB, X, Y, ANG, XS, YS, COL, ALPHA, SIZE }

/// There is deliberately NO off-camera culling here. The game has one
/// (node_armature/Draw_0.gml:2-12); this demo dropped it so the fps readout measures what
/// the animation actually costs -- a cull makes the number a function of where the camera
/// happens to be pointing, which reads as "fps rises when I zoom in" and says nothing
/// about capacity. Every instance pays full pose-and-paint cost every frame.

/// Every facing-derived quantity.
///
/// The subtlety worth its own function: two angle spaces are live at once. The continuous
/// pose is driven by the RAW direction, while the discrete decisions (which way the
/// sub-images face, which side the depth bias falls on) come from the SKEWED direction
/// produced by the anisotropic remap in scr_get_render_dir2. A local player additionally
/// takes its depth side from the raw angle, everything else from the skewed one.
///
/// The X foreshortening comes from that SAME angle, not always the raw one. armature_update
/// stores whatever direction its caller passed, and armature_update_owner.gml:254-255 takes
/// `dcos` from that stored value. obj_horse passes render_dir (:673, and
/// __baked_pose_use_armature_direction = true in its Create), while a local player passes
/// its raw direction -- so an animal foreshortens on cos(skew) and the player on cos(raw).
/// pose.js uses the raw angle for every rig, which is right for the player and wrong for
/// the horse; the visible symptom is a seam opening between the body halves.
function anim_facing(_rig, _dir, _is_player) {
    var _raw  = ((_dir % 360) + 360) % 360;
    var _skew = point_direction(0, 0, dcos(_raw) * 0.2, -dsin(_raw) * 0.6);
    var _dep  = _is_player ? _raw : _skew;

    // One shared struct, overwritten by every call -- valid until the next anim_facing,
    // anywhere. Every caller reads it out before another call can happen; nothing may
    // store it. This is the render loop's hottest allocation site, once per character
    // per frame, which is why it is scratch and not a fresh struct.
    static _f = { raw:0, skew:0, dep:0, dcos:0, zsin:0, mirror:0, down:false, dirDep:0,
                  left:false, up:false, right:false };
    _f.raw    = _raw;
    _f.skew   = _skew;
    _f.dep    = _dep;
    _f.dcos   = dcos(_dep);
    // Z's projection coefficient, from the SAME angle as dcos. Z is the lateral axis --
    // perpendicular to the rig plane -- and rotating the rig about the vertical axis sends
    // rig-x to screen-x times cos and rig-z to screen-x times -sin: a z motion sweeps side
    // to side facing the camera, mirrors facing away, and vanishes in profile.
    _f.zsin   = -dsin(_dep);
    _f.mirror = (_raw > 90 && _raw < 270) ? -1 : 1;
    // Which band counts as "facing away" is per rig, and the rigs genuinely disagree.
    _f.down   = !(_skew < _rig.faceBand[1] && _skew > _rig.faceBand[0]);
    _f.dirDep = sign(dcos(round(_dep / 45) * 45)) + ((_dep < 135 && _dep > 45) ? 1 : 0);
    _f.left   = (_dep < 270 && _dep > 90);
    _f.up     = (_dep > 30 && _dep < 150);
    _f.right  = (_skew >= 270 || _skew < 90);
    return _f;
}

/// Sub-image. Frame 1 on these sprites is the BACK-facing variant, not an animation frame,
/// except on the bones a rig lists in `subImageRule.steepBand`, which flip on a band of the
/// skewed direction instead. Membership was resolved to `steep_band` at load.
function anim_sub(_bone, _steep, _back) {
    if (_bone.frames <= 1) return 0;
    if (_bone.steep_band) return _steep ? 1 : 0;
    return _back;
}

/// Isometric tilt offset for one bone: the near half of the body rides up and down with
/// sin(skew) as the rig turns.
///
/// Transcribed from obj_horse/Step_0.gml:798-850 rather than from pose.js, which differs
/// from the game on two bones (see the "iso" note in horse.demo.json):
///   front half   y - y_adjust          full tilt, and no facing_down step
///   spine        y - y_adjust/2 - 1    half tilt AND the step        (:812)
///   far half     y - 1                 the step only                 (:801-811)
///   tail         y                     neither, in either branch     (:803, :845)
/// The name-list scans became the per-bone iso_cls / iso_flat flags at load.
function anim_iso(_cls, _flat, _iso_y, _down) {
    if (_cls == 2) return -_iso_y;
    var _dy = (_cls == 1) ? -0.5 * _iso_y : 0;
    if (_down && !_flat) _dy -= 1;
    return _dy;
}

/// Where a rider sits on a mount, and the two depth bases its parts lay out against.
/// A transcription of pose.js mountState(); the values all come from the MOUNT's own rig
/// file (`mount` block in horse.rig.json), which is what the editor edits and saves.
///
///   front / back   the mount's two depth proxy bases. Handing these to the rider is what
///                  sandwiches it between the mount's halves at every facing.
///   dy             seat height. The client pins it flat while the saddle rides up and down
///                  with the tilt; seat.followTilt closes that. 0 reproduces the client.
function anim_mount_state(_rig, _dir) {
    var _m = _rig[$ "mount"];
    if (!is_struct(_m)) return undefined;
    var _f = anim_facing(_rig, _dir, false);
    var _iso = _rig.iso, _y = 0;
    if (_iso != undefined) {
        _y = (_f.down ? _iso.ampDown : _iso.ampUp) * dsin(_f.skew);
        if (abs(_y) <= 1 && _f.down) _y = 0;
    }
    return {
        block  : _m,
        front  : _y * 100,
        back   : _f.down ? 100 : 0,
        dy     : _m.seat.dy - _y * (_m.seat[$ "followTilt"] ?? 0),
        // The mount foreshortens on the SKEWED angle, a local player on the raw one -- up
        // to 30 degrees apart, which splays the rider while the horse narrows. When set,
        // the rider adopts the mount's angle space, mirroring pose.js mountState().
        squash : _m.seat[$ "squashFollow"] ?? true
    };
}

/// Draw a posed character at (_x, _y).
///
/// `_look` maps an appearance slot name to a blend colour; a slot set to `undefined` hides
/// every part that uses it. That one mechanism covers the skeleton losing its hair and face
/// and the sword toggling on and off. See scr_demo_look.
///
/// `_mount` is the state returned by anim_mount_state() for a rig this one is riding. The
/// client renders a horse as two depth proxies (`__horse_front_depth_base` /
/// `__horse_back_depth_base`, obj_horse/Step_0.gml:717-727) and slots the rider between
/// them, so the neck stays in front of the rider and the barrel behind it at every facing.
/// Laying the rider out against those two bases is what makes that sandwich come out of the
/// sort for free -- the near limbs land on the front base, the far ones on the back base.
/// The offsets are `mount.riderDepth` in the MOUNT's rig file.
///
/// Appends to `_parts` rather than drawing, so a mount and its rider can share one sorted
/// list. Positions are absolute.
function anim_build(_parts, _rig, _clip, _play, _x, _y, _dir, _look, _is_player,
                    _mount = undefined) {
    var _f    = anim_facing(_rig, _dir, _is_player);
    var _dcos = _f.dcos, _zsin = _f.zsin, _mir = _f.mirror, _down = _f.down;
    var _dat  = _clip.data;
    var _rows = _clip.row;
    var _at   = anim_frame_base(_clip, _play);   // index of this frame's first float
    // Synthesized right-arm tip, for the sword. Scratch, like everything else here: it is
    // built for every character with an arm chain, sword or not.
    static _tip = { x:0, y:0, depth:0, ang:0 };
    var _has_tip = false;
    var _base  = array_length(_parts);            // where this character's parts start

    var _iso = _rig.iso, _iso_y = 0;
    if (_iso != undefined) {
        _iso_y = (_down ? _iso.ampDown : _iso.ampUp) * dsin(_f.skew);
        if (abs(_iso_y) <= 1 && _down) _iso_y = 0;
    }

    // The two depth bases every `base: front/back` entry resolves against. A rider borrows
    // its mount's pair so both end up on one scale.
    var _mounted = (_mount != undefined);
    var _front = _mounted ? _mount.front : _iso_y * 100;
    var _back_base = _mounted ? _mount.back : (_down ? 100 : 0);
    var _rd = _mounted ? _mount.block.riderDepth : undefined;

    // Which side of the rider is away from the camera. (side 0 = left, 1 = right.)
    //
    // The bone names are inverted relative to what you see: the source sequences label the
    // track driving bone_arm_RIGHT_upper as "Left Arm". So a *_left_* bone is the visible
    // RIGHT side, and facing left -- where you see the character's left -- the *_left_*
    // bones are the FAR ones. Do not "correct" this to match the names.
    var _far = -1;
    if (_mounted) _far = _f.left ? 0 : 1;

    // Squash-follow: foreshorten this rider on the mount's skewed angle (see
    // anim_mount_state) -- BOTH coefficients, or the rider would shear.
    if (_mounted && _mount.squash) { _dcos = dcos(_f.skew); _zsin = -dsin(_f.skew); }

    // Bones whose sub-image follows a rig-specific steep band instead of facing_down.
    var _rule = _rig.steep, _steep = false;
    if (_rule != undefined) {
        _steep = (_f.skew > _rule.band[0] && _f.skew < _rule.band[1])
              || (_f.skew > 180 + _rule.band[0] && _f.skew < 180 + _rule.band[1]);
    }
    var _back = _down ? 0 : 1;    // frame 1 is the BACK-facing art, not an animation frame

    // Resolve each tint slot's colour once per character, not once per bone. Reading from
    // the look struct HERE, every frame, is what keeps runtime slot mutation working --
    // Step flips look.sword and look.shadow live, so colours must never be captured
    // anywhere longer-lived than this call.
    static _cols = [];
    var _tn  = _rig.tintNames;
    var _ntn = array_length(_tn);
    array_resize(_cols, _ntn);
    for (var t = 0; t < _ntn; t++) _cols[t] = _look[$ _tn[t]];

    // The sword arm is clamped in front of the head when facing left, so the head's depth
    // has to be known before any chain is placed.
    var _head_depth = (_rig.headChain < 0 || _mounted) ? 0
        : anim_depth(_rig.chain[_rig.headChain].depth, _f, _front, _back_base, 0);

    var _chains = _rig.chain;
    var _nc     = array_length(_chains);
    // Workspaces, reused across calls rather than allocated per character per frame --
    // with hundreds of characters the per-frame garbage was the measurable cost. All of
    // them are consumed before this function returns, and anim_build is never reentrant
    // (a mount and its rider are built one after the other, not inside each other).
    static _start = [];                    // where each chain's parts begin, for the pins
    array_resize(_start, _nc);
    for (var i = 0; i < _nc; i++) _start[i] = -1;
    for (var c = 0; c < _nc; c++) {
        var _ch = _chains[c];
        var _bs = _ch.bones;
        var _n  = array_length(_bs);

        var _depth;
        if (_mounted && _ch.role != "") {
            // Mounted layout, from the mount's own rig data rather than this rig's table.
            // The two bases SWAP places as the mount turns: lifting its front half pushes
            // that half away, so `front` is not reliably the nearer one. Anchor the near
            // parts to whichever end is actually nearest and the rule holds at every
            // angle -- torso, head and the near arm/leg over the whole mount, far arm/leg
            // behind all of it. Anchoring to `front` let the rump draw over the rider's
            // chest at the facings where the tilt is largest.
            var _near_b = min(_front, _back_base);
            var _far_b  = max(_front, _back_base);
            var _is_far = (_ch.side >= 0 && _ch.side == _far);
            switch (_ch.role) {
                case "arm":  _depth = _is_far ? _far_b + _rd.farArm : _near_b + _rd.nearArm; break;
                case "leg":  _depth = _is_far ? _far_b + _rd.farLeg : _near_b + _rd.nearLeg; break;
                case "head": _depth = _near_b + _rd.head; break;
                default:     _depth = _near_b + _rd.body; break;
            }
        } else {
            _depth = anim_depth(_ch.depth, _f, _front, _back_base, _head_depth);
        }
        var _scale = _ch.scale;

        // Armature offsets are ROTATED by direction + 90 (armature_update.gml:10-11).
        var _ax = _ch.arm[0];
        if (_ch.armBy != undefined) {
            _ax = _f.left ? _ch.armBy.left : (_down ? _ch.armBy.rightDown : _ch.armBy.rightUp);
        }
        var _ox = _ch.pos[0] + lengthdir_x(_ax, _f.raw + 90);
        var _oy = _ch.pos[1] + lengthdir_y(_ch.arm[1], _f.raw + 90);

        if (_n == 1) {
            // SINGLE-BONE CHAIN -- body, head, and every animal armature. There is no next
            // joint, so there is no dist/naturalLength stretch, the angle is the baked
            // angle squashed by cos(direction), and the mirror lives on X, not Y.
            var _m   = _bs[0];
            var _col = _cols[_m.tintIdx];       // per BONE: the hands are skin, not sleeve
            if (_col == undefined) continue;
            var _r = _at + _rows[_m.slot];
            _start[c] = array_length(_parts);   // pin recorded: the push below is certain
            array_push(_parts,
                _depth,
                _m.sprite,
                anim_sub(_m, _steep, _back),
                // X foreshortened by cos(direction), z swept in by -sin of the same angle.
                // The armature SCALE reaches the sprite only, never the joint position --
                // multiplying the position by it drags the part toward the origin, which
                // once sank the head into the torso.
                _x + _dat[_r + ANIM_X] * _dcos + _dat[_r + ANIM_Z] * _zsin + _ox,
                _y + _dat[_r + ANIM_Y] + _oy
                    + ((_iso == undefined) ? 0 : anim_iso(_m.iso_cls, _m.iso_flat, _iso_y, _down)),
                _dat[_r + ANIM_ANGLE] * _dcos,
                _dat[_r + ANIM_XSCALE] * _mir * _scale,
                _dat[_r + ANIM_YSCALE] * _scale,
                _col,
                _dat[_r + ANIM_ALPHA]);
            continue;
        }

        // MULTI-BONE CHAIN. Project every joint first: each bone sprite has to know where
        // the next one starts.
        //
        // Z is an out-of-plane PIVOT, not a translation: a bone's z displaces its FAR end,
        // so joint i takes the previous bone's z (the chain root takes none) and the tip
        // takes the last bone's. That is what makes a waving forearm pivot at the elbow
        // instead of dragging the elbow with it.
        static _jx = []; static _jy = []; static _row = [];
        array_resize(_jx, _n); array_resize(_jy, _n); array_resize(_row, _n);
        var _zj = 0;        // z applied at the joint being placed (previous bone's)
        var _zpen = 0;      // z applied at the LAST joint, for the tip differential
        for (var i = 0; i < _n; i++) {
            var _r2 = _at + _rows[_bs[i].slot];
            _row[i] = _r2;
            _jx[i] = _x + _dat[_r2 + ANIM_X] * _dcos + _zj * _zsin + _ox;
            _jy[i] = _y + _dat[_r2 + ANIM_Y] + _oy
                   + ((_iso == undefined) ? 0
                      : anim_iso(_bs[i].iso_cls, _bs[i].iso_flat, _iso_y, _down));
            _zpen = _zj;
            _zj   = _dat[_r2 + ANIM_Z];
        }

        // The tip is synthesized from the last bone's own length and baked angle -- note
        // cos(direction) applies to X only, and the last bone's z lands here in full.
        var _la = _dat[_row[_n - 1] + ANIM_ANGLE];
        var _ln = _bs[_n - 1].len;
        var _ex = _jx[_n - 1] + _ln * _dcos * dcos(_la) + (_zj - _zpen) * _zsin;
        var _ey = _jy[_n - 1] - _ln * dsin(_la);

        if (c == _rig.armChain) {          // the chain a held item hangs off
            _has_tip  = true;
            _tip.x    = _ex;  _tip.y = _ey;  _tip.depth = _depth;
            _tip.ang  = point_direction(_jx[_n - 1], _jy[_n - 1], _ex, _ey);
        }
        // Facing the camera: root over tip. Facing away: reversed, so the shoulder covers
        // the hand. A chain shares one depth, so this is only about emission order.
        var _first = array_length(_parts);
        for (var k = 0; k < _n; k++) {
            var i   = _down ? k : (_n - 1 - k);
            var _nx = (i == _n - 1) ? _ex : _jx[i + 1];
            var _ny = (i == _n - 1) ? _ey : _jy[i + 1];
            var _m   = _bs[i];
            var _col = _cols[_m.tintIdx];
            if (_col == undefined) continue;
            var _sw  = _m.len * _dat[_row[i] + ANIM_XSCALE];
            array_push(_parts,
                _depth,
                _m.sprite,
                anim_sub(_m, _steep, _back),
                _jx[i],
                _jy[i],
                point_direction(_jx[i], _jy[i], _nx, _ny),
                (_sw != 0) ? point_distance(_jx[i], _jy[i], _nx, _ny) / _sw : 1,
                _dat[_row[i] + ANIM_YSCALE] * _mir,
                _col,
                _dat[_row[i] + ANIM_ALPHA]);
        }
        // Only record the pin if something was actually emitted, or it would point at the
        // next chain's first part.
        if (array_length(_parts) > _first) _start[c] = _first;
    }

    // Attachments are not bones: they are transforms pinned to a drawn chain each frame
    // (pose.js buildAttachments). Which chain, which appearance slot, which sprite and how
    // far in front all come from <rig>.demo.json, so a rig without an `attach` list -- the
    // horse -- simply does nothing here.
    var _attach = _rig.attach;
    for (var i = 0; i < array_length(_attach); i++) {
        var _a = _attach[i];
        var _col = _look[$ _a.slot];
        if (_col == undefined) continue;
        if (_a.onlyFacingDown && !_down) continue;      // a face is hidden from behind
        var _p = _start[_a.at];
        if (_p < 0) continue;                           // that chain was not drawn
        array_push(_parts,
            _parts[_p + PART.DEPTH] + _a.depth,
            _look[$ _a.sprite],
            (_a.sub == "back") ? _back : _a.sub,
            _parts[_p + PART.X], _parts[_p + PART.Y], _parts[_p + PART.ANG],
            _parts[_p + PART.XS], _parts[_p + PART.YS], _col, 1);
    }

    var _sword = _look[$ "sword"];
    if (_has_tip && _sword != undefined) {
        // The wrist twist fades out as the character turns toward or away from camera.
        var _ang = _tip.ang + 90 * _mir * abs(dcos(round(_f.dep / 6) * 6 + 20));
        var _sx  = 1;
        if (_f.left) { _ang += 180; _sx = -1; }   // and the blade comes past the head
        array_push(_parts, _tip.depth + (_f.left ? 1 : 0), _look.sword_spr, 0,
                   _tip.x, _tip.y, _ang, _sx, 1, _sword, 1);
    }

    // Ground shadows. The client pins the horse's pair to the DRAWN body halves, +25 in y
    // (obj_horse/Step_0.gml:963-969), and gives a humanoid an obj_shadow at its own x/y. A
    // huge depth just puts them at the back of this character's own paint order.
    var _shade = _look[$ "shadow"];
    if (_shade != undefined) {
        var _spec = _rig.shadow;
        for (var i = 0; i < array_length(_spec); i++) {
            var _s = _spec[i];
            var _p = (_s.at < 0) ? -1 : _start[_s.at];
            if (_s.at >= 0 && _p < 0) continue;              // that chain was not drawn
            array_push(_parts, 1000000, _look.shadow_spr, _s.sub,
                (_p < 0) ? _x : _parts[_p + PART.X],
                ((_p < 0) ? _y : _parts[_p + PART.Y]) + _s.dy,
                0, _s.sx, _s.sy, _shade, _s.alpha);
        }
    }

    return _parts;
}

/// Sort a built list and paint it. GameMaker draws HIGHER depth first (further back). A few
/// dozen entries at most, so an insertion sort over an index list beats a comparator
/// callback -- and it is stable, which is what makes the chain emission order mean anything.
function anim_paint(_parts) {
    var _count = array_length(_parts) div PART.SIZE;
    var _order = array_create(_count);
    for (var i = 0; i < _count; i++) _order[i] = i * PART.SIZE;
    for (var i = 1; i < _count; i++) {
        var _v = _order[i], _d = _parts[_v + PART.DEPTH], j = i - 1;
        while (j >= 0 && _parts[_order[j] + PART.DEPTH] < _d) { _order[j + 1] = _order[j]; j--; }
        _order[j + 1] = _v;
    }

    for (var i = 0; i < _count; i++) {
        var _o = _order[i];
        var _spr = _parts[_o + PART.SPR];
        // An appearance slot that never resolved arrives as -1 (asset_get_index missed) or
        // undefined (a look struct without that _spr field). Either one would abort the
        // whole frame mid-list and take every remaining part with it, so skip just that
        // entry and name it once -- a missing hand is a far better failure than a missing
        // character plus a stack trace.
        // NB: do NOT test is_real() here. In 2024.x a sprite asset is a typed reference,
        // not a plain real, so is_real() is false for every VALID sprite and this guard
        // would silently skip the entire draw list. sprite_exists() handles -1 on its own.
        if (_spr == undefined || !sprite_exists(_spr)) {
            static _reported = {};
            var _key = string(_spr) + "/" + string(_parts[_o + PART.DEPTH]);
            if (!variable_struct_exists(_reported, _key)) {
                _reported[$ _key] = true;
                show_debug_message("ANIM: unresolved sprite " + string(_spr)
                    + " (part " + string(i + 1) + " of " + string(_count)
                    + ", depth " + string(_parts[_o + PART.DEPTH])
                    + ", sub " + string(_parts[_o + PART.SUB])
                    + ", at " + string(_parts[_o + PART.X]) + "," + string(_parts[_o + PART.Y])
                    + ") - skipped");
            }
            continue;
        }
        draw_sprite_ext(_spr, _parts[_o + PART.SUB],
                        _parts[_o + PART.X], _parts[_o + PART.Y],
                        _parts[_o + PART.XS], _parts[_o + PART.YS], _parts[_o + PART.ANG],
                        _parts[_o + PART.COL], _parts[_o + PART.ALPHA]);
    }

    // F1 overlay: paint order and depth per part, so "which of these two overlapping brown
    // shapes is on top" is answerable by reading rather than squinting. Drawn after the
    // sprites, in paint order, so the labels stack the same way the art does.
    // Guarded rather than relying on some object's Create having run first: anim_paint
    // is called from Draw events whose order is not guaranteed against that.
    if (variable_global_exists("anim_debug_depth") && global.anim_debug_depth) {
        draw_set_font(-1);
        for (var i = 0; i < _count; i++) {
            var _o2 = _order[i];
            var _s2 = _parts[_o2 + PART.SPR];
            if (_s2 == undefined || !sprite_exists(_s2)) continue;
            // sprite_get_name needs the asset-name table, which some targets strip; the
            // index is still a usable label when it is missing.
            var _nm = string_replace(sprite_get_name(_s2) ?? string(_s2), "spr_", "");
            var _tx = _parts[_o2 + PART.X], _ty = _parts[_o2 + PART.Y];
            draw_set_colour(c_black);
            draw_text(_tx + 1, _ty + 1, string(i) + ":" + _nm + " " + string(_parts[_o2 + PART.DEPTH]));
            draw_set_colour(c_yellow);
            draw_text(_tx, _ty, string(i) + ":" + _nm + " " + string(_parts[_o2 + PART.DEPTH]));
        }
        draw_set_colour(c_white);
    }
}

/// Append cast-shadow copies of a built character to its own parts list, one set per
/// in-range light. The shadow is the ANIMATED pose, not a blob: every bone part is
/// re-emitted black at its planar projection onto the ground, so the silhouette waves,
/// walks and rides exactly as the character does, one shear per light.
///
/// The projection is the textbook point-light one. A part at height h above the ground
/// anchor (_gx, _gy) lands at
///
///     offset = (part - light) * h / (lightHeight - h)
///
/// and the ISOMETRIC 1:2 GROUND cancels out of that offset entirely: converting a screen
/// delta to ground space doubles y, projecting scales it, converting back halves it
/// again. So the sheared positions use screen deltas directly -- where the 1:2 world DOES
/// appear is the attenuation metric (a light reaches twice as far along x as along
/// screen-y, so ground distance doubles dy) and the 2:1 glow pools the controller draws.
///
/// Stateless: recomputed from the parts list every frame, nothing cached, nothing keyed.
function anim_cast_shadows(_parts, _gx, _gy) {
    var _lights = global.demo_lights;
    var _nl = array_length(_lights);
    if (_nl == 0) return;
    var _count = array_length(_parts);      // snapshot: shadows must not shadow shadows
    for (var l = 0; l < _nl; l++) {
        var _L  = _lights[l];
        var _dy = (_gy - _L.y) * 2;                        // iso 1:2: true ground distance
        var _gd = sqrt(sqr(_gx - _L.x) + sqr(_dy));
        if (_gd > _L.r) continue;
        var _a = 0.38 * (1 - _gd / _L.r);                  // fade toward the light's edge
        for (var i = 0; i < _count; i += PART.SIZE) {
            if (_parts[i + PART.DEPTH] >= 900000) continue;     // contact blobs cast nothing
            var _h = _gy - _parts[i + PART.Y];                  // height above the ground
            if (_h <= 1) continue;
            // Clamped so a part near the light's own height cannot shoot to infinity.
            var _f = _h / max(_L.h - _h, 18);
            array_push(_parts,
                999500 - l,                                // on the ground, over the blob
                _parts[i + PART.SPR], _parts[i + PART.SUB],
                _parts[i + PART.X] + (_parts[i + PART.X] - _L.x) * _f,
                _gy + (_gy - _L.y) * _f,
                _parts[i + PART.ANG],
                _parts[i + PART.XS], _parts[i + PART.YS],
                c_black, _a * _parts[i + PART.ALPHA]);
        }
    }
}

/// The shared parts list, emptied and handed out. One character (or one mount + rider
/// pair) builds into it and paints it before the next asks for it, so a single array
/// serves every draw this frame instead of hundreds of fresh ones feeding the GC.
/// Valid until the next anim_scratch() call -- build and paint it before then.
function anim_scratch() {
    static _s = [];
    array_resize(_s, 0);
    return _s;
}

/// Draw one character on its own.
function anim_draw(_rig, _clip, _play, _x, _y, _dir, _look, _is_player) {
    var _p = anim_build(anim_scratch(), _rig, _clip, _play, _x, _y, _dir, _look, _is_player);
    anim_cast_shadows(_p, _x, _y);
    anim_paint(_p);
}
