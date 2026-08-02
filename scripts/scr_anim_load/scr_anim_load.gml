/// LOADING
///
/// Everything the runtime needs is pipeline output, read as data:
///
///   datafiles/rigs/<id>.rig.json     bone tree, chains, chainConfig offsets/scale, skins,
///                                    facingRule, subImageRule, isoTilt.  Copied verbatim
///                                    from throne-client/animation/rigs -- do not edit.
///   datafiles/rigs/<id>.demo.json    the two tables pose.js keeps in code rather than in
///                                    the rig: per-chain depth offsets, and which
///                                    appearance slot tints each chain.
///   datafiles/baked_sequences/*.bin  a baked clip, v3 (docs/animation-format.md).
///   datafiles/clips.json             the inventory: one entry per shipped clip, with the
///                                    rig it belongs to, its sample rate and its playback
///                                    mode. Emitted by the copy script in the same pass
///                                    that copies the .bin files, so the two cannot drift.
///                                    NOT the rig's own `sequences` array -- that lists all
///                                    28 humanoid clips in the source project, not the five
///                                    this demo ships.
///
/// If you ever feel like typing a bone name, an offset, a depth constant or an angle band
/// into GML, it belongs in one of those files instead.
///
/// Loading is also where every name is resolved to a number. After this runs, drawing a
/// character never hashes a string and never searches for anything.
///
/// ACQUISITION IS ASYNCHRONOUS, on every target. `buffer_load` does not exist on HTML5, and
/// branching on os_type would give us a path that only ever runs on one platform -- which is
/// how "works on Windows, broken on web" happens. So everything is fetched with
/// `buffer_load_async` into a path -> buffer map first, and the parsing below reads from
/// that map. The parsing itself is unchanged: same header reads, same UTF-8 name decode.
///
/// It runs in two stages because the file list is not known up front: fetch the manifest,
/// then fetch every rig and clip it names. obj_demo_controller owns the Async Save/Load
/// event that drives it and spawns the cast once `global.anim_ready` goes true.

/// Queue one included file. Completion lands in anim_async().
///
/// The buffer is PREALLOCATED, not grown. buffer_load_async writes straight into whatever it
/// is handed and does not resize it, so a 1-byte grow buffer silently truncates every file to
/// nothing -- which surfaces as `json_parse: unexpected end of data` rather than as a load
/// error. Nothing shipped here is close to the cap (the biggest clip is ~80KB) and every
/// buffer is freed once parsing is done.
#macro ANIM_FILE_MAX 1048576

function anim_fetch(_path) {
    var _b  = buffer_create(ANIM_FILE_MAX, buffer_fixed, 1);
    var _id = buffer_load_async(_b, _path, 0, -1);
    global.anim_jobs[$ string(_id)] = { path : _path, buf : _b };
    global.anim_left++;
}

/// Read an already-fetched file as a UTF-8 string.
///
/// buffer_create zero-fills and the buffer is larger than the file, so the text is already
/// NUL-terminated: buffer_string stops exactly at the end of the data and decodes UTF-8,
/// where buffer_text would run on into the padding.
function anim_text(_path) {
    var _b = global.anim_files[$ _path];
    buffer_seek(_b, buffer_seek_start, 0);
    return buffer_read(_b, buffer_string);
}

/// Turn one entry of the demo depth table into fixed numeric fields. See scr_anim_depth.
function anim_depth_entry(_e) {
    if (_e == undefined) _e = {};
    var _base = _e[$ "base"];
    var _leg  = _e[$ "leg"];
    return {
        base     : (_base == "front") ? 1 : ((_base == "back") ? 2 : 0),
        down     : _e[$ "down"]   ?? 0,
        up       : _e[$ "up"]     ?? 0,
        mirror   : _e[$ "mirror"] ?? 0,
        dirDep   : _e[$ "dirDep"] ?? 0,
        leg      : (_leg == "right") ? 1 : ((_leg == "left") ? 0 : -1),
        clamped  : (_e[$ "frontOfHead"] != undefined),
        clampOff : _e[$ "frontOfHead"] ?? 0
    };
}

