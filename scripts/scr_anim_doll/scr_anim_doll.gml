/// RAGDOLL
///
/// A knocked-down body stops being a POSE and becomes a set of points with distances between
/// them. The clip is read exactly once -- at the moment of the hit, whatever the body happened
/// to be doing -- and from then on the limbs are simulated: they swing from the shoulder, trail
/// behind the torso as it tumbles, fold when they hit the ground and end up wherever the fall
/// left them. That is the difference between a body falling and a drawing of a body falling.
///
/// Position-based dynamics: predict where every point would go, then satisfy the distances by
/// MOVING the points, and read the velocity back off how far each one actually ended up
/// travelling. A bone can therefore never stretch permanently however violent the launch, which
/// an impulse solver only promises. Fourteen parts and a handful of links per body, so it stays
/// cheap enough to run on every skeleton in the room at once.
///
/// Velocity is stored EXPLICITLY rather than implied by a previous position. Plain Verlet
/// carries velocity as "how far it moved last frame", which silently means "per frame at
/// whatever rate we were running then" -- and this demo's frame rate swings from 90 to 8 while
/// an explosion is on screen. The first version of this stored the launch as a 1/60th-of-a-
/// second step, ran its first frame 115ms later, and the bodies tumbled about seven times too
/// slowly: they slid outward in the pose they were hit in, looking exactly like no simulation at
/// all. Seconds are the only unit that survives a variable frame time.
///
/// THREE SPACES, and mixing them up is the trap:
///   * screen -- what is drawn. The isometric halving lives here.
///   * ground -- the floor plane. Ground y is screen y DOUBLED, as everywhere in this demo.
///   * height -- straight screen y, the one axis the projection does not halve.
/// A particle stores (X, Y, Z) = screen-x offset, ground-row screen-y offset, height. Distances
/// between particles are solved in GROUND space, because a bone is a real length and does not
/// get shorter because the camera is looking down the y axis. Everything is an OFFSET from the
/// body's anchor, so the instance keeps owning where the body travels -- and its cast shadow,
/// its depth and its culling keep working off that same anchor.

/// One simulated point: where it is, and how fast it is going in PIXELS PER SECOND.
enum DPT { X, Y, Z, VX, VY, VZ, SIZE }

/// One drawn segment, spanning two points. KIND 0 is a lone sprite -- a torso or a head -- which
/// has no next joint to aim at, so it gets a second point on an invented lever arm purely so it
/// has an ORIENTATION to simulate. KIND 1 is a real bone between two real joints, and stretches
/// to span them exactly as anim_build's does.
enum DBONE { KIND, A, B, SPR, SUB, COL, ALPHA, DEPTH, SC, YS, SIZE }

/// Length of the invented lever on a lone sprite. Long enough that the solver can turn it
/// without the two points fighting over rounding, short enough to stay inside the body.
#macro DOLL_LEVER 18

/// Constraint passes per frame, when the quality tier has not said otherwise. Three keeps a
/// fourteen-part body together; one leaves it visibly rubbery on the frame it lands, which is
/// what the low tier trades away.
#macro DOLL_ITERS 3

/// Relative gravity, in height-pixels per second squared. Only applies once the body's anchor
/// is on the ground -- see anim_doll_step.
#macro DOLL_GRAV 1400

/// Fraction of a point's speed kept per second while it is in the air. A body is not a
/// pendulum: limbs that swing on for three seconds after it lands read as a puppet.
#macro DOLL_DAMP 0.35

/// ...and per second while it is dragging along the ground, which takes speed away far faster.
#macro DOLL_GRIP 0.004

/// Below this speed, summed over the whole body, it is treated as settled and the solver is
/// skipped -- which is most of the time a body spends lying there, and is what lets a room full
/// of downed skeletons cost nothing. Generous on purpose: a threshold tight enough to be
/// "really stopped" is one the last half-pixel of solver jitter never gets under, and then a
/// hundred settled bodies go on paying full price forever.
#macro DOLL_STILL 30

/// ...and how long it has to stay that slow. Short, because the test above is already generous.
#macro DOLL_STILL_T 0.1

/// Find or make the point for a named joint. Sharing matters: a chain's bones must hand the SAME
/// point back and forth or the arm comes apart at the elbow the first time it is pulled.
function anim_doll_point(_d, _name, _px, _py, _ax, _ay) {
    var _e = _d.key[$ _name];
    if (_e != undefined) return _e;
    var _i = array_length(_d.p);
    array_push(_d.p, _px - _ax, 0, _ay - _py, 0, 0, 0);
    _d.key[$ _name] = _i;
    return _i;
}

