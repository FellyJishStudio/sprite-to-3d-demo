/// APPEARANCE
///
/// Ported from tools/anim_pipeline/editor/js/appearance.js (itself a port of
/// scr_appearance.gml). The game uses two paths:
///
///   * body / arms / legs -> a plain multiply tint. The demo does exactly that.
///   * head               -> a 4-colour palette swap in a shader. The demo approximates it
///                           with a single multiply that maps the head sprite's own base
///                           colour onto the chosen skin. On the default skin that is
///                           EXACTLY identity, which is what scr_appearance_is_lightest_skin
///                           does; on darker skins the two shadow tones scale linearly
///                           instead of following the chained merges below. That is the one
///                           visible difference, and it buys us not shipping a shader.
///
/// The shade ramp is NOT a multiply and NOT a fixed offset: it is two chained linear merges,
/// first toward a fixed warm colour and then toward black.

/// Preset swatches (scr_appearance.gml:555-607).
function look_presets() {
    static _p = {
        skin  : [[251,175,93],[232,154,84],[204,132,76],[168,106,62],[130,82,50],[96,60,38],[70,44,28]],
        hair  : [[0,0,0],[60,40,24],[104,72,44],[158,52,34],[198,168,112],[224,193,120],[150,150,155],[205,205,205]],
        shirt : [[3,157,91],[180,60,55],[45,80,160],[200,170,60],[120,60,150],[230,230,230]],
        pants : [[19,77,125],[60,50,40],[40,40,45],[110,90,60],[150,40,40],[200,200,205]],
        eye   : [[0,174,240],[60,140,70],[120,80,40],[90,90,100],[140,60,150],[40,40,40]]
    };
    return _p;
}

function look_rgb(_c)  { return make_colour_rgb(_c[0], _c[1], _c[2]); }
function look_pick(_a)  { return _a[irandom(array_length(_a) - 1)]; }

/// The multiply that turns spr_head_base's base colour into the chosen skin.
///
/// This is needed ONLY for the head. Every other sprite that takes a skin or clothing colour
/// is a white (or grey) template, so a plain multiply by the colour gives the colour back --
/// which is what the client does, passing the raw skin_color to the hand
/// (scr_player_avatar.gml:257). spr_head_base is the exception: it already carries the
/// default skin, and the client repaints it with the palette-swap shader rather than a
/// blend. With no shader, the demo compensates here instead.
///
/// Only slot 0 of the destination palette is reachable through a blend, and slot 0 is the
/// chosen skin in both branches of the game's rule -- so the ramp above collapses to this.
/// On the default skin it is exactly identity (251 * 255 / 251 = 255 = c_white), which is
/// the passthrough scr_appearance_is_lightest_skin performs.
function look_head_tint(_skin) {
    static _src = [251, 175, 93];      // spr_head_base's own base colour, HEAD_SRC[0]
    return make_colour_rgb(min(255, _skin[0] * 255 / _src[0]),
                           min(255, _skin[1] * 255 / _src[1]),
                           min(255, _skin[2] * 255 / _src[2]));
}

/// A complete look. `undefined` in a slot hides every part that uses it -- that one
/// mechanism covers the sword toggle, the skeleton's missing hair and face, and the rider
/// losing its shadow to the horse.
///
/// The slots come from scr_player_avatar.gml:249-260, which colours the armatures
/// bone by bone: body(shirt) head(skin) arm(shirt, skin) leg(pants, pants). Which bone
/// takes which slot is in <rig>.demo.json, not here.
///
/// hair_spr picks one of the 13 hair silhouettes. They are drawn as solid black, so a
/// multiply tint cannot recolour them; the game lightens them through the 8-colour
/// appearance palette shader, which this demo does not ship. Hair colour therefore stays
/// black, which is the game's own default, and the shuffle varies the style instead.
function look_random() {
    var _p = look_presets();
    var _skin = look_pick(_p.skin);
    return {
        plain     : c_white,
        skin      : look_rgb(_skin),                 // white templates: hands
        headSkin  : look_head_tint(_skin),           // spr_head_base is pre-coloured
        shirt     : look_rgb(look_pick(_p.shirt)),
        pants     : look_rgb(look_pick(_p.pants)),
        hair      : look_rgb(look_pick(_p.hair)),
        face      : c_white,
        sword     : c_white,
        shadow    : c_white,
        mounted   : false,
        hair_spr  : asset_get_index("spr_hair_base_" + string(irandom_range(1, 13))),
        face_spr  : spr_head_default_face,
        sword_spr : spr_sword,
        shadow_spr: spr_player_shadow
    };
}

/// No new art: the same clothed humanoid rig, greyed out.
function look_skeleton() {
    var _g = make_colour_rgb(155, 158, 150);
    return { plain : _g, skin : _g, headSkin : _g, shirt : _g, pants : _g,
             hair : undefined, face : undefined, sword : undefined,
             shadow : c_white, mounted : false, shadow_spr : spr_player_shadow };
}

/// A rig with no appearance slots at all -- every chain falls through to "plain".
function look_plain() {
    return { plain : c_white, shadow : c_white, shadow_spr : spr_player_shadow };
}