/// Load a rig and flatten it into the form the renderer walks: an array of chains, each
/// holding its bones' resolved art, its offsets and its depth rule.
///
/// The rig's `pivot` values were extracted from the sprites' own origins, so nothing here
/// needs to carry a pivot -- draw_sprite_ext already draws about the sprite origin.
function anim_rig_load(_id) {
    var _r    = json_parse(anim_text("rigs/" + _id + ".rig.json"));
    var _demo = json_parse(anim_text("rigs/" + _id + ".demo.json"));

    var _skins = _r[$ "skins"];
    var _skin  = is_struct(_skins) ? _skins[$ _r.defaultSkin] : undefined;

    var _meta = {};       // bone id -> draw info
    _r.boneNames = [];    // slot -> the name the .bin indexes by
    // Tint slots become indices here: the renderer resolves each slot's colour once per
    // character per frame instead of hashing a string once per BONE per frame. The list
    // is tiny (five names on the humanoid, one on an animal).
    _r.tintNames = [];
    var _tidx = {};       // name -> index, load-time only
    for (var i = 0; i < array_length(_r.bones); i++) {
        var _b = _r.bones[i];
        var _s = is_struct(_skin) ? _skin[$ _b.id] : undefined;   // skin overrides art
        if (_s == undefined) _s = _b;
        // Every sprite is resolved by NAME, so if a target ever strips asset names (or
        // "remove unused assets" drops one nothing references directly) the whole character
        // silently draws nothing. Say which sprite instead.
        var _spr = asset_get_index(_s.sprite);
        if (_spr < 0 && global.anim_error == "") global.anim_error = "sprite " + string(_s.sprite);
        var _tn = _demo.tint[$ _b.id] ?? "plain";     // per BONE: the hands are not sleeve
        var _ti = _tidx[$ _tn];
        if (_ti == undefined) {
            _ti = array_length(_r.tintNames);
            _tidx[$ _tn] = _ti;
            array_push(_r.tintNames, _tn);
        }
        _meta[$ _b.id] = {
            name    : _b.name,
            slot    : i,                         // index into a clip's row table
            sprite  : _spr,
            frames  : _s.spriteFrames,
            len     : _s.naturalLength,
            tintIdx : _ti,
            // Rule membership, resolved below once the rule lists exist. The renderer
            // reads these flags per bone per frame; the name scans happen only here.
            iso_cls    : 0,       // 2 = front half (full tilt), 1 = spine (half), 0 = rest
            iso_flat   : false,   // exempt from the facing-down -1 step
            steep_band : false    // sub-image follows the steep band, not facing_down
        };
        _r.boneNames[i] = _b.name;
    }

    _r.gait = _demo.gait;                // which clip each movement state plays
    // NB: `mount` is NOT read from the demo file -- it is part of the rig itself
    // (horse.rig.json), emitted by rig_extract and editable in the editor's rig panel.

    _r.chain     = [];
    // Named anchor chains, from the demo file: `head` is what hair, face and the sword's
    // depth clamp hang off, `weapon` is the chain whose synthesized tip holds an item.
    var _anchor = _demo[$ "anchor"] ?? {};
    var _role   = _demo[$ "role"] ?? {};
    _r.headChain = -1;
    _r.armChain  = -1;
    for (var i = 0; i < array_length(_r.chains); i++) {
        var _c   = _r.chains[i];
        var _cfg = _r.chainConfig[$ _c.id];
        var _bones = [];
        for (var j = 0; j < array_length(_c.bones); j++) _bones[j] = _meta[$ _c.bones[j]];
        var _side = _demo.side[$ _c.id];

        _r.chain[i] = {
            id    : _c.id,
            bones : _bones,
            pos   : _cfg.posOffset,
            arm   : _cfg.armOffset,
            // Some lateral offsets vary with facing rather than being constant --
            // the left arm is -4/-5/-3 (scr_player_avatar.gml:748-749).
            armBy : _cfg[$ "armOffsetXByFacing"],
            scale : _cfg.scale,
            side  : (_side == "right") ? 1 : ((_side == "left") ? 0 : -1),
            // arm / leg / head / body -- which mount.riderDepth offset applies when riding
            role  : _role[$ _c.id] ?? "",
            depth : anim_depth_entry(_demo.depth[$ _c.id])
        };
        if (_c.id == _anchor[$ "head"])   _r.headChain = i;
        if (_c.id == _anchor[$ "weapon"]) _r.armChain  = i;
    }

    // Null in the rig JSON means "this rig has no such rule".
    _r.iso   = is_struct(_r.isoTilt)       ? _r.isoTilt       : undefined;
    _r.steep = is_struct(_r.subImageRule)  ? _r.subImageRule  : undefined;

    // The band of skewed direction that counts as facing the camera. The rigs disagree:
    // the humanoid is (30,150), an animal is the whole upper half.
    _r.faceBand = (_r.facingRule == "wide") ? [0, 180] : [30, 150];

    // Corrections to the rig, from the demo file so the rig copy stays untouched.
    if (_r.iso != undefined) _r.iso.flat = is_struct(_demo[$ "iso"])
        ? (_demo.iso[$ "flat"] ?? []) : [];

    // Resolve the name-list rules into the per-bone flags declared above. Bones that share
    // a name (duplicate source bones) all take the rule, exactly as the name scan did.
    var _sband = (_r.steep != undefined) ? _r.steep.steepBand : undefined;
    for (var i = 0; i < array_length(_r.chain); i++) {
        var _cb = _r.chain[i].bones;
        for (var j = 0; j < array_length(_cb); j++) {
            var _m2 = _cb[j];
            if (_r.iso != undefined) {
                _m2.iso_cls  = array_contains(_r.iso.front, _m2.name) ? 2
                             : (array_contains(_r.iso.half,  _m2.name) ? 1 : 0);
                _m2.iso_flat = array_contains(_r.iso.flat, _m2.name);
            }
            if (_sband != undefined) _m2.steep_band = array_contains(_sband, _m2.name);
        }
    }

    // Ground shadows and head attachments, each pinned to a drawn chain (or, for a shadow
    // with a null chain, to the instance origin). Chain ids are resolved to indices here so
    // the renderer never compares a string.
    _r.shadow = _demo[$ "shadow"] ?? [];
    _r.attach = _demo[$ "attach"] ?? [];
    var _pinned = [_r.shadow, _r.attach];
    for (var k = 0; k < 2; k++) {
        var _list = _pinned[k];
        for (var i = 0; i < array_length(_list); i++) {
            var _s2 = _list[i];
            _s2.at = -1;
            for (var j = 0; j < array_length(_r.chain); j++) {
                if (_r.chain[j].id == _s2[$ "chain"]) _s2.at = j;
            }
        }
    }

    global.rigs[$ _id] = _r;
    return _r;
}