/// Tie two points together at whatever distance they are currently apart. Rest lengths are
/// MEASURED, never authored -- the rig already knows how long a forearm is, and measuring means
/// this works for any rig without a table to keep in step.
///
/// `_min` makes the tie ONE-SIDED: it pushes apart when the two get closer than that fraction
/// of their rest length, and does nothing otherwise. That is the difference between a joint
/// limit and a strut. A two-sided brace across the knee turns each leg into a rigid triangle,
/// and a body with two rigid legs and a rigid spine simply STANDS THERE under gravity, held up
/// by its own constraints -- which is exactly what the first version of this did.
function anim_doll_link(_d, _a, _b, _stiff, _min = 0) {
    var _p = _d.p;
    var _dx = _p[_b + DPT.X] - _p[_a + DPT.X];
    var _dy = (_p[_b + DPT.Y] - _p[_a + DPT.Y]) * 2;    // ground space
    var _dz = _p[_b + DPT.Z] - _p[_a + DPT.Z];
    array_push(_d.link, _a, _b, sqrt(_dx * _dx + _dy * _dy + _dz * _dz), _stiff, _min);
}

/// Read a character's current pose ONCE and hang a ragdoll on it. Everything after this is
/// simulation: the clip is never sampled again (except to reassemble -- see anim_doll_pull).
function anim_doll_make(_rig, _clip, _play, _x, _y, _dir, _look) {
    static _cap = [];
    array_resize(_cap, 0);
    var _parts = anim_build([], _rig, _clip, _play, _x, _y, _dir, _look, false, undefined, _cap);

    var _d = { p: [], link: [], bone: [], fol: [], blob: [], key: {}, bkey: {}, still: 0,
               arms: [] };
    var _chain = {};                       // per chain: root point, lever point, bone count
    var _trunk_a = -1, _trunk_b = -1;
    var _pbone = [];                       // part ordinal -> bone offset, for the followers
    var _n = array_length(_cap);
    array_resize(_pbone, _n);

    for (var j = 0; j < _n; j++) {
        _pbone[j] = -1;
        var _e = _cap[j];
        var _o = j * PART.SIZE;
        if (_e.k > 1) continue;

        var _px = _parts[_o + PART.X], _py = _parts[_o + PART.Y];
        var _ck = string(_e.c);
        var _a  = anim_doll_point(_d, _ck + "_" + string(_e.i), _px, _py, _x, _y);
        var _b;
        if (_e.k == 0) {
            // No next joint: invent one straight "up" out of the sprite, so the solver has
            // something to turn. Its angle is read back off the same lever when drawing.
            var _la = _parts[_o + PART.ANG] + 90;
            _b = anim_doll_point(_d, _ck + "_lever",
                                 _px + lengthdir_x(DOLL_LEVER, _la),
                                 _py + lengthdir_y(DOLL_LEVER, _la), _x, _y);
        } else {
            _b = anim_doll_point(_d, _ck + "_" + string(_e.i + 1), _e.nx, _e.ny, _x, _y);
        }

        _pbone[j] = array_length(_d.bone);
        _d.bkey[$ _ck + "_" + string(_e.i)] = _pbone[j];
        array_push(_d.bone, _e.k, _a, _b,
                   _parts[_o + PART.SPR], _parts[_o + PART.SUB], _parts[_o + PART.COL],
                   _parts[_o + PART.ALPHA], _parts[_o + PART.DEPTH],
                   (_e.k == 0) ? _parts[_o + PART.XS] : _e.sw, _parts[_o + PART.YS]);
        anim_doll_link(_d, _a, _b, 1);

        var _c = _chain[$ _ck];
        if (_c == undefined) {
            _c = { root: _a, lever: (_e.k == 0) ? _b : -1, n: 0 };
            _chain[$ _ck] = _c;
        }
        if (_e.i == 0) { _c.root = _a; if (_e.k == 0) _c.lever = _b; }
        _c.n = max(_c.n, _e.i + 1);
        // The torso is the hub every other chain hangs off. Named, not guessed at by position:
        // a rig is free to list its chains in any order.
        if (_rig.chain[_e.c].id == "body") { _trunk_a = _a; _trunk_b = _b; }
    }

    if (_trunk_a < 0) return _d;           // no torso to hang anything on; leave it as loose bones

    var _ids = variable_struct_get_names(_chain);
    for (var i = 0; i < array_length(_ids); i++) {
        var _c = _chain[$ _ids[i]];
        // The ARM points, recorded as their own group. Only the baked knockdowns use this: it
        // is what lets one body's arms be given another one's flop without its shoulders going
        // with them, because everything here is kept relative to the shoulder it hangs off.
        if (string_pos("arm", _rig.chain[real(_ids[i])].id) == 1) {
            var _grp = { root: _c.root, pts: [] };
            for (var k = 0; k <= _c.n; k++) {
                var _ap = _d.key[$ _ids[i] + "_" + string(k)];
                if (_ap != undefined && _ap != _c.root) array_push(_grp.pts, _ap);
            }
            if (array_length(_grp.pts) > 0) array_push(_d.arms, _grp);
        }
        if (_c.root == _trunk_a) continue;                       // this IS the torso
        // A limb is PINNED at its root and free everywhere else -- that is what lets it swing.
        // The second, slack tie to the far end of the torso is what stops a shoulder sliding
        // around the chest; without it the arms orbit the neck.
        anim_doll_link(_d, _c.root, _trunk_a, 1);
        anim_doll_link(_d, _c.root, _trunk_b, 0.35);
        if (_c.lever >= 0) anim_doll_link(_d, _c.lever, _trunk_b, 0.3);   // neck
        // A JOINT LIMIT across each elbow and knee: it stops a limb folding back through itself,
        // and does nothing at all until it is folded that far. It must not hold the limb
        // straight -- see anim_doll_link.
        for (var k = 0; k + 2 <= _c.n; k++) {
            var _p0 = _d.key[$ _ids[i] + "_" + string(k)];
            var _p2 = _d.key[$ _ids[i] + "_" + string(k + 2)];
            if (_p0 != undefined && _p2 != undefined) anim_doll_link(_d, _p0, _p2, 0.5, 0.4);
        }
    }

    // Hair, face and the sword are not simulated: they are pinned to a bone and go where it
    // goes. Their offset is recorded in that bone's own frame, so the hair stays on the head
    // however far the head ends up turning.
    for (var j = 0; j < _n; j++) {
        var _e = _cap[j];
        var _o = j * PART.SIZE;
        if (_e.k == 2) {
            if (_e.ref < 0 || _pbone[_e.ref] < 0) continue;
            var _ro = _e.ref * PART.SIZE;
            var _ra = _parts[_ro + PART.ANG];
            var _dx = _parts[_o + PART.X] - _parts[_ro + PART.X];
            var _dy = _parts[_o + PART.Y] - _parts[_ro + PART.Y];
            var _cc = dcos(_ra), _ss = dsin(_ra);
            array_push(_d.fol, {
                b:  _pbone[_e.ref],
                lx: _dx * _cc - _dy * _ss,          // into the bone's frame
                ly: _dx * _ss + _dy * _cc,
                da: _parts[_o + PART.ANG] - _ra,
                dd: _parts[_o + PART.DEPTH] - _parts[_ro + PART.DEPTH],
                spr: _parts[_o + PART.SPR], sub: _parts[_o + PART.SUB],
                col: _parts[_o + PART.COL], alpha: _parts[_o + PART.ALPHA],
                xs: _parts[_o + PART.XS],   ys: _parts[_o + PART.YS]
            });
        } else if (_e.k == 3) {
            // The soft blob under the feet stays on the floor at the anchor. It is a contact
            // shadow, and a contact shadow does not tumble with the body.
            array_push(_d.blob, {
                spr: _parts[_o + PART.SPR], sub: _parts[_o + PART.SUB],
                dy:  _e.dy,                 col: _parts[_o + PART.COL],
                alpha: _parts[_o + PART.ALPHA],
                sx:  _parts[_o + PART.XS],  sy: _parts[_o + PART.YS]
            });
        }
    }
    return _d;
}

