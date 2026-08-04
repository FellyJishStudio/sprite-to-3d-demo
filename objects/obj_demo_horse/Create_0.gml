rig       = global.rigs[$ "horse"];
look      = look_plain();     // no appearance slots: every chain falls through to "plain"
clip      = rig.gait.idle;
play      = 0;
rider     = noone;
direction = 180;
face      = 180;              // where it wants to point; `direction` eases toward it

// The narrowest this horse's cast shadow may come out, in pixels -- with or without a
// rider, against whichever lamp. A property of THE HORSE because the problem is the
// horse's: its long body collapses to a streak when it lines up with a light, where a
// humanoid never gets thin enough to matter, so casters without this field are never
// widened at all (anim_shadow_pair passes it through; anim_shadow_char passes zero).
// 16.5 is the value settled by eye on the live dial before the dials were retired.
shadow_minw = 16.5;
