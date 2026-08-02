/// No new art: the clothed humanoid rig and the same three clips, greyed out.
rig       = global.rigs[$ "humanoid"];
look      = look_skeleton();
clip      = rig.gait.idle;
play      = irandom(200) / 20;   // desynchronise the crowd
direction = irandom(359);

// Flee state is latched rather than recomputed from distance alone -- see Step.
flee      = false;
flee_hold = 0;