/// Set the body spinning. The axis lies in the GROUND plane and across the direction of travel,
/// so a body thrown north somersaults over its own head rather than pirouetting.
///
/// `_sign` picks WHICH END LEADS, and the two look completely different. Working the algebra
/// through: with the axis as built below, `+1` makes the top TRAIL the direction of travel --
/// the feet fly out first and the body goes over backwards, which is what a blast at ground
/// level does to someone standing in it, because the push lands below their centre. `-1` makes
/// the top lead, pitching them face-first in the direction they are thrown.
///
/// Every point gets v = w x r about the body's centre, which is what makes this read as one
/// object turning rather than fourteen sprites each doing their own thing.
function anim_doll_kick(_d, _head, _rate, _sign, _spread) {
    var _p = _d.p, _n = array_length(_p);
    if (_n == 0) return;
    var _cx = 0, _cy = 0, _cz = 0, _cnt = _n / DPT.SIZE;
    for (var i = 0; i < _n; i += DPT.SIZE) {
        _cx += _p[i + DPT.X]; _cy += _p[i + DPT.Y] * 2; _cz += _p[i + DPT.Z];
    }
    _cx /= _cnt; _cy /= _cnt; _cz /= _cnt;

    var _ax = lengthdir_x(1, _head + 90) * _sign + random_range(-_spread, _spread);
    var _ay = lengthdir_y(1, _head + 90) * _sign + random_range(-_spread, _spread);
    var _az = random_range(-_spread, _spread);
    var _ln = sqrt(_ax * _ax + _ay * _ay + _az * _az);
    if (_ln < 0.0001) return;
    var _w = _rate / _ln;
    _ax *= _w; _ay *= _w; _az *= _w;

    // Written through the `@` accessor, here and in the solver. Without it these assignments
    // land on a COPY of the array and are silently thrown away -- the bodies were kicked with a
    // perfectly good spin every time and stood there in the pose they were hit in.
    for (var i = 0; i < _n; i += DPT.SIZE) {
        var _rx = _p[i + DPT.X] - _cx;
        var _ry = _p[i + DPT.Y] * 2 - _cy;
        var _rz = _p[i + DPT.Z] - _cz;
        _p[@ i + DPT.VX] = _ay * _rz - _az * _ry;
        _p[@ i + DPT.VY] = (_az * _rx - _ax * _rz) * 0.5;   // ground y is halved on screen
        _p[@ i + DPT.VZ] = _ax * _ry - _ay * _rx;
    }
    _d.still = 0;
}