/// Load one baked clip.
///
///   u32 totalFrames | u32 boneCount | f32 playbackSpeed | f32 sequenceLength
///   boneCount x (u32 byteLength + UTF-8 name)
///   f32[totalFrames * boneCount * 6]
///
/// The payload is copied straight into a flat GML array in the layout the renderer wants.
/// It could be read from the buffer instead, but `buffer_peek` is a runtime call and array
/// indexing is a VM opcode: on this data that difference is worth about 3x.
function anim_clip_load(_entry) {
    var _rig = global.rigs[$ _entry.rig];
    var _b   = global.anim_files[$ "baked_sequences/" + _entry.id + ".bin"];
    buffer_seek(_b, buffer_seek_start, 0);

    // Read the header into locals first: struct literals do not guarantee that their
    // members are evaluated in source order, and these reads must happen in file order.
    var _frames = buffer_read(_b, buffer_u32);
    var _bones  = buffer_read(_b, buffer_u32);
    var _speed  = buffer_read(_b, buffer_f32);
    buffer_seek(_b, buffer_seek_relative, 4);    // sequenceLength: skipped, not stored --
                                                 // the manifest carries the sample rate

    // Bone names are UTF-8. Decoding them byte-per-codepoint (Latin-1) is the bug the main
    // game still has in load_baked_sequences.gml:99, so decode them through a buffer.
    var _row_of = {};
    for (var i = 0; i < _bones; i++) {
        var _len = buffer_read(_b, buffer_u32);
        var _t   = buffer_create(_len + 1, buffer_fixed, 1);
        buffer_copy(_b, buffer_tell(_b), _len, _t, 0);
        buffer_poke(_t, _len, buffer_u8, 0);
        buffer_seek(_t, buffer_seek_start, 0);
        _row_of[$ buffer_read(_t, buffer_string)] = i;
        buffer_delete(_t);
        buffer_seek(_b, buffer_seek_relative, _len);
    }

    // rig bone slot -> index of that bone's first float within a frame. Resolved here so
    // that drawing is pure arithmetic.
    var _row = array_create(array_length(_rig.boneNames));
    for (var i = 0; i < array_length(_rig.boneNames); i++) {
        _row[i] = _row_of[$ _rig.boneNames[i]] * 6;
    }

    var _count = _frames * _bones * 6;
    var _data  = array_create(_count);
    for (var i = 0; i < _count; i++) _data[i] = buffer_read(_b, buffer_f32);

    var _c = {
        data   : _data,
        frames : _frames,
        speed  : _speed,
        rate   : _entry.sampleRate,      // v3 drops it; the manifest carries the real one
        stride : _bones * 6,
        row    : _row
    };

    global.clips[$ _entry.id] = _c;
    return _c;
}

