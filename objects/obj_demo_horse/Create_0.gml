rig       = global.rigs[$ "horse"];
look      = look_plain();     // no appearance slots: every chain falls through to "plain"
clip      = rig.gait.idle;
play      = 0;
rider     = noone;
direction = 180;
face      = 180;              // where it wants to point; `direction` eases toward it