/// Advance the simulation. `_basez` is how high the body's ANCHOR currently is.
///
/// There is no relative gravity while the anchor is airborne, and that is not a shortcut: a
/// body in free fall and its own arm fall at the same rate, so in the body's frame the arm does
/// not sag at all -- it only swings, from the tumble. Applying gravity twice is what makes a
/// thrown ragdoll look like it is being poured out of a bucket.
function anim_doll_step(_d, _dt, _basez) {
    var _p = _d.p, _n = array_length(_p);
    if (_n == 0) return;
    _dt = min(_dt, 1 / 20);                     // a long frame must not blow the solver up
    if (_dt <= 0) return;

    // Settled bodies stop costing anything. Speed, not travel, so it does not depend on how
    // long the frame happened to be -- and it wakes the moment anything disturbs it.
    var _sp = 0;
    for (var i = 0; i < _n; i += DPT.SIZE) {
        _sp += abs(_p[i + DPT.VX]) + abs(_p[i + DPT.VY]) + abs(_p[i + DPT.VZ]);
    }
    var _rest_z = (_basez <= 0.5);
    if (_sp < DOLL_STILL && _rest_z) {
        _d.still = min(_d.still + _dt, 1);
        if (_d.still >= DOLL_STILL_T) {
            // Settled for good: park every point exactly where it lies and stop. Leaving a
            // trickle of velocity in is what makes a heap of bodies creep across the grass.
            for (var i = 0; i < _n; i += DPT.SIZE) {
                _p[@ i + DPT.VX] = 0; _p[@ i + DPT.VY] = 0; _p[@ i + DPT.VZ] = 0;
            }
            return;
        }
    } else {
        _d.still = 0;
    }

    var _acc   = _rest_z ? -DOLL_GRAV * _dt : 0;
    var _floor = -_basez;                       // the real floor, in this body's own frame
    var _air   = power(DOLL_DAMP, _dt);

    // PREDICT. Where each point would go if nothing were holding it.
    static _ox = []; static _oy = []; static _oz = [];
    var _cnt = _n div DPT.SIZE;
    if (array_length(_ox) < _cnt) {         // grow only: every downed body calls this every frame
        array_resize(_ox, _cnt); array_resize(_oy, _cnt); array_resize(_oz, _cnt);
    }
    var k = 0;
    for (var i = 0; i < _n; i += DPT.SIZE) {
        _ox[k] = _p[i + DPT.X]; _oy[k] = _p[i + DPT.Y]; _oz[k] = _p[i + DPT.Z];
        k++;
        _p[@ i + DPT.VZ] = (_p[i + DPT.VZ] + _acc) * _air;
        _p[@ i + DPT.VX] = _p[i + DPT.VX] * _air;
        _p[@ i + DPT.VY] = _p[i + DPT.VY] * _air;
        _p[@ i + DPT.X]  = _p[i + DPT.X] + _p[i + DPT.VX] * _dt;
        _p[@ i + DPT.Y]  = _p[i + DPT.Y] + _p[i + DPT.VY] * _dt;
        _p[@ i + DPT.Z]  = _p[i + DPT.Z] + _p[i + DPT.VZ] * _dt;
    }

    // SOLVE. Distances in GROUND space, because a bone is a real length and does not get
    // shorter because the camera is looking down the y axis.
    var _lk = _d.link, _nl = array_length(_lk);
    var _grip = power(DOLL_GRIP, _dt);
    repeat (global.q_doll) {
        for (var i = 0; i < _nl; i += 5) {
            var _a = _lk[i], _b = _lk[i + 1], _rest = _lk[i + 2], _st = _lk[i + 3];
            var _mn = _lk[i + 4];
            var _dx = _p[_b + DPT.X] - _p[_a + DPT.X];
            var _dy = (_p[_b + DPT.Y] - _p[_a + DPT.Y]) * 2;
            var _dz = _p[_b + DPT.Z] - _p[_a + DPT.Z];
            var _dl = sqrt(_dx * _dx + _dy * _dy + _dz * _dz);
            if (_dl < 0.0001) continue;
            if (_mn > 0) {
                // One-sided: a limit, not a strut. Silent unless it is folded past the stop.
                _rest *= _mn;
                if (_dl >= _rest) continue;
            }
            var _f = (_dl - _rest) / _dl * 0.5 * _st;
            var _cx = _dx * _f, _cy = _dy * _f * 0.5, _cz = _dz * _f;
            _p[@ _a + DPT.X] = _p[_a + DPT.X] + _cx;
            _p[@ _a + DPT.Y] = _p[_a + DPT.Y] + _cy;
            _p[@ _a + DPT.Z] = _p[_a + DPT.Z] + _cz;
            _p[@ _b + DPT.X] = _p[_b + DPT.X] - _cx;
            _p[@ _b + DPT.Y] = _p[_b + DPT.Y] - _cy;
            _p[@ _b + DPT.Z] = _p[_b + DPT.Z] - _cz;
        }
        // Inside the loop, so a constraint can never push a limb through the floor and leave
        // it there for a frame.
        for (var i = 0; i < _n; i += DPT.SIZE) {
            if (_p[i + DPT.Z] < _floor) _p[@ i + DPT.Z] = _floor;
        }
    }

    // READ THE VELOCITY BACK off how far each point actually got. This is what makes the body
    // behave as one object: a limb stopped by the torso loses its speed to the torso, and a
    // limb stopped by the ground loses it to the ground, without either being a special case.
    var _inv = 1 / _dt;
    k = 0;
    for (var i = 0; i < _n; i += DPT.SIZE) {
        _p[@ i + DPT.VX] = (_p[i + DPT.X] - _ox[k]) * _inv;
        _p[@ i + DPT.VY] = (_p[i + DPT.Y] - _oy[k]) * _inv;
        _p[@ i + DPT.VZ] = (_p[i + DPT.Z] - _oz[k]) * _inv;
        k++;
        // Dragging on the floor scrubs off sideways speed fast. Without this a body keeps the
        // speed it landed with and slithers away across the grass.
        if (_p[i + DPT.Z] <= _floor + 0.01) {
            _p[@ i + DPT.VX] = _p[i + DPT.VX] * _grip;
            _p[@ i + DPT.VY] = _p[i + DPT.VY] * _grip;
            if (_p[i + DPT.VZ] < 0) _p[@ i + DPT.VZ] = 0;   // a limb is not a ball: no bounce
        }
    }
}