/// Start loading. Returns immediately; watch `global.anim_ready`.
function anim_boot() {
    global.rigs       = {};
    global.clips      = {};
    global.anim_dump  = false;
    global.anim_ready = false;
    global.anim_files = {};      // path -> loaded buffer
    global.anim_jobs  = {};      // async request id -> { path, buf }
    global.anim_left  = 0;       // outstanding requests in this stage
    global.anim_stage = 0;
    global.anim_error = "";      // set to the path of the first file that fails to load
    anim_fetch("clips.json");
}

/// Call from the Async Save/Load event. Returns true once everything is parsed.
function anim_async() {
    var _key = string(async_load[? "id"]);
    var _job = global.anim_jobs[$ _key];
    if (_job == undefined) return false;                 // not one of ours
    variable_struct_remove(global.anim_jobs, _key);

    if (async_load[? "status"] < 0) {
        // Name the file and stop, rather than letting an empty buffer reach json_parse and
        // surface as a confusing "unexpected end of data".
        global.anim_error = _job.path;
        show_debug_message("anim: FAILED to load " + _job.path
            + " (status " + string(async_load[? "status"]) + ")");
        return false;
    }
    global.anim_files[$ _job.path] = _job.buf;
    global.anim_left--;
    if (global.anim_left > 0) return false;              // stage still in flight

    if (global.anim_stage == 0) {
        // The manifest names every rig and clip; queue them all as stage two.
        global.anim_stage = 1;
        var _m = json_parse(anim_text("clips.json"));
        global.anim_manifest = _m;
        var _rigs = {};
        for (var i = 0; i < array_length(_m); i++) {
            var _e = _m[i];
            if (_rigs[$ _e.rig] == undefined) {
                _rigs[$ _e.rig] = true;
                anim_fetch("rigs/" + _e.rig + ".rig.json");
                anim_fetch("rigs/" + _e.rig + ".demo.json");
            }
            anim_fetch("baked_sequences/" + _e.id + ".bin");
        }
        return false;
    }

    // Everything is in memory -- parse exactly as the synchronous version did.
    var _m = global.anim_manifest;
    for (var i = 0; i < array_length(_m); i++) {
        var _entry = _m[i];
        if (global.rigs[$ _entry.rig] == undefined) anim_rig_load(_entry.rig);
        anim_clip_load(_entry);
    }
    // Gait names -> clip structs, now that every clip exists. An instance's `clip` is a
    // struct from here on: Step reads clip.speed and Draw hands it straight to anim_build,
    // with no per-frame global.clips hash on either path.
    var _rn = variable_struct_get_names(global.rigs);
    for (var i = 0; i < array_length(_rn); i++) {
        var _g  = global.rigs[$ _rn[i]].gait;
        var _gn = variable_struct_get_names(_g);
        for (var j = 0; j < array_length(_gn); j++) _g[$ _gn[j]] = global.clips[$ _g[$ _gn[j]]];
    }
    var _names = variable_struct_get_names(global.anim_files);
    for (var i = 0; i < array_length(_names); i++) buffer_delete(global.anim_files[$ _names[i]]);
    global.anim_files = {};
    global.anim_ready = true;
    return true;
}
