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

    // Shadows build with the SAME iso tilt as the drawn figure. The horse's art is
    // authored to be contiguous WITH the tilt applied per facing -- a flat build was
    // tried for shadows and opened 1-7px seams between its body pieces at camera-facing
    // angles. (The "boxes" that flat build chased were a colour artifact of the fog era,
    // fixed for real by sh_silhouette's uniform grey.)
    var _iso = _rig.iso;
    var _iso_y = 0;
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
            // A gesture can pull one chain in front of the whole head while facing the
            // camera: the waving hand must beat the hair, whose depth is head - 10. The
            // slot lives on the look struct so Step can flip it live, like the sword.
            if (_down && _look[$ "frontChain"] == _ch.id) _depth = _head_depth - 12;
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
            // X foreshortened by cos(direction), z swept in by -sin of the same angle.
            // The armature SCALE reaches the sprite only, never the joint position --
            // multiplying the position by it drags the part toward the origin, which
            // once sank the head into the torso.
            var _px = _x + _dat[_r + ANIM_X] * _dcos + _dat[_r + ANIM_Z] * _zsin + _ox;
            var _py = _y + _dat[_r + ANIM_Y] + _oy
                    + ((_iso == undefined) ? 0 : anim_iso(_m.iso_cls, _m.iso_flat, _iso_y, _down));
            var _pang = _dat[_r + ANIM_ANGLE] * _dcos;
            var _pxs  = _dat[_r + ANIM_XSCALE] * _mir * _scale;
            var _pys  = _dat[_r + ANIM_YSCALE] * _scale;
            _start[c] = array_length(_parts);   // pin recorded: the push below is certain
            array_push(_parts,
                _depth,
                _m.sprite,
                anim_sub(_m, _steep, _back),
                _px,
                _py,
                _pang,
                _pxs,
                _pys,
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
    // The blob hands over to the cast-shadow system as lights get close: anim_blob_scale.
    var _shade = _look[$ "shadow"];
    var _blob_a = (_shade != undefined) ? anim_blob_scale(_x, _y) : 0;
    if (_shade != undefined && _blob_a > 0.02) {
        var _spec = _rig.shadow;
        for (var i = 0; i < array_length(_spec); i++) {
            var _s = _spec[i];
            var _p = (_s.at < 0) ? -1 : _start[_s.at];
            if (_s.at >= 0 && _p < 0) continue;              // that chain was not drawn
            array_push(_parts, 1000000, _look.shadow_spr, _s.sub,
                (_p < 0) ? _x : _parts[_p + PART.X],
                ((_p < 0) ? _y : _parts[_p + PART.Y]) + _s.dy,
                0, _s.sx, _s.sy, _shade, _s.alpha * _blob_a);
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

/// One light's shear, for a character standing at (_gx, _gy) -- or undefined when the
/// light does not reach it. A shadow is NOT a displaced copy of the finished parts: that
/// scatters bone-sized sprites along a line and the figure tears apart. It is a second
/// anim_build pass whose JOINTS are laid onto the ground first, so the point-at-next-joint
/// stretch then draws connected, correctly elongated bones between them -- the same
/// mechanic that keeps the standing character connected keeps its shadow connected.
///
///     joint (jx, jy) at height h = gy - jy   ->   (jx + kx*h, gy + ky*h)
///
/// (kx, ky) is the unit ground direction away from the light times h*groundDist/lightHeight
/// -- a linear slope, so the figure stays in one piece and lengthens smoothly with
/// distance. The ISOMETRIC 1:2 ground supplies both the direction and the metric: ground
/// deltas double screen-y going in and halve coming back, so a light reaches twice as far
/// along x as along screen-y and the shadow of a ring of characters is a true circle on
/// the iso ground. Stateless: recomputed every frame.
function anim_light_shadow(_L, _gx, _gy) {
    var _dgx = _gx - _L.x;
    var _dgy = (_gy - _L.y) * 2;                     // screen y -> iso ground y
    var _gd  = sqrt(_dgx * _dgx + _dgy * _dgy);
    if (_gd > _L.r || _gd < 1) return undefined;
    // Length cap 1.6, down from 2.2: sunset-length shadows turned a mounted pair (75px of
    // stacked height) into a screen-crossing wedge that read as a smear, not a figure.
    var _s  = min(_gd / _L.h, 1.6);                  // shadow length per pixel of height
    // The shear is the PURE iso away-direction: unit ground vector away from the light,
    // times s, with ground-y halved back onto the screen -- with ONE exception: |ky| is
    // floored at 0.35, sign preserved. At near-horizontal shear the projection
    // degenerates onto a single line, and a wide pose's lateral spread separates parts
    // ALONG that line -- the shadow fragmented into dashes. The floor keeps enough
    // vertical spread for the figure to stay connected and shaped. Diagonal and
    // north/south shadows are untouched (their |ky| already clears it); this is NOT the
    // old constant +0.3 bias, which bent every direction toward the camera.
    var _kx = (_dgx / _gd) * _s;
    var _ky = (_dgy / _gd) * 0.5 * _s;
    if (abs(_ky) < 0.35) _ky = (_ky < 0) ? -0.35 : 0.35;
    // ...and capped above: a steep toward-camera shear stretches the figure's height
    // bands APART, and where the front view is sparse (thin legs, the belly) the bands
    // separate into detached stripes -- the shadow read as floating blobs with holes.
    // Capping the slope keeps the bands overlapping into one grounded mass.
    _ky = clamp(_ky, -0.55, 0.55);
    var _kl = sqrt(_kx * _kx + _ky * _ky);           // s > 0, so never zero
    return {
        kx   : _kx,
        ky   : _ky,
        gy   : _gy,
        // Every part keeps its TRUE projected position: lateral offsets stay due east at
        // every light angle (no mirror, ever), heights ride the shear. The one degeneracy
        // -- a due east/west light folds the figure toward a line -- is answered by
        // THICKENING the stamp (extra passes offset vertically, see anim_shadow_paint),
        // never by re-aiming the width: two earlier attempts that redirected lateral
        // offsets scrambled wide figures, ramming the horse's length into vertical steps
        // that read as a mirrored edge. Thickness fades in smoothly as the axis
        // approaches horizontal, so nothing pops.
        thick : 3.0 * max(0, 1 - abs(_ky / _kl) / 0.55),
        // Brightness stamped into the shadow surface: full at the light, 0 at its edge.
        a255 : round(255 * (1 - _gd / _L.r))
        // There is deliberately NO lateral mirror at any light angle. The rig is a
        // billboard: its lateral axis IS the ground's east-west axis, and a planar
        // projection maps east to east whichever way the shadow falls -- a sword pointing
        // east casts an east-pointing shadow both toward and away from the camera. A
        // toward-camera "mirror" was tried here and looked wrong on screen; do not
        // reintroduce it from the screen-image-orientation argument (the shear's negative
        // determinant), which is about the picture, not the world.
    };
}

/// Paint a built character as ONE sheared silhouette for one light, straight to the
/// active target (the controller's shadow surface). The shadow transform
///
///     T(p) = (px + kx*(gy - py),  gy + ky*(gy - py))
///
/// is AFFINE in the part's screen position, so each part's drawn QUAD goes through T
/// corner by corner (draw_sprite_pos). Affinity is the no-gaps guarantee: parts that
/// touch standing up still touch sheared, whatever their angle -- the previous
/// lie-down-and-stretch pass approximated this per part and opened seams on every
/// diagonal one (the horse's neck). Colour comes from the fog the caller set.
function anim_shadow_paint(_parts, _s) {
    var _count = array_length(_parts);
    var _kx = _s.kx, _ky = _s.ky, _gy = _s.gy;
    var _th = _s.thick;
    var _reps = (_th >= 0.5) ? 3 : 1;    // near east-west: stamp thrice, offset +/- thick
    // sh_silhouette makes the stamp a FLAT grey: the texture contributes only its alpha
    // shape, the vertex colour the value. Neither fog (ignored by textured primitives --
    // it silently left sprite colours in the surface, so black hair cast nothing and the
    // dark horse cast weakly) nor alpha-channel accumulation (blend equations proved
    // unreliable on the alpha channel here, overlaps showed as translucent boxes) can do
    // this in the fixed pipeline. Opaque grey stamps overwrite each other, so overlaps
    // inside a silhouette stay uniform, exactly like the approved look.
    var _grey = make_colour_rgb(_s.a255, _s.a255, _s.a255);
    shader_set(sh_silhouette);
    for (var i = 0; i < _count; i += PART.SIZE) {
        if (_parts[i + PART.DEPTH] >= 900000) continue;      // contact blobs cast nothing
        var _al = _parts[i + PART.ALPHA];
        if (_al <= 0) continue;                              // hidden stays hidden
        var _spr = _parts[i + PART.SPR];
        if (_spr == undefined || !sprite_exists(_spr)) continue;
        var _sub = _parts[i + PART.SUB];
        var _px = _parts[i + PART.X],  _py = _parts[i + PART.Y];
        var _xs = _parts[i + PART.XS], _ys = _parts[i + PART.YS];
        var _ca = dcos(_parts[i + PART.ANG]), _sa = dsin(_parts[i + PART.ANG]);
        // NOT draw_sprite_pos: texture pages auto-crop sprites, and that function maps
        // the TRIMMED texture onto the full-size quad -- every cropped part smears. The
        // quad here is the trimmed rect itself (uvs[4..7]), in local pixels around the
        // origin, scaled and rotated exactly as draw_sprite_ext would place it, then
        // sheared corner by corner. Textured primitives also honour the fog the caller
        // set, which draw_sprite_pos does not.
        var _uv = sprite_get_uvs(_spr, _sub);
        var _u0 = (_uv[4] - sprite_get_xoffset(_spr)) * _xs;
        var _v0 = (_uv[5] - sprite_get_yoffset(_spr)) * _ys;
        var _u1 = _u0 + sprite_get_width(_spr)  * _uv[6] * _xs;
        var _v1 = _v0 + sprite_get_height(_spr) * _uv[7] * _ys;
        var _x1 = _px + _u0 * _ca + _v0 * _sa,  _y1 = _py - _u0 * _sa + _v0 * _ca;
        var _x2 = _px + _u1 * _ca + _v0 * _sa,  _y2 = _py - _u1 * _sa + _v0 * _ca;
        var _x3 = _px + _u1 * _ca + _v1 * _sa,  _y3 = _py - _u1 * _sa + _v1 * _ca;
        var _x4 = _px + _u0 * _ca + _v1 * _sa,  _y4 = _py - _u0 * _sa + _v1 * _ca;
        // Corner -> shadow: the TRUE projection, nothing else. x keeps the corner's own
        // east-west position plus the shear; y is the shear alone.
        var _sx1 = _x1 + _kx * (_gy - _y1), _sy1 = _gy + _ky * (_gy - _y1);
        var _sx2 = _x2 + _kx * (_gy - _y2), _sy2 = _gy + _ky * (_gy - _y2);
        var _sx3 = _x3 + _kx * (_gy - _y3), _sy3 = _gy + _ky * (_gy - _y3);
        var _sx4 = _x4 + _kx * (_gy - _y4), _sy4 = _gy + _ky * (_gy - _y4);
        for (var _r = 0; _r < _reps; _r++) {
            var _dy = (_r == 0) ? 0 : ((_r == 1) ? -_th : _th);
            draw_primitive_begin_texture(pr_trianglestrip, sprite_get_texture(_spr, _sub));
            draw_vertex_texture_colour(_sx1, _sy1 + _dy, _uv[0], _uv[1], _grey, _al);
            draw_vertex_texture_colour(_sx2, _sy2 + _dy, _uv[2], _uv[1], _grey, _al);
            draw_vertex_texture_colour(_sx4, _sy4 + _dy, _uv[0], _uv[3], _grey, _al);
            draw_vertex_texture_colour(_sx3, _sy3 + _dy, _uv[2], _uv[3], _grey, _al);
            draw_primitive_end();
        }
    }
    shader_reset();
}

/// Additive warm sheen where a light hits a character -- quadratic in proximity, so it
/// only really shines up close. The copy is offset a touch TOWARD the light, so the
/// bright spill sits on the lit side of every part.
function anim_light_sheen(_parts, _gx, _gy) {
    var _lights = global.demo_lights;
    var _nl = array_length(_lights);
    for (var l = 0; l < _nl; l++) {
        var _L = _lights[l];
        var _dgx = _gx - _L.x;
        var _dgy = (_gy - _L.y) * 2;                 // iso 1:2 metric, as everywhere
        var _gd  = sqrt(_dgx * _dgx + _dgy * _dgy);
        if (_gd > _L.r || _gd < 1) continue;
        var _t = 1 - _gd / _L.r;
        // Cubic, and gentle: additive warm over already-saturated art blows out fast (an
        // orange horse turned lava at the first attempt). This is a kiss of light for
        // characters practically touching the lamp, not a paint job.
        var _a = 0.16 * _t * _t * _t;
        if (_a < 0.02) continue;
        var _ox = -_dgx / _gd * 1.5;
        var _oy = -_dgy * 0.5 / _gd * 1.5;
        gpu_set_blendmode(bm_add);
        var _count = array_length(_parts);
        for (var i = 0; i < _count; i += PART.SIZE) {
            if (_parts[i + PART.DEPTH] >= 900000) continue;      // not the contact blob
            var _spr = _parts[i + PART.SPR];
            if (_spr == undefined || !sprite_exists(_spr)) continue;
            draw_sprite_ext(_spr, _parts[i + PART.SUB],
                _parts[i + PART.X] + _ox, _parts[i + PART.Y] + _oy,
                _parts[i + PART.XS], _parts[i + PART.YS], _parts[i + PART.ANG],
                make_colour_rgb(226, 208, 168), _a * _parts[i + PART.ALPHA]);
        }
        gpu_set_blendmode(bm_normal);
    }
}

/// Stamp one character's cast shadows into the ACTIVE shadow surface, one silhouette per
/// in-range light. The caller (the controller's shadow layer) owns the surface and the
/// composite; this draws opaque grey silhouettes into it, brightness = the light's fade.
///
/// The fog trick forces every drawn pixel to one flat colour while sprite alphas keep
/// working -- that, plus the parts being opaque on the surface, is what makes the shadow
/// UNIFORM: overlapping parts (hair over torso over arm) all write the same grey instead
/// of stacking translucent layers into blotches.
/// How much of the ambient contact blob a character keeps: 1 in darkness, fading to 0 as
/// the strongest light's attenuation rises. Where a light reaches, the cast shadow does
/// the grounding, and the blob's oval sitting beside it read as two competing shadows --
/// but a hard cutoff at the radius would pop, since the cast shadow is invisibly faint
/// exactly at the edge. So the blob hands over smoothly.
function anim_blob_scale(_x, _y) {
    var _ls = global.demo_lights;
    var _best = 0;
    for (var i = 0; i < array_length(_ls); i++) {
        var _L = _ls[i];
        var _dgx = _x - _L.x, _dgy = (_y - _L.y) * 2;
        var _gd = sqrt(_dgx * _dgx + _dgy * _dgy);
        if (_gd < _L.r) _best = max(_best, 1 - _gd / _L.r);
    }
    return 1 - _best;
}

/// Stamp one character's silhouette for ONE light into that light's active surface.
/// Shadows are kept per light so a pool can fade OTHER lights' shadows crossing it
/// without erasing its own -- a character standing inside a pool blocks that pool's
/// light, and its shadow there must stay strong (a shared surface made it float
/// detached, the near half eaten by its own caster's fade).
function anim_shadow_char(_L, _rig, _clip, _play, _x, _y, _dir, _look, _is_player) {
    var _s = anim_light_shadow(_L, _x, _y);
    if (_s == undefined) return;
    var _p = anim_build(anim_scratch(), _rig, _clip, _play, _x, _y, _dir, _look, _is_player);
    anim_shadow_paint(_p, _s);
}

/// The mount-and-rider version: both shear against the mount's ground anchor and light,
/// so the pair stamps as one silhouette.
function anim_shadow_pair(_L, _h) {
    var _s = anim_light_shadow(_L, _h.x, _h.y);
    if (_s == undefined) return;
    var _p = anim_scratch();
    if (_h.rider != noone) {
        var _r = _h.rider;
        anim_build(_p, _r.rig, _r.clip, _r.play, _r.x, _r.y, _r.direction, _r.look, true,
                   anim_mount_state(_h.rig, _h.direction));
    }
    anim_build(_p, _h.rig, _h.clip, _h.play, _h.x, _h.y, _h.direction, _h.look, false);
    anim_shadow_paint(_p, _s);
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

/// Draw one character on its own, plus the warm sheen of any light close to it. Its cast
/// shadows are NOT drawn here: the controller's shadow layer stamps every character's
/// silhouettes into one surface before any character draws (see anim_shadow_char), so
/// shadows sit under everyone and stay uniform.
function anim_draw(_rig, _clip, _play, _x, _y, _dir, _look, _is_player) {
    var _p = anim_build(anim_scratch(), _rig, _clip, _play, _x, _y, _dir, _look, _is_player);
    anim_paint(_p);
    anim_light_sheen(_p, _x, _y);
}