/// Drag the simulation back onto a real pose, so a body can get up. Called AFTER the step, so
/// the velocities have already been read off this frame's motion and the gathering does not
/// register as the body throwing itself into shape.
function anim_doll_pull(_d, _rig, _clip, _play, _x, _y, _dir, _look, _w) {
    static _cap = [];
    array_resize(_cap, 0);
    var _parts = anim_build(anim_scratch(), _rig, _clip, _play, _x, _y, _dir, _look, false,
                            undefined, _cap);
    var _p = _d.p, _b = _d.bone;
    var _n = array_length(_cap);
    for (var j = 0; j < _n; j++) {
        var _e = _cap[j];
        if (_e.k > 1) continue;
        // Keyed by chain and bone, NOT by position in the list: which end of a chain is emitted
        // first flips with the facing, and the body may well have turned since the hit.
        var _t = _d.bkey[$ string(_e.c) + "_" + string(_e.i)];
        if (_t == undefined) continue;
        var _o = j * PART.SIZE;
        anim_doll_place(_p, _b[_t + DBONE.A],
                        _parts[_o + PART.X] - _x, 0, _y - _parts[_o + PART.Y], _w);
        if (_e.k == 0) {
            var _la = _parts[_o + PART.ANG] + 90;
            anim_doll_place(_p, _b[_t + DBONE.B],
                            _parts[_o + PART.X] + lengthdir_x(DOLL_LEVER, _la) - _x, 0,
                            _y - (_parts[_o + PART.Y] + lengthdir_y(DOLL_LEVER, _la)), _w);
        } else {
            anim_doll_place(_p, _b[_t + DBONE.B], _e.nx - _x, 0, _y - _e.ny, _w);
        }
    }
    _d.still = 0;
}

