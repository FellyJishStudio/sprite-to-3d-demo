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
function anim_paint(_parts, _shadow_source = false) {
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
        if (_shadow_source && _parts[_o + PART.DEPTH] >= 900000) continue;
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
    if (!_shadow_source && variable_global_exists("anim_debug_depth") && global.anim_debug_depth) {
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

/// The ray frame for one caster under one light. Isometric ground distances use twice the
/// screen-y delta; converting a ground vector back to screen space halves y.
///
/// This returns the LIGHT-RELATIVE ray, not a finished transform, because the shadow is
/// no longer one sheared card: anim_shadow_paint casts each column of the silhouette
/// along its own ray out of the light, so it needs the frame rather than a single
/// direction. `s` stays the art-directed length law the game has always used -- a shadow
/// is `s` times the caster's height, capped at 1.6 -- because a true perspective length
/// would send the rider's head (h ~ 85, above a lamp at h 60) off to infinity.
function anim_light_shadow(_L, _gx, _gy) {
    var _dgx = _gx - _L.x;
    var _dgy = (_gy - _L.y) * 2;                     // screen y -> iso ground y
    var _gd  = sqrt(_dgx * _dgx + _dgy * _dgy);
    // Reach and falloff go by the TRUE distance to the lamp, through the air rather than
    // across the floor, so raising it pulls its circle in and thins what is left. Ground
    // distance still guards the divide below -- that one is about the ray, not the range.
    var _d3  = sqrt(_gd * _gd + _L.h * _L.h);
    if (_d3 > _L.r || _gd < 1) return undefined;
    return {
        dx   : _dgx,             // caster relative to the light, in ground units
        dy2  : _dgy,
        gd   : _gd,
        ux   : _dgx / _gd,       // unit ray, ground units
        uy   : _dgy / _gd,
        // Height is the whole of shadow length: the lower the lamp, the further a given
        // caster throws. Capped, or a lamp near the floor would ask for an endless one.
        s    : min(_gd / _L.h, 1.6),
        // Brightness stamped into the shadow surface: full at the light, 0 at its edge.
        a255 : round(255 * (1 - _d3 / _L.r))
    };
}

/// The ground line a rig's cast shadow shears about, as {t, c}: the ground under card
/// column u sits at screen-y offset c + t*u from the stable origin row. A rig with no iso
/// tilt (or no groundX) gets {0, 0} -- the level baseline through the origin, which the
/// baked idle data puts within ~2px of every humanoid foot and every untilted hoof.
///
/// The horse is why this exists: its iso `front` list includes all four front-leg bones,
/// so the front hooves are DRAWN shifted by the full tilt as the horse turns -- a depth
/// cue, not elevation. They stand on a different screen row than the back hooves at most
/// facings, and a level baseline reads that row difference as height and casts it along
/// the light ray: the front-leg shadows detach by tilt times cast length. Tilting the
/// line through both hoof rows pins both pairs, and it is still one linear map.
///
/// The two rows are also held a minimum distance apart. Near broadside the tilt vanishes
/// and they coincide, which flattens the baseline and leaves the cast nothing to open a
/// wedge with -- the shadow thins to a streak. The horse's feet are genuinely that far
/// apart on the floor; the drawing just has no room left to say so at that facing, so the
/// baseline says it instead. The slope is clamped rather than faded out, because fading
/// was what discarded the separation exactly where it mattered most.
///
/// Scratch struct, same contract as anim_facing: valid until the next call, consumed by
/// anim_shadow_paint before another character builds.

/// Ceiling on the baseline's slope, for when the two hoof columns stack face-on and the
/// run under that separation goes to zero.
#macro ANIM_SHADOW_MAX_SLOPE 0.4
/// Smallest angle, as a determinant, allowed between the baseline and the cast direction.
/// At zero the card folds onto a line and the shadow vanishes; this is the floor under
/// its width when the caster points straight at the lamp. Roughly: width in pixels is
/// about 46 times this. See anim_shadow_paint.
/// This is the STARTING value only. anim_boot copies it into
/// `global.anim_shadow_min_fold`, which is what the renderer actually reads, so it can be
/// tuned live -- [ and ] in the demo, with the current value on the HUD.
/// Zero: the fold-based width floor is off by default. It bought width by LEANING the
/// baseline, which has to choose a side, and every choice of side flipped somewhere -- at
/// broadside, or at the lamp's own row as a caster ran past it. ANIM_SHADOW_EDGE holds the
/// width now, symmetrically, with no side to choose. The dial is left wired up (O and P) so
/// the old behaviour can still be dialled back in and looked at.
#macro ANIM_SHADOW_MIN_FOLD 0

/// How far apart the two measured shadow edges are held, ACROSS the ray, in pixels. This is
/// the number that actually sets the shadow's width, and the one the F3 overlay draws as the
/// gap between the red dots. K and L move it live.
#macro ANIM_SHADOW_EDGE 8

/// How strongly other lamps' illumination washes a shadow out, per pixel (see the wash pass
/// in obj_demo_controller/Draw_0). Zero is the old behaviour -- every shadow at full local
/// strength regardless of other light. One erases a shadow completely wherever another lamp
/// shines as brightly as its own; physically about half the darkness should survive where
/// two equal pools overlap, so it sits below that.
#macro ANIM_SHADOW_WASH 0.7

/// The minimum width, in pixels, that any shadow may come out at -- what the ring in
/// anim_shadow_paint holds a collapsing cast to. The ring only ever makes up the SHORTFALL
/// below this, so a cast already at least this wide is drawn to the pixel as it always was:
/// the floor exists only where the collapse does. Five is "a hairline becomes a slim
/// readable band". M and N move it live; zero switches the floor off.
#macro ANIM_SHADOW_THIN 5
/// Floor under the shadow's horizontal scale. At zero the sprite squashes to a line and
/// then comes out MIRRORED, columns in reverse order; this keeps a quarter of the width
/// no matter how far the lean is pushed. It bounds the O/P dial rather than the dial
/// bounding itself, so no setting can invert the shadow. See anim_shadow_paint.
#macro ANIM_SHADOW_MIN_XSCALE 0.25

/// The most the width guard may lean the baseline away from where the rig drew it, as a
/// slope. It is a bound on the guard's PAYMENT, not on the baseline: the natural slope is
/// bounded separately by ANIM_SHADOW_MAX_SLOPE and never comes near this.
///
/// It exists because leaning buys width at a rate of `ux`, so unbounded demands cost
/// unbounded slope as the lamp comes into line with the caster -- and `ux` sweeps through
/// there twice a lap when something runs a circle round a lamp. See anim_shadow_lean.
///
/// SIZED FROM THE WIDTH, not picked to be safe. The allowance goes as `ux*ux`, so the full
/// floor is affordable while `MAX_LEAN * ux*ux` covers the gap the guard has to close --
/// which needs about 1.2 at the broadside angles where that gap is widest. At 0.6 it was
/// under half of that, and the floor silently collapsed to a third of the dial's setting
/// across ordinary lamp angles: 45% of the sweep came out under four fifths of the width
/// asked for, which is the shadow going thin again. Doubling the margin on 1.2 costs
/// nothing anywhere the guard is not already engaged.
///
/// Toward `ux = 0` no finite value delivers the whole floor, but nothing is needed there:
/// with the cast near vertical the natural fold is already about 0.48 against a 0.52 dial,
/// so the shortfall is a few percent of width rather than a collapse.
#macro ANIM_SHADOW_MAX_LEAN 2.5

/// How far the shadow may move between one facing and the next half-degree, in pixels, at
/// the caster's own drawn height. Anything sharper than this is a step rather than a turn.
///
/// Where the number comes from: with the bar lifted and the whole grid measured, the worst
/// anywhere at the shipped 0.52 setting is 5.05px, and it is at a lamp 35px away -- closer
/// to the horse than the horse is long. Everything further out is far below it. Six leaves
/// that corner a little room without admitting a new artifact; the three artifacts this
/// sweep has caught so far measured 63.5, 33.6 and 6.0px, all of them well clear of it.
///
/// The bar is only half the check. global.anim_shadow_worst carries the largest movement
/// and the narrowest width actually seen and both are printed on every run, pass or fail,
/// so drift toward the bar is visible instead of silent.
#macro ANIM_SHADOW_MAX_JUMP 6

/// The cast card. 256 square, with 240px above the stable origin and 16px below it, walked
/// in 16 stations. Macros because the renderer and the regression tests must walk the SAME
/// card: a test that samples a different span measures a different projection.
#macro ANIM_SHADOW_CARD     256
#macro ANIM_SHADOW_CARD_LX  128
#macro ANIM_SHADOW_CARD_LY  240
#macro ANIM_SHADOW_STATIONS 16

/// How tall the drawn caster stands above its own ground row -- a mounted rider, with room
/// to spare. The strip runs out to the card's edge because that is where the texture's top
/// row is, but everything above this is transparent, so this is the height the guards and
/// the sweep judge at. Judging at the card edge instead scales every wobble by more than
/// four and condemns movement nothing can see.
#macro ANIM_SHADOW_TALL     72

/// And how far to either side of its origin the drawn caster reaches. The horse is about
/// 46px nose to tail, a rider adds height rather than width; this has room to spare.
///
/// The card is 256 wide because the SHADOW stretches, not because the caster does, so most
/// of it is transparent. Judging the guards across the whole width is not merely wasteful,
/// it is wrong: with the lamp closer than half a card the outer columns sit on the FAR SIDE
/// of it, their direction away from it reverses, and the strip really does fold out there.
/// Throttling the wedge to keep empty space in order cost 63px of shadow jumping about on a
/// caster passing close to a lamp -- and the fold it was avoiding is invisible, since those
/// columns have no pixels in them.
#macro ANIM_SHADOW_WIDE     48

/// The caster's body depth: how wide its ground footprint stays when it is stood exactly
/// end-on to the lamp and the flat card has nothing left to show. A horse is about twelve
/// pixels through the shoulders. Only ever an addend to the caster's own projected extent,
/// so it sets where the O/P dial starts having to do work rather than a width by itself.
#macro ANIM_SHADOW_BODY     12

/// How far above its own ground row to read a caster's outline when laying the footprint
/// band. Low enough to still be the body rather than the head, high enough to clear the
/// legs -- a horse's barrel sits about here, and a rider's torso above that.
#macro ANIM_SHADOW_BELLY    22

function anim_shadow_ground(_rig, _dir, _is_player) {
    // ub/uf are the back and front hoof columns -- the two card-x the shadow's width is
    // actually measured between. Carried out so the debug overlay marks the SAME points the
    // projection uses rather than a second guess at them.
    static _g = { t: 0, c: 0, w: 1, d: 0, px: 0, py: 0, ub: 0, uf: 0, dir: 0 };
    _g.t = 0;
    _g.c = 0;
    var _iso = _rig.iso;
    if (_iso == undefined) return _g;
    var _gx = _iso[$ "groundX"];
    if (_gx == undefined) return _g;
    var _f = anim_facing(_rig, _dir, _is_player);
    // The tilt anim_build applies -- but deliberately NOT its pixel rounding.
    //
    // anim_build also steps the back legs a pixel, and snaps a sub-pixel tilt to zero, as
    // the caster crosses from facing-away to facing-toward. On the drawn horse that is one
    // pixel of quantisation and nobody sees it. Fed into this baseline it is a step in the
    // SLOPE, and the projection multiplies slope by the caster's height and again by the
    // cast length: a pixel of rounding came back out as 4.2px of shadow snapping sideways
    // at that single facing, which is the flicker anim_shadow_flicker_test measures. Both
    // amplitudes are still honoured, and they meet where the step used to be because the
    // tilt itself is zero there -- so this tracks the drawn hooves within a pixel and,
    // unlike them, does it continuously.
    var _iso_y = (_f.down ? _iso.ampDown : _iso.ampUp) * dsin(_f.skew);
    var _ub = _gx[0] * _f.dcos, _uf = _gx[1] * _f.dcos;
    var _vb = 0;                     // back legs are iso cls 0: no tilt
    var _vf = -_iso_y;               // front legs are iso cls 2: full tilt

    // The two hoof rows are used exactly as the rig drew them -- NO minimum separation.
    //
    // Forcing them a few pixels apart was once what kept the shadow from thinning to a
    // streak, and it flickered. The tilt genuinely reverses as the caster turns through
    // broadside, so the natural separation passes through zero there; forcing a minimum
    // while keeping its sign turned an honest one-pixel change into a snap between plus
    // and minus the minimum. That is the flicker around 90 degrees, and it is measured by
    // anim_shadow_flicker_test. The fold guard in anim_shadow_paint holds the width now,
    // and it takes its direction from the LAMP, which does not reverse when a caster turns.
    var _sep = _vf - _vb;

    // Slope of the baseline through the two hoof columns, faded out as those columns
    // stack up face-on.
    //
    // The fade is not optional and removing it is a trap I already fell into. Face-on the
    // run between the columns passes through zero AND changes sign -- the front feet swing
    // from one side of the back feet to the other -- so an unfaded slope both blows up and
    // flips, snapping the shadow across the ground as the caster turns through that
    // facing. The drawn horse shows nothing of it because it is foreshortened to a sliver
    // there, but the shadow is not, so it pops.
    //
    // Fading costs nothing now: it used to be the only thing holding the shadow open, but
    // the fold guard in anim_shadow_paint keeps the width instead, and that guard works
    // off the LIGHT's geometry rather than this run, so it has nothing to divide by zero.
    var _du = _uf - _ub;
    var _t  = 0;
    if (abs(_du) >= 1) {
        var _fade = min(1, abs(_du) / 12);
        _t = clamp(_sep / _du, -ANIM_SHADOW_MAX_SLOPE, ANIM_SHADOW_MAX_SLOPE) * _fade * _fade;
    }
    _g.t = _t;
    _g.c = (_vb + _vf) * 0.5 - _g.t * (_ub + _uf) * 0.5;

    // WIDTH, which is now an honest scale on the ground footprint rather than a lean.
    //
    // With card-x laid on the ground perpendicular to the ray the shadow's width IS the
    // caster's own extent across that ray, so it is already right where the caster is
    // broadside. End-on it is only the body's depth, and a flat card has no depth to give
    // -- that is the one number the rig genuinely does not carry, and the one the O/P dial
    // is for. Scaling the perpendicular up to the dial's width fills it in.
    //
    // Note what this is NOT: it does not pick a side, it cannot reach zero, and it does
    // nothing at all once the caster's own extent is wider than the dial asks for. So it
    // widens the thin case without popping, which is exactly what a lean could never do.
    // THE OTHER AXIS OF THE SAME FLOOR. The band gives the footprint its depth into the
    // screen; this gives it its width ACROSS the screen, and a caster needs both.
    //
    // The card's own width is the caster's projected length, which is fine broadside and
    // collapses to the body alone end-on: about 12px for a horse at 90 or 270. A vertical
    // band under a 12px card is a 12px shadow however deep it is, which is why 90 and 120
    // stayed thin after the band went in. Stretching the silhouette out to the dial's width
    // fills it, does nothing at all once the caster is already wider than that, and cannot
    // reach zero -- so the minimum holds in every direction without anything to flip.
    var _len = abs(_uf - _ub) + ANIM_SHADOW_BODY;
    _g.w = max(1, (global.anim_shadow_min_fold * 46) / max(1, _len));
    _g.dir = _dir;
    _g.ub = _ub;
    _g.uf = _uf;

    // THE BODY'S DEPTH, which the card does not have and never could.
    //
    // The card is one flat cutout of the caster as drawn, so it carries length and height
    // and nothing across. Side-on to the lamp there is genuinely nothing left to cast and
    // the shadow goes to a streak -- and every attempt to fake width by LEANING the
    // baseline failed the same way, because a lean has to choose a side and any choice of
    // side flips somewhere: at broadside, or at the lamp's own row, or (rotating the axis
    // to dodge the choice) by reversing the sprite outright.
    //
    // Depth has no side. It straddles the body axis, so it is symmetric by construction:
    // there is nothing to choose and so nothing to flip. `d` is that depth in ground units
    // and (px, py) is the direction it runs -- perpendicular to the body on the ground,
    // taken from the caster's OWN facing and never from the lamp, which is what makes it
    // immune to everything the lamp does. anim_shadow_paint lays a band of it under the
    // feet; see the second strip there.
    // Plus whatever K/L have dialled in on top, straight in pixels. The dial above is a
    // fold that has to be multiplied out to mean anything; this one is the number actually
    // being judged -- how far apart the two edges are held across the ray -- so it is the
    // one worth being able to push while looking at the overlay that draws it.
    _g.d  = global.anim_shadow_min_fold * 46
          + (variable_global_exists("anim_shadow_edge") ? global.anim_shadow_edge : 0);

    // STRAIGHT DOWN THE SCREEN, at every facing, and NOT along the body's perpendicular.
    //
    // The card is one flat cutout, so what it captures is the caster's extent in screen X
    // and what it is missing is always the same thing: the extent INTO the screen. That is
    // true whichever way the caster is pointed, so the band that stands in for it always
    // spreads the same way -- vertically.
    //
    // Rotating it with the body instead looks right and is wrong at half the facings. At 0
    // the body's ground perpendicular is into the screen, so it worked; at 90 the caster
    // points into the screen and that perpendicular comes out HORIZONTAL, which is the one
    // direction the card already covers -- so the band widened a shadow that was already
    // wide and left 90 and 120 as thin as before. The missing dimension does not rotate,
    // because the thing doing the missing is the flatness of the card, not the pose.
    _g.px = 0;
    _g.py = 1;
    return _g;
}

/// Startup regression sweep for the shadow projection. It samples a dense 2:1 isometric
/// orbit at a quarter of a degree, and every check here exists because the matching
/// artifact was seen on screen and reported. Each one names its symptom:
///
///   ray        the frame must match the light geometry and the length law.
///   ECHO       the sprite's own axis must map to screen x, unscaled and unmirrored, at
///              every light angle. This is the shadow LOOKING LIKE the horse and turning
///              with it. Rotate this axis with the ray instead -- as one revision did --
///              and the shadow shows the horse from the lamp's side, which reads as the
///              shadow not turning with the horse.
///   THICKNESS  the flank smear must stay fixed and in the CASTER's frame, independent of
///              where the light is. Sizing it against the ray instead asked for up to 48
///              units and dissolved the horse into a SLAB.
///   DASH       the silhouette's extent across the ray must never collapse. The flank is
///              what prevents it: a flat card has no thickness down its own axis, so with
///              the ray along the body there would otherwise be nothing to cast.
///   wedge      the strip's two edges must DIVERGE with distance rather than run parallel,
///              and everything must move continuously -- a jump is the mirror FLIP.
///
/// The algebra mirrors anim_shadow_paint and must stay in sync with it; see
/// docs/shadow-test-plan.md. Empty string means every invariant passed.
function anim_shadow_regression_test() {
    var _L = { x: 0, y: 0, h: 60, r: 400 };
    var _radius = 170;
    var _lx = 128, _ly = 240;
    var _last_ux = 0, _last_uy = 0;
    var _last_e0x = 0, _last_e0y = 0, _last_e1x = 0, _last_e1y = 0;
    // A caster heading, held fixed while the light goes round.
    var _dir = 35;

    for (var _i = 0; _i <= 1440; _i++) {
        var _ang = _i * 0.25;
        var _gx = _radius * dcos(_ang);
        var _gy = -_radius * 0.5 * dsin(_ang);
        var _s = anim_light_shadow(_L, _gx, _gy);
        if (_s == undefined) return "missing transform at " + string(_ang);

        var _dgx = _gx - _L.x, _dgy = (_gy - _L.y) * 2;
        var _gd = sqrt(_dgx * _dgx + _dgy * _dgy);
        if (abs(_s.ux - _dgx / _gd) > 0.0001 || abs(_s.uy - _dgy / _gd) > 0.0001
         || abs(_s.s - min(_gd / _L.h, 1.6)) > 0.0001) {
            return "cast ray mismatch at " + string(_ang);
        }

        // ECHO: run two card columns through the SAME root expression anim_shadow_paint
        // uses, and they must come out that same distance apart, in that same order,
        // whatever the light is doing. Written through the mapping on purpose: swap the
        // root back to the ray-perpendicular form a previous revision used and this goes
        // straight to |40 * nx|, which fails everywhere except due north and south.
        var _rxL = _gx + (-20);
        var _rxR = _gx + ( 20);
        if (abs((_rxR - _rxL) - 40) > 0.0001) {
            return "sprite echo broken at " + string(_ang);
        }

        // No width floor is asserted here, and that is deliberate. The shadow is ONE stamp
        // of the drawn palette, so with the lamp nearly in line with the caster's own axis
        // there is genuinely nothing side-on to cast and it goes thin. Every device that
        // propped the width up there cost more than it bought -- a signed floor popped, a
        // stamp fan banded, a lying card double-exposed, a sideways smear dithered the
        // palette into a slab AND pulled its near edge off the feet. Thin is the honest
        // answer at that one band, and it stays.
        var _nx = -_s.uy, _ny = _s.ux;
        var _skewd = point_direction(0, 0, dcos(_dir) * 0.2, -dsin(_dir) * 0.6);
        var _cardw = 46 * abs(dcos(_skewd)) + 12;

        // The strip's edges must spread apart with distance.
        var _e0x = 0, _e0y = 0, _e1x = 0, _e1y = 0, _rootSep = 0;
        for (var _e = 0; _e < 2; _e++) {
            var _u = (_e == 0) ? -_cardw * 0.5 : _cardw * 0.5;
            var _rgx = _dgx + _u, _rgy = _dgy;
            var _rl = max(1, sqrt(_rgx * _rgx + _rgy * _rgy));
            var _rx = _gx + _u, _ry = _gy;
            var _hh = 60;
            var _tx = _rx + _hh * (_rgx / _rl) * _s.s;
            var _ty = _ry + _hh * (_rgy / _rl) * 0.5 * _s.s;
            if (_e == 0) { _e0x = _tx; _e0y = _ty; _rootSep = -(_rx * _nx + _ry * 2 * _ny); }
            else         { _e1x = _tx; _e1y = _ty; _rootSep += (_rx * _nx + _ry * 2 * _ny); }
        }
        var _tipSep = abs((_e1x - _e0x) * _nx + (_e1y - _e0y) * 2 * _ny);
        if (_tipSep < _rootSep - 0.001) return "wedge fails to diverge at " + string(_ang);
        if (_i > 0) {
            var _jump = max(max(abs(_e0x - _last_e0x), abs(_e0y - _last_e0y)),
                            max(abs(_e1x - _last_e1x), abs(_e1y - _last_e1y)));
            if (_jump > 8) return "wedge edge discontinuity at " + string(_ang);
        }
        _last_e0x = _e0x; _last_e0y = _e0y;
        _last_e1x = _e1x; _last_e1y = _e1y;

        if (_i > 0 && max(abs(_s.ux - _last_ux), abs(_s.uy - _last_uy)) > 0.03) {
            return "ray discontinuity at " + string(_ang);
        }
        _last_ux = _s.ux;
        _last_uy = _s.uy;
    }
    return "";
}

/// ONE station of the cast strip, as offsets from the caster's anchor.
///
/// The single place the projection is written down. The renderer, the width guard and the
/// regression sweep all go through here, so a test cannot come back green against geometry
/// the screen does not draw -- which is exactly how a mirrored shadow survived a passing
/// suite: the sweep modelled one cast direction for the whole card while the renderer gave
/// every column its own.
///
/// `_div` is how far each column leans onto its OWN ray out of the lamp: 1 is the full
/// wedge, 0 a parallel cast. See anim_shadow_spread for why it is not always 1.
/// `_h` is how far up the column to evaluate, above the card's own ground row. It defaults
/// to the card's top edge, which is what the strip is drawn to; the guards pass
/// ANIM_SHADOW_TALL instead so they judge the part that has pixels in it.
function anim_shadow_station(_s, _g, _tt, _u, _div, _ly, _h = undefined) {
    // SCRATCH, not a fresh struct, and valid only until the next call -- read what you need
    // before making another. The renderer walks this hundreds of times per caster per light
    // per frame and the startup sweep tens of millions of times; returning a new struct put
    // about thirty seconds in front of the title screen and left a constant allocation
    // churn in play. Same contract as anim_facing and anim_shadow_ground.
    static _p = { rx: 0, ry: 0, tx: 0, ty: 0, hT: 0 };
    var _vg  = _g.c + _tt * _u;                 // the card's own ground row under this column

    // CARD-X LIES ALONG THE GROUND PERPENDICULAR TO THE RAY. Not along screen x.
    //
    // This one line is what every width guard in this file's history was patching around.
    // The card is the caster posed from the LAMP (anim_shadow_dir), so its horizontal axis
    // is the caster's extent across the light ray -- and on the ground that direction is
    // (-uy, ux), which is where it has to be laid down. Laying it along screen x instead
    // put it near enough ALONG the ray whenever the lamp was off to the side, so the card's
    // width and the shadow's length ran the same way and the silhouette collapsed onto a
    // line. `fold` was exactly the mismatch between those two directions, and the minimum
    // fold, the taper, the lean side and the divergence search were all propping it up.
    //
    // With the axis where it belongs the two spanning directions are perpendicular in
    // ground terms by construction, so their determinant is a flat -s/2 whatever the caster
    // or the lamp does: NEVER zero, never changing sign. The shadow cannot fold flat and
    // cannot come out mirrored, so there is nothing left for a floor to defend and no sign
    // for it to pick -- which is what dissolves the width-versus-popping trade entirely.
    // It is also why a caster standing at 0 or 180 goes wrong today: side-lit, the card is
    // the horse seen end-on, so card-x is its body DEPTH, and depth laid along screen x
    // vanishes into the shadow's own length instead of giving it any.
    // CARD-X MAPS STRAIGHT TO SCREEN X, and it has to.
    //
    // The card is the caster posed from the CAMERA (see anim_shadow_cast: "the DRAWN
    // facing"), so its horizontal axis is the caster as you see it and the nose has to stay
    // on the side the nose is drawn. Laying it along the ground perpendicular to the ray,
    // (-uy, ux), is right only for a card posed from the LAMP -- and that factor -uy is
    // NEGATIVE for every lamp on one side, which reverses card-x and draws the shadow
    // mirrored across half of all lamp positions. Worse, a test that measures the strip
    // along that same perpendicular is monotone by construction and cannot see the flip,
    // which is how it passed at 2.26px while the screen showed a mirrored horse.
    //
    // The depth the card lacks is real, and `w` still supplies it -- but as a widening of
    // this axis, never as a rotation of it.
    var _w  = _g[$ "w"] ?? 1;
    var _nx = _w, _ny = 0;

    // The column's own ray, from the lamp past where that column actually stands.
    var _rgx = _s.dx  + (_u * _nx) * _div;
    var _rgy = _s.dy2 + 2 * _vg * _div;
    var _rl  = max(1, sqrt(_rgx * _rgx + _rgy * _rgy));
    var _dxs = (_rgx / _rl) * _s.s;
    var _dys = (_rgy / _rl) * 0.5 * _s.s;
    var _hT  = _vg + _ly;                       // height of the card's top edge here
    var _he  = (_h == undefined) ? _hT : _h;
    _p.rx = _u * _nx;           _p.ry = _u * _ny + _vg;   // root, welded to the drawn feet
    _p.tx = _p.rx + _he * _dxs; _p.ty = _p.ry + _he * _dys;
    _p.hT = _hT;
    return _p;
}

/// True when the strip runs one way across the screen instead of folding back through
/// itself. Only the tip row can turn over -- the root row is the card's own x, untouched.
///
/// The bar is a MARGIN, not merely "forwards". A strip that only just advances is one that
/// has squashed to a sliver, and a sliver is what reads as the flicker at the facings
/// either side of a mirror.
function anim_shadow_forward(_s, _g, _tt, _div, _ly) {
    return anim_shadow_xscale(_s, _g, _tt, _div, _ly) >= ANIM_SHADOW_MIN_XSCALE;
}

/// How much per-column divergence this cast can carry before it turns itself inside out.
///
/// Each column casting along its own ray is what opens the wedge -- the two lines running
/// from the lamp past either side of the caster. But the ray direction SWINGS across the
/// card, and a column's tip rides that swing multiplied by its own height, so with the lamp
/// close the far columns can overtake the near ones: the strip folds back through itself
/// and the shadow comes out MIRRORED.
///
/// The width guard cannot see this. It holds `1 + tt*ux*s` above a floor, which is the
/// derivative of a PARALLEL cast; the divergence term is not in it at any setting. So
/// measure the real strip instead and back the divergence off until every station moves
/// forwards. Zero is the parallel cast the guard does cover and is always safe, so the
/// search always lands somewhere -- and it only costs anything on the frames that need it,
/// since full divergence is the right answer nearly everywhere.
function anim_shadow_spread(_s, _g, _tt, _ly) {
    if (anim_shadow_forward(_s, _g, _tt, 1, _ly)) return 1;
    var _lo = 0, _hi = 1;
    // Deep enough that the ANSWER, not the search, is what moves between one facing and the
    // next: the result multiplies a card half-width of 128 against a lamp that may be only
    // tens of pixels away, so a coarse search quantises the tip into visible steps. Twelve
    // halvings puts that quantisation a long way under a pixel. It is not free -- this runs
    // per caster per light on every frame that folds, and the startup sweep runs it tens of
    // thousands of times -- so it is not set higher for luck.
    repeat (12) {
        var _mid = (_lo + _hi) * 0.5;
        if (anim_shadow_forward(_s, _g, _tt, _mid, _ly)) _lo = _mid; else _hi = _mid;
    }
    return _lo;
}

/// The baseline lean this cast is drawn with: the natural one, widened to the minimum fold
/// and then floored so the parallel term cannot invert. Shared by the renderer and the
/// sweep for the same reason anim_shadow_station is.
/// The baseline lean the cast is drawn with -- now simply the tilt the rig drew, because
/// there is nothing left for a guard to do.
///
/// Everything that used to live here existed to stop the card folding flat, and the card
/// cannot fold flat once its own axis is laid on the ground perpendicular to the ray: the
/// determinant is a constant -s/2 (see anim_shadow_station). What is left is the rig's own
/// hoof-row tilt, which is what pins the shadow to the feet, and it is used as drawn.
///
/// Deleted with the guard, and worth naming so they are not reinvented: a minimum fold, a
/// tapered floor, a lean side taken from the lamp, a bounded lean allowance, a knee, and a
/// clamp. Each fixed the artifact the one before it caused, and every one of them was
/// propping up a mismatch that no longer exists. `_minfold` stays in the signature and now
/// scales WIDTH honestly instead -- see anim_shadow_width.
function anim_shadow_lean(_s, _g, _minfold) {
    return _g.t;
}

/// The dead guard, kept only so the old text is findable next to what replaced it.
function anim_shadow_lean_legacy(_s, _g, _minfold) {
    var _tt = _g.t;
    if (abs(_s.ux) <= 0.01) return _tt;

    // `_fold` is the determinant between the baseline the card stands on and the cast
    // running out from the lamp: its size is the shadow's width, its SIGN is the shadow's
    // orientation. Flipping that sign is, exactly, mirroring the caster.
    var _fold = _tt * _s.ux - _s.uy * 0.5;

    // A TAPERED floor, and the taper is not a nicety -- it is forced.
    //
    // No continuous function can hold |fold| at or above a positive minimum while fold
    // changes sign: it would have to be at least m on one side, at most -m on the other,
    // and never pass through the zero in between. So a width floor that never lapses and a
    // shadow that never pops are incompatible, and every earlier revision here traded one
    // for the other. Forcing the sign from `_fold` popped as a caster turned through
    // broadside; forcing it from the LAMP moved the pop to where the caster crosses the
    // lamp's own row -- which reads as fine while a horse turns on the spot and is a
    // disaster the moment it RUNS AROUND the lamp, because it crosses that row twice every
    // lap. That was 63px of shadow flipping over mid-stride, at the shipped setting.
    //
    // Mirroring is the thing worth refusing, so the width gives way instead: full floor
    // once the natural fold reaches a quarter of it, tapering to nothing only at the true
    // degeneracy, where the card really is edge-on to the light and has nothing to cast.
    // The sign is the natural one throughout and changes only where the magnitude is zero,
    // so there is no step to see.
    //
    // And the floor asks for no more width than a BOUNDED lean can buy.
    //
    // Leaning buys width at a rate of `ux`, so the slope it costs is the width wanted
    // divided by `ux` -- and with the lamp nearly in line with the caster in ground terms
    // that divisor approaches zero. A hair of missing width is then paid for with an
    // enormous change of slope, and since `ux` moves as the caster orbits, so does the
    // payment: 63px of lurch at first, 6px after the sign was fixed, all of it from this
    // division rather than from anything about the shadow. Capping the WIDTH by
    // `MAX_LEAN * ux` caps the slope at MAX_LEAN outright, whatever `ux` does.
    //
    // Nothing is given up where it matters. With the cast near vertical the card folds flat
    // only if its baseline lies along it, which needs a slope the baseline never reaches --
    // so the natural fold is already about a half there, wider than the floor would have
    // asked for. Broadside, where the collapse is real, `ux` is near one and the full floor
    // is affordable. This is also what lets the `ux` cutoff above be crossed without a step.
    var _af   = abs(_fold);
    // SQUARED, and that is the point rather than a tuning choice. The lean the guard costs
    // is the extra width over `ux`, so an allowance proportional to `ux` leaves a correction
    // of a fixed size as `ux` shrinks -- and `ux` passes through zero whenever the lamp
    // comes into line with the caster, twice a lap for anything circling it. The numerator
    // keeps its sign across that crossing while the divisor changes sign, so the lean
    // inverts: 33px of shadow flipping over as a lamp swept past a caster standing still.
    // Squared, the correction is bounded by MAX_LEAN * |ux| and so fades to nothing at the
    // crossing, which is also the only value continuous with the cutoff above.
    var _m    = min(_minfold, _af + ANIM_SHADOW_MAX_LEAN * _s.ux * _s.ux);
    // WHERE THE KNEE SITS IS THE WHOLE TRADE, and it is worth being exact about.
    //
    // Below it the width tapers, and the taper is a gain: the lean comes out as `_m/_knee`
    // times the natural one, so it multiplies how fast that lean MOVES by the same factor.
    // Wide knee, smooth shadow, narrow shadow. Narrow knee, full width, sharper movement.
    //
    // At half the floor it was far too wide. A caster standing at facing 0 or 180 has a
    // LEVEL baseline -- the rig draws both hoof rows on one line there -- so its natural
    // fold is just `uy/2`, about 0.14 under a typical lamp. That sat well inside a 0.26
    // knee and came out at 0.29 against a 0.52 dial: the 24px shadow delivered as 13px, at
    // the one facing most likely to be looked at. The taper is meant for the degeneracy,
    // not for the ordinary broadside pose.
    var _knee = _m * 0.15;
    var _mag  = (_knee > 0) ? max(_af, _m * min(1, _af / _knee)) : _af;
    var _want = (_fold >= 0) ? _mag : -_mag;

    // AND the lean cannot turn the sprite inside out. A column at card-x u lands at
    // u + h*ux*s and carries the lean in its own height h, so the parallel cast's
    // horizontal scale is 1 + tt*ux*s -- and tt*ux is `_want + uy/2`, NOT `_want`. Dropping
    // that uy/2 floored the wrong quantity, which let the scale go negative with the lamp
    // well above or below the caster however wide the dial was set. This bound is ONE-SIDED,
    // which is what lets it be both absolute and continuous.
    _want = max(_want, (ANIM_SHADOW_MIN_XSCALE - 1) / _s.s - _s.uy * 0.5);

    // Bounded because `ux` is a divisor and may be as small as the cutoff above allows. The
    // natural slope never approaches this; only the guard can, and only where the lamp is
    // nearly in line with the caster in ground terms.
    return clamp((_want + _s.uy * 0.5) / _s.ux, -3, 3);
}

/// Sweeps a caster turning a full circle under a lamp at every angle around it, finely,
/// and asserts two things at every one of those combinations. Both exist because they were
/// reported from the screen, and neither showed up in a coarser sweep.
///
///   FLICKER  nothing may jump between adjacent facings. A caster's heading eases toward
///            where it is pointed, so it lingers and wobbles; a step in the shadow at the
///            facing it settles near reads as a per-frame flicker, not a one-off snap.
///            Two causes were caught this way: a guard written as "replace it when below
///            the threshold", which disagreed with the natural value AT the threshold, and
///            a forced minimum hoof separation, which snapped between plus and minus
///            itself where the rig's own tilt reverses.
///
///   MIRROR   the sprite's own axis must keep pointing the same way -- two card columns
///            must leave the map in the order they entered it, or the shadow is a mirrored
///            horse.
///
/// The step is deliberately finer than the artifacts are wide. At one degree both bugs
/// above were stepped straight over and the sweep came back clean.
///
/// NOT ON THE BOOT PATH. The full grid is 173,000 samples with a search inside each one and
/// it takes about forty seconds in the VM -- forty seconds of black window before the demo
/// appears, which is how it first showed up: a run that looked hung at "About to startroom".
/// Thoroughness is the point of this sweep, so it keeps its resolution and moves off the
/// launch instead: F2 in the demo runs it, and so does THRONE_TEST=1 in the environment for
/// an automated run. anim_shadow_regression_test still runs at every boot; it is cheap.
/// Debug overlay for the cast: the two ground points the shadow's width is measured
/// between, and the two rays out of the lamp that graze them. The shadow is supposed to be
/// what lies between those rays, so drawing them makes the claim checkable instead of
/// arguable -- if the grey does not fill the wedge, the picture says so immediately.
///
/// Read straight out of the same anim_shadow_ground and anim_shadow_station the renderer
/// uses. That matters: a debug view that recomputes the geometry its own way agrees with
/// whatever it believes rather than with what is on screen, which is how a green sweep sat
/// on top of a mirrored shadow for most of this file's history.
///
/// F3 in the demo. World space, so it must be drawn from a world Draw event.
function anim_shadow_debug(_L, _rig, _dir, _is_player, _x, _y) {
    var _s = anim_light_shadow(_L, _x, _y);
    if (_s == undefined) return;                      // caster out of this lamp's reach
    var _g   = anim_shadow_ground(_rig, _dir, _is_player);
    var _tt  = anim_shadow_lean(_s, _g, global.anim_shadow_min_fold);
    var _div = anim_shadow_spread(_s, _g, _tt, ANIM_SHADOW_CARD_LY);

    // The hoof columns as the rig drew them, put back on the floor through the projection,
    // and then HELD APART across the ray exactly as anim_shadow_paint holds them -- so the
    // dots mark the width the shadow is actually given, not the width the rig happened to
    // measure. Drawn raw they sit almost on top of each other whenever the caster points at
    // the lamp, which is the thing this overlay was added to show.
    var _us = [_g.ub, _g.uf];
    var _ex = [0, 0], _ey = [0, 0];
    for (var i = 0; i < 2; i++) {
        var _p = anim_shadow_station(_s, _g, _tt, _us[i], _div, ANIM_SHADOW_CARD_LY);
        _ex[i] = _x + _p.rx;
        _ey[i] = _y + _p.ry;
    }
    var _pnx = -_s.uy, _pny = _s.ux * 0.5;
    var _pn  = max(0.0001, sqrt(_pnx * _pnx + _pny * _pny));
    _pnx /= _pn;  _pny /= _pn;
    var _sep = abs((_ex[1] - _ex[0]) * _pnx + (_ey[1] - _ey[0]) * _pny);
    var _dd  = max(0, _g.d - _sep) * 0.5;
    _ex[0] -= _dd * _pnx;  _ey[0] -= _dd * _pny;
    _ex[1] += _dd * _pnx;  _ey[1] += _dd * _pny;

    draw_set_colour(c_red);
    draw_set_alpha(1);
    for (var i = 0; i < 2; i++) {
        // The ray from the lamp, through the edge, run well past the caster so the wedge it
        // bounds is visible rather than implied.
        var _dx = _ex[i] - _L.x, _dy = _ey[i] - _L.y;
        var _l  = max(1, sqrt(_dx * _dx + _dy * _dy));
        draw_line(_L.x, _L.y, _L.x + (_dx / _l) * 700, _L.y + (_dy / _l) * 700);
    }
    for (var i = 0; i < 2; i++) {
        draw_circle(_ex[i], _ey[i], 3, false);        // filled, so they read over the grey
    }
    draw_set_colour(c_white);
}

/// The narrowest the strip gets anywhere across the card, as a multiple of the spacing it
/// went in with. One is undistorted, below zero is a mirrored caster, and near zero is a
/// caster squashed to a sliver -- which is what the frames either side of a mirror look
/// like. Every sweep measures the mirror through here, walking EVERY station: the two ends
/// alone cannot see a strip that folds in the middle and comes back, and with each column
/// on its own ray it can do exactly that.
/// Measured ALONG THE CARD'S OWN AXIS on the ground, not along screen x. Card-x is laid on
/// the ground perpendicular to the ray (see anim_shadow_station), so with the lamp off to
/// one side the strip advances in screen Y and an x-only test reads every station as
/// standing still -- it would call a perfectly good shadow collapsed. Ground units, so the
/// 2:1 metric does not weight the two axes differently.
function anim_shadow_xscale(_s, _g, _tt, _div, _ly) {
    var _st   = ANIM_SHADOW_STATIONS;
    var _step = (ANIM_SHADOW_WIDE * 2) / _st;
    // Measured in SCREEN X, which is the axis the card is actually laid on and the axis a
    // reversed sprite reverses along. Measuring along the strip's own direction instead --
    // whatever that direction happens to be -- makes this monotone by construction and
    // therefore blind: it passed a build that drew a mirrored horse for every lamp on one
    // side. A mirror test has to be anchored to something the mirror moves against.
    var _pa = 0, _worst = 999999;
    for (var _k = 0; _k <= _st; _k++) {
        var _u = -ANIM_SHADOW_WIDE + _k * _step;
        var _p = anim_shadow_station(_s, _g, _tt, _u, _div, _ly, ANIM_SHADOW_TALL);
        if (_k > 0) _worst = min(_worst, (_p.tx - _pa) / _step);
        _pa = _p.tx;
    }
    return _worst;
}

/// The horse rig's own tilt numbers, as the loader resolves them: ampDown/ampUp and the
/// wide facing band come from horse.rig.json's isoTilt and facingRule, groundX from
/// horse.demo.json. Written out rather than read from global.anim_rigs so the sweeps can
/// run before the async load finishes -- but they are the REAL values, not stand-ins, and
/// anim_shadow_rig_check fails the build if the JSON drifts away from them.
function anim_shadow_test_rig() {
    return { iso : { ampDown: 7, ampUp: 9, groundX: [-5, 26], flat: [] },
             faceBand : [0, 180] };
}

/// Guards the constants above against the data. A sweep that turns a rig nobody ships is
/// worth nothing, and nothing else would notice the day someone retunes the horse's tilt.
function anim_shadow_rig_check() {
    var _rigs = global[$ "anim_rigs"];
    if (!is_struct(_rigs)) return "";                    // called before the load finished
    var _h = _rigs[$ "horse"];
    if (!is_struct(_h) || !is_struct(_h[$ "iso"])) return "";
    var _t = anim_shadow_test_rig();
    if (_h.iso.ampDown != _t.iso.ampDown || _h.iso.ampUp != _t.iso.ampUp) {
        return "horse tilt is now " + string(_h.iso.ampDown) + "/" + string(_h.iso.ampUp)
             + " but the shadow sweeps still turn " + string(_t.iso.ampDown) + "/"
             + string(_t.iso.ampUp) + " -- update anim_shadow_test_rig";
    }
    if (_h.faceBand[0] != _t.faceBand[0] || _h.faceBand[1] != _t.faceBand[1]) {
        return "horse faceBand changed -- update anim_shadow_test_rig";
    }
    var _gx = _h.iso[$ "groundX"];
    if (is_array(_gx) && (_gx[0] != _t.iso.groundX[0] || _gx[1] != _t.iso.groundX[1])) {
        return "horse groundX is now [" + string(_gx[0]) + "," + string(_gx[1])
             + "] but the shadow sweeps still use [" + string(_t.iso.groundX[0]) + ","
             + string(_t.iso.groundX[1]) + "] -- update anim_shadow_test_rig";
    }
    return "";
}

function anim_shadow_flicker_test() {
    // The worst movement and the narrowest width seen anywhere, reported whether the sweep
    // passes or fails. A pass with no numbers attached says only "under the bar", which is
    // how a sweep sitting a hair under it goes unnoticed until it drifts over.
    global.anim_shadow_worst = { jump: 0, where: "", xscale: 999999, xwhere: "",
                                 narrow: 0, total: 0 };
    var _L = { x: 0, y: 0, h: 60, r: 400 };
    var _rig = anim_shadow_test_rig();
    // Sweep the WHOLE range the HUD dial can reach, not just the shipped default, and
    // several lamp distances -- the cast length factor scales with distance and it is what
    // multiplies the lean, so a setting that is safe far away can invert up close. Testing
    // one distance at one setting is how the mirror got through.
    var _folds = [0.1, 0.33, 0.52, 0.8, 1.2];
    // 35 is a lamp practically standing on the caster, which L in the demo drops wherever
    // the cursor is. It is also the only distance here that reaches the divergence fold at
    // all, now the guards judge the caster's own width instead of the whole card -- without
    // it the liveness check below correctly reports this sweep as proving nothing.
    var _dists = [35, 70, 140, 240, 330];
    // The narrowest the shadow gets anywhere in the sweep. Checked at the end: see the note
    // there on why a sweep that never comes near the failure is worthless.
    var _tightest = 999999;

    for (var _fi = 0; _fi < array_length(_folds); _fi++) {
        var _minfold = _folds[_fi];
        for (var _di = 0; _di < array_length(_dists); _di++) {
            var _rad = _dists[_di];
            for (var _la = 0; _la < 360; _la += 30) {
                // Lamp on a 2:1 isometric orbit: ground y is the screen delta doubled.
                var _gx = _rad * dcos(_la), _gy = -_rad * 0.5 * dsin(_la);
                var _s = anim_light_shadow(_L, _gx, _gy);
                if (_s == undefined) continue;

                var _pax = 0, _pay = 0, _pbx = 0, _pby = 0, _have = false;
                for (var _i = 0; _i <= 720; _i++) {
                    var _dir = _i * 0.5;
                    var _g = anim_shadow_ground(_rig, _dir, false);

                    // Through the SAME calls the renderer makes, on the same card, rather
                    // than a second copy of the arithmetic. The copy is what let the mirror
                    // through: it modelled one cast direction for the whole card while the
                    // renderer gave every column its own, so the term that actually turns
                    // the strip over was absent from the thing under test.
                    var _ly = ANIM_SHADOW_CARD_LY;
                    var _tt  = anim_shadow_lean(_s, _g, _minfold);
                    var _div = anim_shadow_spread(_s, _g, _tt, _ly);

                    // WIDTH, which is the other half of the job and the half that has no
                    // hard failure to trip over -- a shadow quietly narrowing is a
                    // regression nobody's assertion catches. Counted as the share of
                    // samples where the guarded fold ends up under four fifths of what the
                    // dial asked for.
                    var _foldg = _tt * _s.ux - _s.uy * 0.5;
                    global.anim_shadow_worst.total++;
                    if (abs(_foldg) < _minfold * 0.8) global.anim_shadow_worst.narrow++;

                    var _worst = anim_shadow_xscale(_s, _g, _tt, _div, _ly);
                    _tightest = min(_tightest, _worst);
                    if (_worst < global.anim_shadow_worst.xscale) {
                        global.anim_shadow_worst.xscale = _worst;
                        global.anim_shadow_worst.xwhere = "fold " + string(_minfold);
                    }
                    if (_worst < ANIM_SHADOW_MIN_XSCALE - 0.02) {
                        return "shadow mirrored/collapsed, x-scale "
                             + string_format(_worst, 1, 2) + " at facing " + string(_dir)
                             + ", lamp " + string(_la) + " dist " + string(_rad)
                             + ", fold " + string(_minfold) + ", spread "
                             + string_format(_div, 1, 2);
                    }

                    // FLICKER: no step between one facing and the next, measured at both
                    // ends of the caster's own footprint.
                    // Copied out, not held: anim_shadow_station hands back one shared
                    // scratch, so `_a` would be `_b` by the time it is read.
                    var _a = anim_shadow_station(_s, _g, _tt, -23, _div, _ly,
                                                 ANIM_SHADOW_TALL);
                    var _ax2 = _a.tx, _ay2 = _a.ty;
                    var _b = anim_shadow_station(_s, _g, _tt,  23, _div, _ly,
                                                 ANIM_SHADOW_TALL);
                    var _bx2 = _b.tx, _by2 = _b.ty;
                    if (_have) {
                        var _jump = max(point_distance(_ax2, _ay2, _pax, _pay),
                                        point_distance(_bx2, _by2, _pbx, _pby));
                        if (_jump > global.anim_shadow_worst.jump) {
                            global.anim_shadow_worst.jump  = _jump;
                            global.anim_shadow_worst.where = "facing " + string(_dir)
                                + ", lamp " + string(_la) + " dist " + string(_rad)
                                + ", fold " + string(_minfold);
                        }
                        if (_jump > ANIM_SHADOW_MAX_JUMP) {
                            return "shadow flickers " + string_format(_jump, 1, 1)
                                 + "px at facing " + string(_dir) + ", lamp " + string(_la)
                                 + " dist " + string(_rad) + ", fold " + string(_minfold);
                        }
                    }
                    _pax = _ax2; _pay = _ay2; _pbx = _bx2; _pby = _by2; _have = true;
                }
            }
        }
    }

    // CAN THIS SWEEP FAIL? Every artifact in this file's history was reported from the
    // screen after a sweep had come back green, so a pass is only worth what the sweep is
    // shown able to catch. If the narrowest shadow anywhere in the grid still sits a long
    // way clear of the floor then the grid never approaches a mirror at all, and passing a
    // mirror check says nothing. Measured on the shadow itself rather than on whether some
    // guard engaged, so that tightening a guard cannot quietly make this vacuous -- which
    // is exactly what happened when the guards moved to judging the caster's own width.
    if (_tightest > ANIM_SHADOW_MIN_XSCALE + 0.5) {
        return "grid never comes near the mirror boundary (narrowest "
             + string_format(_tightest, 1, 2) + ") -- its mirror check proves nothing";
    }
    return anim_shadow_orbit_test();
}

/// A caster RUNNING A FULL CIRCLE AROUND THE LAMP, which is the thing actually reported
/// from the screen and a genuinely different test from the grid above.
///
/// The grid turns a caster on the spot at a handful of fixed lamp placements, so facing and
/// lamp direction are varied INDEPENDENTLY. On an orbit they move together: a running
/// caster faces along its own travel, so its facing stays about ninety degrees off the lamp
/// direction the whole way round, and the pair sweeps continuously through every angle in
/// between. A coarse grid can step straight over what a correlated path lands on -- and
/// which way the two are locked together is precisely what decides whether the lean and the
/// divergence add or cancel, so it is the thing under test, not a detail of the setup.
///
/// The orbit is a circle in GROUND space, which the 2:1 metric makes an ellipse on screen.
/// That is what the demo's horse actually runs, and it means the cast length varies all the
/// way round even at a fixed radius.
function anim_shadow_orbit_test() {
    var _L   = { x: 0, y: 0, h: 60, r: 340 };
    var _rig = anim_shadow_test_rig();
    // The shipped ~24px setting first, then both ends of what the dial can reach.
    var _folds = [0.52, 0.1, 1.2];
    var _radii = [50, 90, 150, 230];
    // A caster with no isoTilt at all -- the humanoid, whose baseline stays level through
    // the origin. anim_shadow_ground returns t=0,c=0 there, a geometry the horse never
    // produces and which nothing else in these sweeps covers.
    var _flat = { t: 0, c: 0, w: 1 };
    var _ly   = ANIM_SHADOW_CARD_LY;
    var _tightest = 999999;

    for (var _fi = 0; _fi < array_length(_folds); _fi++) {
        var _minfold = _folds[_fi];
        for (var _ri = 0; _ri < array_length(_radii); _ri++) {
            var _rad = _radii[_ri];
            // WHICH way facing is locked to the orbit. Modes 0 and 1 are the horse running
            // the circle each way round; 2 keeps it pointed at the lamp the whole way,
            // which is the collapse case, its baseline lying along its own cast; 3 never
            // turns at all, so the lamp sweeps past a caster that stays put. 4 is the
            // level-baseline caster, running.
            for (var _mode = 0; _mode <= 4; _mode++) {
                var _pax = 0, _pay = 0, _pbx = 0, _pby = 0, _have = false;
                for (var _i = 0; _i <= 720; _i++) {
                    var _oa = _i * 0.5;                  // where round the lamp it has got
                    // Ground-space circle; screen y is half of ground y.
                    var _cx = _L.x + _rad * dcos(_oa);
                    var _cy = _L.y + _rad * dsin(_oa) * 0.5;
                    // Screen-space tangent to that path, which is what the demo derives a
                    // running character's facing from.
                    var _tx2 = -_rad * dsin(_oa);
                    var _ty2 =  _rad * dcos(_oa) * 0.5;

                    var _dir;
                    switch (_mode) {
                        case 0:  _dir = point_direction(0, 0, _tx2, _ty2);            break;
                        case 1:  _dir = point_direction(0, 0, -_tx2, -_ty2);          break;
                        case 2:  _dir = point_direction(_cx, _cy, _L.x, _L.y);        break;
                        case 3:  _dir = 90;                                           break;
                        default: _dir = point_direction(0, 0, _tx2, _ty2);            break;
                    }

                    var _s = anim_light_shadow(_L, _cx, _cy);
                    if (_s == undefined) continue;       // out of the lamp's reach
                    var _g   = (_mode == 4) ? _flat : anim_shadow_ground(_rig, _dir, false);
                    var _tt  = anim_shadow_lean(_s, _g, _minfold);
                    var _div = anim_shadow_spread(_s, _g, _tt, _ly);

                    // WIDTH, which is the other half of the job and the half that has no
                    // hard failure to trip over -- a shadow quietly narrowing is a
                    // regression nobody's assertion catches. Counted as the share of
                    // samples where the guarded fold ends up under four fifths of what the
                    // dial asked for.
                    var _foldg = _tt * _s.ux - _s.uy * 0.5;
                    global.anim_shadow_worst.total++;
                    if (abs(_foldg) < _minfold * 0.8) global.anim_shadow_worst.narrow++;

                    var _worst = anim_shadow_xscale(_s, _g, _tt, _div, _ly);
                    _tightest = min(_tightest, _worst);
                    if (_worst < global.anim_shadow_worst.xscale) {
                        global.anim_shadow_worst.xscale = _worst;
                        global.anim_shadow_worst.xwhere = "fold " + string(_minfold);
                    }
                    if (_worst < ANIM_SHADOW_MIN_XSCALE - 0.02) {
                        return "orbit: shadow mirrored/collapsed, x-scale "
                             + string_format(_worst, 1, 2) + " at orbit " + string(_oa)
                             + " deg, radius " + string(_rad) + ", mode " + string(_mode)
                             + ", facing " + string_format(_dir, 1, 1)
                             + ", fold " + string(_minfold);
                    }

                    // FLICKER, measured from the caster's OWN anchor, so the shadow moving
                    // with a running horse is not counted -- only the shape changing under
                    // it. Copied out because the station struct is shared scratch.
                    var _a = anim_shadow_station(_s, _g, _tt, -23, _div, _ly,
                                                 ANIM_SHADOW_TALL);
                    var _ax2 = _a.tx, _ay2 = _a.ty;
                    var _b = anim_shadow_station(_s, _g, _tt,  23, _div, _ly,
                                                 ANIM_SHADOW_TALL);
                    var _bx2 = _b.tx, _by2 = _b.ty;
                    if (_have) {
                        var _jump = max(point_distance(_ax2, _ay2, _pax, _pay),
                                        point_distance(_bx2, _by2, _pbx, _pby));
                        if (_jump > global.anim_shadow_worst.jump) {
                            global.anim_shadow_worst.jump  = _jump;
                            global.anim_shadow_worst.where = "orbit " + string(_oa)
                                + " r" + string(_rad) + " mode " + string(_mode)
                                + ", fold " + string(_minfold);
                        }
                        if (_jump > ANIM_SHADOW_MAX_JUMP) {
                            return "orbit: shadow flickers " + string_format(_jump, 1, 1)
                                 + "px at orbit " + string(_oa) + " deg, radius "
                                 + string(_rad) + ", mode " + string(_mode)
                                 + ", facing " + string_format(_dir, 1, 1)
                                 + ", fold " + string(_minfold);
                        }
                    }
                    _pax = _ax2; _pay = _ay2; _pbx = _bx2; _pby = _by2; _have = true;
                }
            }
        }
    }

    if (_tightest > ANIM_SHADOW_MIN_XSCALE + 0.5) {
        return "orbit never comes near the mirror boundary (narrowest "
             + string_format(_tightest, 1, 2) + ") -- its mirror check proves nothing";
    }
    return anim_shadow_rig_check();
}

/// Render the already assembled palette once, then cast that ONE texture into the wedge
/// the light throws.
///
/// The same depth-sorted horse/rider or humanoid that appears on screen supplies the alpha
/// cutout, so a body piece or head cannot disappear independently -- but posed at the
/// LIGHT's facing rather than the camera's (anim_shadow_dir), which is the whole idea.
///
/// The history is worth keeping, because four separate artifacts all had one cause. This
/// used to transform the CAMERA's card into a shadow. That card's structure lies along the
/// ray whenever the caster points at the lamp, so casting it collapsed the silhouette to a
/// 2px dash; and every attempt to widen the dash failed in its own way -- a floored ky
/// mirror-popped as the caster crossed the light's row, a swept fan of stamps banded, a
/// laid-down second card double-exposed, and a sideways smear stamped the narrow image
/// past itself into a featureless slab. None of them could work: no transform of a card
/// drawn for one viewpoint can produce the silhouette seen from another.
///
/// Posing the shadow from the light removes the cause instead of the symptom. The card
/// then IS the outline being cast, at the right width for free: broadside to the light it
/// is the whole body, nose-on it foreshortens to the flank. Nothing here needs a declared
/// footprint, a minimum width, a smear or a special case, and the rigs no longer carry a
/// `groundFootprint` because of it.
///
/// What remains is the projection: lay the card's horizontal axis across the ray, and cast
/// each column along ITS OWN ray out of the light so the wedge spreads with distance
/// rather than running as a parallel strip. Column-varying direction is not affine, so
/// this cannot go through draw_surface_ext or one world matrix. It is a textured triangle
/// strip: stations across the card, two vertices each, adjacent quads SHARING their
/// vertices so the fan cannot open seams -- which is what killed the earlier stamp fan.
function anim_shadow_paint(_parts, _s, _g, _ax, _ay, _dst, _main_cam, _cast_surf, _cast_cam) {
    if (!surface_exists(_dst) || !surface_exists(_cast_surf)) return;
    // A 256px card leaves 240px above the stable origin and 16px below it.
    var _size = ANIM_SHADOW_CARD;
    var _lx = ANIM_SHADOW_CARD_LX, _ly = ANIM_SHADOW_CARD_LY;
    camera_set_view_pos(_cast_cam, _ax - _lx, _ay - _ly);
    camera_set_view_size(_cast_cam, _size, _size);
    surface_reset_target();
    surface_set_target(_cast_surf);
    draw_clear_alpha(c_black, 0);
    camera_apply(_cast_cam);
    anim_paint(_parts, true);                          // exact palette, without contact blob
    surface_reset_target();
    surface_set_target(_dst);
    camera_apply(_main_cam);
    var _grey = make_colour_rgb(_s.a255, _s.a255, _s.a255);

    // The sprite lies down on the floor, once. Card-x maps straight through to screen x,
    // so the nose stays where the nose is: the shadow is the drawn character's own palette
    // reflected onto the ground, and it turns exactly with it.
    //
    // Each column casts along ITS OWN ray out of the light, which is what opens the wedge
    // with distance -- the two lines running out from the lamp past either side of the
    // caster -- rather than a parallel strip. Height is measured from the card's own ground
    // row and the root lands on that same row, so a foot at zero height maps exactly onto
    // itself and the shadow stays welded to the feet.
    //
    // ONE stamp, deliberately. A previous revision stamped the card several times, offset
    // sideways, to fake the thickness a flat cutout does not have. It cost exactly what
    // stamping always costs: the overlapping copies blurred the palette into a dithered
    // slab, and because each copy rooted on its own line the union's near edge pulled away
    // from the hooves and the legs came unstuck. Both of those were the smear, not the
    // projection. The honest trade is that with the lamp nearly in line with the caster's
    // own axis there is genuinely nothing side-on to cast, and the shadow goes thin there.
    //
    // Column-varying direction is not affine, so this cannot go through draw_surface_ext
    // or one world matrix: it is a textured triangle strip, two vertices per station, with
    // adjacent quads SHARING them so the fan cannot open seams. Two rows is vertically
    // exact, the cast being linear in height.
    // NEVER FOLD FLAT, AND NEVER FOLD OVER.
    //
    // The shadow's width comes from the angle between two directions: the baseline the
    // card stands on, and the cast running out from the lamp. When those two line up the
    // whole card folds onto a single line and the shadow all but disappears -- which is
    // what happens when the caster points straight at the lamp, since then its baseline
    // and its shadow run the same way. Separating the hoof rows cannot help there: that
    // separation lies ALONG the shadow, not across it. anim_shadow_lean holds a floor
    // under that angle; anim_shadow_spread stops the wedge folding the strip back through
    // itself. The two failures are different and neither guard catches the other's.
    // Read from the global, not the macro, so it can be dialled live from the HUD --
    // O and P in the demo. The macro is only the starting value (see anim_boot).
    var _tt = anim_shadow_lean(_s, _g, global.anim_shadow_min_fold);

    // How much of the wedge this geometry can actually carry. Nearly always all of it; less
    // only where the lamp is close enough that the ray swing across the card would fold the
    // strip back through itself.
    var _div = anim_shadow_spread(_s, _g, _tt, _ly);

    shader_set(sh_silhouette);

    // The stations are solved ONCE into a table and every copy below reads it back. The
    // band and the ring lay this same strip down up to twenty more times, and re-solving
    // seventeen stations for every copy of every caster against every light is what halved
    // the frame rate the last time this loop grew. anim_shadow_station hands back one
    // shared scratch struct, so the fields are copied out rather than the struct kept.
    var _st = ANIM_SHADOW_STATIONS;
    static _kx = array_create(ANIM_SHADOW_STATIONS + 1);   // root
    static _ky = array_create(ANIM_SHADOW_STATIONS + 1);
    static _kX = array_create(ANIM_SHADOW_STATIONS + 1);   // tip
    static _kY = array_create(ANIM_SHADOW_STATIONS + 1);
    static _kU = array_create(ANIM_SHADOW_STATIONS + 1);   // u across the card
    static _kB = array_create(ANIM_SHADOW_STATIONS + 1);   // v of the ground row
    for (var i = 0; i <= _st; i++) {
        var _u = -_lx + (i / _st) * _size;
        var _p = anim_shadow_station(_s, _g, _tt, _u, _div, _ly);
        _kx[i] = _ax + _p.rx;  _ky[i] = _ay + _p.ry;
        _kX[i] = _ax + _p.tx;  _kY[i] = _ay + _p.ty;
        _kU[i] = (_u + _lx) / _size;
        // The strip STOPS at the ground row. Card rows below it are the few pixels of hoof
        // hanging under the joint, and they carry negative height -- cast as-is they throw
        // shadow BACKWARDS past the feet towards the lamp.
        _kB[i] = _p.hT / _size;
    }

    // Each entry below is one COPY of the strip, at a screen offset. Three kinds share the
    // list: the strip itself; the K/L band, which fills the resting gap across the ray
    // exactly as it always has; and the minimum-width ring, which redraws the strip on a
    // small circle so the union is the shadow grown equally in every direction. How the
    // ring decides whether to engage at all -- and why that decision is finally sound --
    // is with the ring block below.    static _ox = array_create(24);
    static _oy = array_create(24);
    var _nc = 0;
    _ox[_nc] = 0; _oy[_nc] = 0; _nc++;

    var _pnx = -_s.uy, _pny = _s.ux * 0.5;
    var _pn  = max(0.0001, sqrt(_pnx * _pnx + _pny * _pny));
    _pnx /= _pn;  _pny /= _pn;
    var _q0  = anim_shadow_station(_s, _g, _tt, _g.ub, _div, _ly);
    var _e0x = _q0.rx, _e0y = _q0.ry;
    var _q1  = anim_shadow_station(_s, _g, _tt, _g.uf, _div, _ly);
    var _sep = abs((_q1.rx - _e0x) * _pnx + (_q1.ry - _e0y) * _pny);
    var _dd  = max(0, _g.d - _sep) * 0.5;      // only the shortfall against the K/L gap
    var _cp  = 6;
    if (_dd > 0.5) {
        for (var k = -_cp; k <= _cp; k++) {
            if (k == 0) continue;
            _ox[_nc] = (k / _cp) * _dd * _pnx;
            _oy[_nc] = (k / _cp) * _dd * _pny;
            _nc++;
        }
    }

    // THE RING ENGAGES ONLY ON THE SHORTFALL, so every cast already at the minimum width is
    // drawn to the pixel as it always was -- radius zero adds no copies at all -- and a
    // collapsing one is held AT the minimum rather than grown past it. Unconditional, the
    // ring fattened every shadow in the room to fix the few that needed it.
    //
    // How thin this cast is comes from its ENVELOPE: the four corners of the OCCUPIED part
    // of the card -- the caster's own span by its drawn height, NOT the mostly-empty 256px
    // quad -- put through the same stations the strip is drawn from, and the narrowest
    // caliper width of the quadrilateral they land on. Every earlier conditional derived
    // thinness from geometry the screen does not draw and each was wrong somewhere; this
    // one is exact precisely where it has to be, because a degenerate cast maps EVERYTHING
    // onto its thin envelope, so at the failure the envelope width IS the visible width.
    // Away from the failure it overestimates -- and there that only means the ring stays
    // off, which is the correct answer anyway.
    var _qa  = anim_shadow_station(_s, _g, _tt, -ANIM_SHADOW_WIDE * 0.5, _div, _ly);
    var _wax = _qa.rx, _way = _qa.ry;                      // copied out: shared scratch
    var _wk  = (_qa.hT > 1) ? min(1, ANIM_SHADOW_TALL / _qa.hT) : 0;
    var _wdx = _qa.rx + (_qa.tx - _qa.rx) * _wk;           // tip at the DRAWN height, not
    var _wdy = _qa.ry + (_qa.ty - _qa.ry) * _wk;           // the card's empty top edge
    var _qb  = anim_shadow_station(_s, _g, _tt,  ANIM_SHADOW_WIDE * 0.5, _div, _ly);
    var _wbx = _qb.rx, _wby = _qb.ry;
    var _wk2 = (_qb.hT > 1) ? min(1, ANIM_SHADOW_TALL / _qb.hT) : 0;
    var _wcx = _qb.rx + (_qb.tx - _qb.rx) * _wk2;
    var _wcy = _qb.ry + (_qb.ty - _qb.ry) * _wk2;

    // Narrowest caliper width: for each edge of the quad, how far the other two corners
    // stand off its line; the smallest of those is how thin the envelope gets.
    var _qw = 999999;
    for (var e = 0; e < 4; e++) {
        var _p1x = 0, _p1y = 0, _p2x = 0, _p2y = 0;
        var _o1x = 0, _o1y = 0, _o2x = 0, _o2y = 0;
        switch (e) {
        case 0:  _p1x=_wax; _p1y=_way; _p2x=_wbx; _p2y=_wby;
                 _o1x=_wcx; _o1y=_wcy; _o2x=_wdx; _o2y=_wdy; break;
        case 1:  _p1x=_wbx; _p1y=_wby; _p2x=_wcx; _p2y=_wcy;
                 _o1x=_wax; _o1y=_way; _o2x=_wdx; _o2y=_wdy; break;
        case 2:  _p1x=_wcx; _p1y=_wcy; _p2x=_wdx; _p2y=_wdy;
                 _o1x=_wax; _o1y=_way; _o2x=_wbx; _o2y=_wby; break;
        default: _p1x=_wdx; _p1y=_wdy; _p2x=_wax; _p2y=_way;
                 _o1x=_wbx; _o1y=_wby; _o2x=_wcx; _o2y=_wcy; break;
        }
        var _elx = _p2x - _p1x, _ely = _p2y - _p1y;
        var _el  = sqrt(_elx * _elx + _ely * _ely);
        if (_el < 0.001) continue;
        var _d1 = abs((_o1x - _p1x) * _ely - (_o1y - _p1y) * _elx) / _el;
        var _d2 = abs((_o2x - _p1x) * _ely - (_o2y - _p1y) * _elx) / _el;
        _qw = min(_qw, max(_d1, _d2));
    }

    // Only the shortfall, halved into a radius: a 3px envelope gets a 1px ring and comes
    // out at the minimum; a 5px one gets radius zero and is untouched to the pixel. The
    // radius is continuous in the width, so nothing pops as a caster turns through the
    // boundary.
    //
    // PER CASTER, not global. The minimum belongs to the thing casting: a horse (with or
    // without its rider) carries `shadow_minw` on the instance and anim_shadow_pair passes
    // it through here; a caster without one -- the dismounted player, the skeletons --
    // gets zero and is never widened at all. The width floor exists because the horse's
    // long body collapses to a streak at some headings; a humanoid's shadow was never the
    // complaint, and widening it too was part of what kept reading as wrong.
    var _minw = global[$ "anim_shadow_cast_minw"] ?? 0;
    var _rr = clamp((_minw - _qw) * 0.5, 0, _minw * 0.5);
    if (_rr > 0.15) {
        for (var k = 0; k < 8; k++) {
            _ox[_nc] = _rr * dcos(k * 45);
            _oy[_nc] = _rr * dsin(k * 45);
            _nc++;
        }
    }

    // ONE primitive for every copy, joined by zero-area triangles: repeating the vertex
    // either side of a join gives the bridging triangles no area, so they rasterise
    // nothing and the copies stay separate shapes inside a single draw call.
    draw_primitive_begin_texture(pr_trianglestrip, surface_get_texture(_cast_surf));
    var _px2 = 0, _py2 = 0, _pu2 = 0, _pb2 = 0;
    for (var c = 0; c < _nc; c++) {
        var _cx2 = _ox[c], _cy2 = _oy[c];
        if (c > 0) {
            draw_vertex_texture_colour(_px2, _py2, _pu2, _pb2, _grey, 1);
            draw_vertex_texture_colour(_kX[0] + _cx2, _kY[0] + _cy2, _kU[0], 0, _grey, 1);
        }
        for (var j = 0; j <= _st; j++) {
            draw_vertex_texture_colour(_kX[j] + _cx2, _kY[j] + _cy2, _kU[j], 0,      _grey, 1);
            draw_vertex_texture_colour(_kx[j] + _cx2, _ky[j] + _cy2, _kU[j], _kB[j], _grey, 1);
        }
        _px2 = _kx[_st] + _cx2;  _py2 = _ky[_st] + _cy2;
        _pu2 = _kU[_st];         _pb2 = _kB[_st];
    }
    draw_primitive_end();
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
        // Through the air, not across the floor: a lamp standing directly over a character
        // is still a lamp some distance away, and lifting it has to dim what it throws.
        var _d3  = sqrt(_gd * _gd + _L.h * _L.h);
        if (_d3 > _L.r || _gd < 1) continue;
        var _t = 1 - _d3 / _L.r;
        // Cubic, and gentle: additive warm over already-saturated art blows out fast (an
        // orange horse turned lava at the first attempt). This is a kiss of light for
        // characters practically touching the lamp, not a paint job.
        var _a = 0.16 * _t * _t * _t;
        if (_a < 0.02) continue;
        var _ox = -_dgx / _gd * 1.5;
        var _oy = -_dgy * 0.5 / _gd * 1.5;
        // What the lamp actually throws. Ordinary lamps keep the fixed warm they have always
        // used; an EFFECT lamp puts its own colour on whoever is standing in it, which is the
        // difference between a disco ball and a violet circle on the floor. Its pool tint is
        // dim by design (it is added to the floor), so it is taken up to full brightness here
        // -- `_a` above is what keeps this a kiss of light rather than a paint job.
        //
        // Read through the accessor: the projection tests build bare light structs with no
        // tint at all, and this runs for every character in range of every light.
        var _tint = make_colour_rgb(226, 208, 168);
        if ((_L[$ "fx"] ?? "") != "") {
            var _tc = _L.col;
            var _m  = max(colour_get_red(_tc), colour_get_green(_tc), colour_get_blue(_tc));
            if (_m > 1) _tint = make_colour_rgb(colour_get_red(_tc)   * 255 / _m,
                                                colour_get_green(_tc) * 255 / _m,
                                                colour_get_blue(_tc)  * 255 / _m);
        }
        gpu_set_blendmode(bm_add);
        var _count = array_length(_parts);
        for (var i = 0; i < _count; i += PART.SIZE) {
            if (_parts[i + PART.DEPTH] >= 900000) continue;      // not the contact blob
            var _spr = _parts[i + PART.SPR];
            if (_spr == undefined || !sprite_exists(_spr)) continue;
            draw_sprite_ext(_spr, _parts[i + PART.SUB],
                _parts[i + PART.X] + _ox, _parts[i + PART.Y] + _oy,
                _parts[i + PART.XS], _parts[i + PART.YS], _parts[i + PART.ANG],
                _tint, _a * _parts[i + PART.ALPHA]);
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
        // Same true distance the cast shadow fades by, or the blob would hand over to a
        // cast shadow that a raised lamp has already faded out, and leave a gap.
        var _d3 = sqrt(_gd * _gd + _L.h * _L.h);
        if (_d3 < _L.r) _best = max(_best, 1 - _d3 / _L.r);
    }
    return 1 - _best;
}

/// Stamp one character's silhouette for ONE light into that light's active surface.
/// Shadows are kept per light so a pool can fade OTHER lights' shadows crossing it
/// without erasing its own -- a character standing inside a pool blocks that pool's
/// light, and its shadow there must stay strong (a shared surface made it float
/// detached, the near half eaten by its own caster's fade).
function anim_shadow_char(_L, _rig, _clip, _play, _x, _y, _dir, _look, _is_player,
                          _dst, _main_cam, _cast_surf, _cast_cam) {
    var _s = anim_light_shadow(_L, _x, _y);
    if (_s == undefined) return;
    // The DRAWN facing: the shadow is the character you are looking at, laid down.
    var _g = anim_shadow_ground(_rig, _dir, _is_player);
    var _p = anim_build(anim_scratch(), _rig, _clip, _play, _x, _y, _dir, _look, _is_player);
    // Humanoids and skeletons carry no width floor: the minimum is the horse's property
    // (see anim_shadow_paint), and a dismounted player's shadow is left exactly as drawn.
    global.anim_shadow_cast_minw = 0;
    anim_shadow_paint(_p, _s, _g, _x, _y, _dst, _main_cam, _cast_surf, _cast_cam);
}

/// The mount-and-rider version uses one assembled palette and the mount's stable object
/// origin. A gallop can lift every hoof without making the projected card jitter between
/// whichever animated leg happens to be lowest that frame.
function anim_shadow_pair(_L, _h, _dst, _main_cam, _cast_surf, _cast_cam) {
    var _s = anim_light_shadow(_L, _h.x, _h.y);
    if (_s == undefined) return;
    // Drawn facings throughout, so the pair's shadow is the pair you are looking at.
    var _g = anim_shadow_ground(_h.rig, _h.direction, false);
    var _p = anim_scratch();
    if (_h.rider != noone) {
        var _r = _h.rider;
        anim_build(_p, _r.rig, _r.clip, _r.play, _r.x, _r.y, _r.direction, _r.look, true,
                   anim_mount_state(_h.rig, _h.direction));
    }
    anim_build(_p, _h.rig, _h.clip, _h.play, _h.x, _h.y, _h.direction, _h.look, false);
    // The width floor rides on the HORSE INSTANCE -- `shadow_minw`, set in its Create --
    // so it applies to the horse and to horse-plus-rider, is absent for everyone else,
    // and can differ per horse if one ever needs it to.
    global.anim_shadow_cast_minw = _h[$ "shadow_minw"] ?? 0;
    anim_shadow_paint(_p, _s, _g, _h.x, _h.y, _dst, _main_cam, _cast_surf, _cast_cam);
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
