function anim_doll_place(_p, _i, _tx, _ty, _tz, _w) {
    _p[@ _i + DPT.X] = _p[_i + DPT.X] + (_tx - _p[_i + DPT.X]) * _w;
    _p[@ _i + DPT.Y] = _p[_i + DPT.Y] + (_ty - _p[_i + DPT.Y]) * _w;
    _p[@ _i + DPT.Z] = _p[_i + DPT.Z] + (_tz - _p[_i + DPT.Z]) * _w;
    // The pose is where it is being PUT, not somewhere it is flying to: bleed the simulated
    // speed away as it takes over, or the body arrives upright and keeps going.
    var _k = 1 - _w;
    _p[@ _i + DPT.VX] = _p[_i + DPT.VX] * _k;
    _p[@ _i + DPT.VY] = _p[_i + DPT.VY] * _k;
    _p[@ _i + DPT.VZ] = _p[_i + DPT.VZ] * _k;
}

/// Turn the simulated points back into a draw list, in the same layout anim_build produces --
/// so everything downstream (sorting, the light sheen, the silhouette card) treats a ragdoll
/// exactly like a posed character and none of it needs to know the difference.
function anim_doll_build(_d, _x, _y, _out) {
    var _p = _d.p, _b = _d.bone, _nb = array_length(_b);
    for (var i = 0; i < _nb; i += DBONE.SIZE) {
        var _a = _b[i + DBONE.A], _c = _b[i + DBONE.B];
        var _ax = _x + _p[_a + DPT.X], _ay = _y + _p[_a + DPT.Y] - _p[_a + DPT.Z];
        var _bx = _x + _p[_c + DPT.X], _by = _y + _p[_c + DPT.Y] - _p[_c + DPT.Z];
        var _ang = point_direction(_ax, _ay, _bx, _by);
        var _sc  = _b[i + DBONE.SC];
        var _xs, _da;
        if (_b[i + DBONE.KIND] == 0) {
            _xs = _sc;  _da = -90;              // the lever was built 90 off the sprite's angle
        } else {
            _xs = (_sc != 0) ? point_distance(_ax, _ay, _bx, _by) / _sc : 1;
            _da = 0;
        }
        // Spread out on the floor, a body's own parts need sorting against each other: the arm
        // nearer the camera has to draw over the chest. Ground row does that, and while the
        // body is upright every part shares one row, so this changes nothing until it matters.
        array_push(_out, _b[i + DBONE.DEPTH] - _p[_a + DPT.Y] * 2,
                   _b[i + DBONE.SPR], _b[i + DBONE.SUB], _ax, _ay, _ang + _da,
                   _xs, _b[i + DBONE.YS], _b[i + DBONE.COL], _b[i + DBONE.ALPHA]);
    }
    var _nf = array_length(_d.fol);
    for (var i = 0; i < _nf; i++) {
        var _f = _d.fol[i];
        // Bones were emitted in order, so bone n is part n -- but the two strides are counted
        // in different units and only happen to be the same size today.
        var _o = (_f.b div DBONE.SIZE) * PART.SIZE;
        var _ra = _out[_o + PART.ANG];
        var _cc = dcos(_ra), _ss = dsin(_ra);
        array_push(_out, _out[_o + PART.DEPTH] + _f.dd, _f.spr, _f.sub,
                   _out[_o + PART.X] + _f.lx * _cc + _f.ly * _ss,
                   _out[_o + PART.Y] - _f.lx * _ss + _f.ly * _cc,
                   _ra + _f.da, _f.xs, _f.ys, _f.col, _f.alpha);
    }
    var _ng = array_length(_d.blob);
    if (_ng > 0) {
        // Recomputed, never taken from the capture: a canned body's blob was baked at the
        // origin under whatever lights existed then, and would be frozen at that strength and
        // that offset wherever the body actually came down.
        var _c = global.q_blobshadow
               ? anim_blob_cheap(_x, _y, _d.blob[0].spr) : undefined;
        var _ba  = (_c == undefined) ? 1 : _c.a;
        var _bx  = (_c == undefined) ? 0 : _c.dx;
        var _by  = (_c == undefined) ? 0 : _c.dy;
        var _bkx = (_c == undefined) ? 1 : _c.kx;
        var _bky = (_c == undefined) ? 1 : _c.ky;
        var _bag = (_c == undefined) ? 0 : _c.ang;
        for (var i = 0; i < _ng; i++) {
            var _g = _d.blob[i];
            array_push(_out, 1000000, _g.spr, _g.sub, _x + _bx, _y + _g.dy + _by, _bag,
                       _g.sx * _bkx, _g.sy * _bky, _g.col, _g.alpha * _ba);
        }
    }
    return _out;
}

/// Draw a ragdoll where anim_draw would have drawn the character.
function anim_doll_paint(_d, _x, _y) {
    var _o = anim_doll_build(_d, _x, _y, anim_scratch());
    anim_paint(_o);
    anim_light_sheen(_o, _x, _y);
}

/// CANNED KNOCKDOWNS, for the phone tier.
///
/// Simulating a hundred bodies is not expensive because any one of them is; it is expensive
/// because there are a hundred. So on the lowest tier the simulation is run ONCE, at boot, for a
/// handful of knockdowns -- three pitching forward, three going over backwards -- and each of
/// them is kept as two snapshots: the shape it had in the air, and the shape it settled into.
/// A body that gets hit then just picks one and plays those two poses, and the solver never runs
/// again for the rest of the session.
///
/// The trade is honest and visible: six outcomes instead of one per body, always in the same
/// screen orientation, so a crowd knocked down together lands in repeating shapes. What survives
/// is that they still fall LIMP and land splayed, which is the thing that reads.
function anim_doll_bake(_rig, _look, _each) {
    var _lib = { tmpl: undefined, air: [], flr: [], seq: [], arm: [] };
    // Baked at full solver quality whatever tier asked for it -- these are computed once ever,
    // and a rubbery snapshot would be frozen in for the whole session.
    var _q = global.q_doll;
    global.q_doll = 3;
    for (var v = 0; v < _each * 2; v++) {
        var _d = anim_doll_make(_rig, _rig.gait.idle, v * 3, 0, 0, 0, _look);
        if (_lib.tmpl == undefined) _lib.tmpl = _d;
        // First half goes over BACKWARDS, and demo_skeleton_down draws from that half when the
        // blast was in front. Same sign convention as the live kick -- see anim_doll_kick.
        anim_doll_kick(_d, v * 61, degtorad(320 + v * 70), (v < _each) ? 1 : -1, 0.16);
        // In the air: the floor put far below, so nothing touches down early.
        repeat (10) anim_doll_step(_d, 1 / 60, 400);
        array_push(_lib.air, anim_doll_snapshot(_d));
        // ...and then let it fall, recording the whole ARRIVAL rather than just where it ended
        // up. A body dropped as one rigid shape lands like a felled log; what sells the weight
        // is the half second afterwards, when the limbs are still catching up with the torso.
        var _seq = [], _arm = [];
        repeat (DOLL_SETTLE_FRAMES) {
            repeat (2) anim_doll_step(_d, 1 / 60, 0);      // one recorded frame per 1/30s
            array_push(_seq, anim_doll_snapshot(_d));
            array_push(_arm, anim_doll_arm_snapshot(_d));
        }
        // Then run it out to a real rest, so the pose it holds afterwards is settled and not
        // wherever the recording happened to stop.
        var _t = 0;
        while (_t < 240 && _d.still < DOLL_STILL_T) { anim_doll_step(_d, 1 / 60, 0); _t++; }
        _seq[array_length(_seq) - 1] = anim_doll_snapshot(_d);
        _arm[array_length(_arm) - 1] = anim_doll_arm_snapshot(_d);
        array_push(_lib.flr, anim_doll_snapshot(_d));
        array_push(_lib.seq, _seq);
        array_push(_lib.arm, _arm);
    }
    global.q_doll = _q;
    return _lib;
}

function anim_doll_snapshot(_d) {
    var _n = array_length(_d.p), _o = array_create(_n);
    array_copy(_o, 0, _d.p, 0, _n);
    return _o;
}

/// How many frames of the landing are recorded, at 1/30s each. Ten is a third of a second --
/// long enough for an arm to swing over and drop, short enough that the body is visibly at rest
/// well before it starts getting up.
#macro DOLL_SETTLE_FRAMES 10

/// Just the arms, and RELATIVE TO THE SHOULDER. Stored apart from the body so a knockdown can
/// borrow its arm movement from a different baked fall than its body came from -- six landings
/// times three arm flops reads as far more variety than six of anything.
function anim_doll_arm_snapshot(_d) {
    var _p = _d.p, _a = _d.arms, _o = [];
    for (var g = 0; g < array_length(_a); g++) {
        var _r = _a[g].root, _pt = _a[g].pts;
        for (var k = 0; k < array_length(_pt); k++) {
            var _i = _pt[k];
            array_push(_o, _p[_i + DPT.X] - _p[_r + DPT.X],
                           _p[_i + DPT.Y] - _p[_r + DPT.Y],
                           _p[_i + DPT.Z] - _p[_r + DPT.Z]);
        }
    }
    return _o;
}

/// One body's copy of a baked knockdown. The bones, the followers and the joint names are SHARED
/// with the template -- every skeleton has the same rig and the same palette, so there is exactly
/// one of those in the room however many bodies are on the floor. Only the moving points are per
/// body, because the landing blend writes to them.
function anim_doll_canned(_lib, _v, _av) {
    var _t = _lib.tmpl;
    return {
        p: anim_doll_snapshot({ p: _lib.air[_v] }),
        bone: _t.bone, link: _t.link, fol: _t.fol, blob: _t.blob,
        key: _t.key, bkey: _t.bkey, arms: _t.arms, still: 1,
        flr: _lib.flr[_v], seq: _lib.seq[_v], arm: _lib.arm[_av], land: 0
    };
}

/// Play a canned body's landing: the recorded arrival for its own fall, with somebody else's
/// arms grafted on at the shoulder. Runs for a third of a second and then costs nothing at all
/// for the rest of the time the body lies there.
function anim_doll_land(_d, _dt) {
    if (_d.land >= 1) return;
    var _seq = _d.seq, _n = array_length(_seq);
    _d.land = min(1, _d.land + _dt * 30 / max(1, _n - 1));

    var _f  = _d.land * (_n - 1);
    var _i0 = clamp(floor(_f), 0, _n - 1);
    var _i1 = min(_i0 + 1, _n - 1);
    var _w  = _f - _i0;
    var _a0 = _seq[_i0], _a1 = _seq[_i1];
    var _p  = _d.p, _np = array_length(_p);
    for (var i = 0; i < _np; i++) _p[@ i] = _a0[i] + (_a1[i] - _a0[i]) * _w;

    // ...and then the arms, placed back onto THIS body's shoulders. Written after the body so
    // it wins: the shoulder has just been positioned by the frame above, which is exactly the
    // anchor these offsets were measured from.
    var _arm = _d.arm;
    if (_arm == undefined) return;
    var _b0 = _arm[_i0], _b1 = _arm[_i1];
    var _g = _d.arms, _k = 0;
    for (var q = 0; q < array_length(_g); q++) {
        var _r = _g[q].root, _pt = _g[q].pts;
        var _rx = _p[_r + DPT.X], _ry = _p[_r + DPT.Y], _rz = _p[_r + DPT.Z];
        for (var m = 0; m < array_length(_pt); m++) {
            var _i = _pt[m];
            _p[@ _i + DPT.X] = _rx + _b0[_k]     + (_b1[_k]     - _b0[_k])     * _w;
            _p[@ _i + DPT.Y] = _ry + _b0[_k + 1] + (_b1[_k + 1] - _b0[_k + 1]) * _w;
            _p[@ _i + DPT.Z] = _rz + _b0[_k + 2] + (_b1[_k + 2] - _b0[_k + 2]) * _w;
            _k += 3;
        }
    }
}

/// A ragdoll's silhouette, ready to be projected into every light that wants it -- the same
/// contract as anim_shadow_prep_char, so a downed body throws the shadow it is actually in
/// rather than the shadow of the pose it was in when it was hit.
/// `_x, _y` is the GROUND point, not where the body is drawn -- exactly as anim_shadow_prep_char
/// takes it, and for the same reason: the card and the projection have to be registered to the
/// same origin, and the shadow belongs on the floor under the body rather than flying with it.
/// A ragdoll's points are offsets from its own origin, so anchoring here lays the shape it is
/// currently in flat on the ground whatever height the body has reached.
function anim_doll_shadow_prep(_d, _rig, _x, _y, _dir, _cast_surf, _cast_cam) {
    var _g = anim_shadow_ground(_rig, _dir, false);
    var _p = anim_doll_build(_d, _x, _y, anim_scratch());
    if (!anim_shadow_card(_p, _x, _y, _cast_surf, _cast_cam)) return undefined;
    return { g: _g, x: _x, y: _y, minw: 0 };
}
