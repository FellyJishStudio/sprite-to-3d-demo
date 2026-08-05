// Off-camera skip, and ONLY when the controller has switched it on -- fun mode, or the
// THRONE_CHARCULL probe. See the note where global.cull_on is set: this demo deliberately
// poses and paints every instance every frame so the fps readout means something, and the
// exception exists for the case where the point is spectacle rather than measurement.
if (global.cull_on && (x < global.cull_x0 || x > global.cull_x1
                    || y < global.cull_y0 || y > global.cull_y1)) exit;

// Lifted by `hit_z` while it is in the air. The POSITION stays on the floor -- height is
// straight screen-y here, the one axis the isometric projection does not halve -- so the
// controller casts its shadow from the ground point underneath it and the shadow stays put
// while the body arcs over it.
// A downed body is drawn from the SIMULATION, not from a clip: its limbs are wherever the fall
// left them. Everything else about it -- where it is, how deep it sorts, what light reaches it
// -- still comes off the anchor, so nothing downstream has to know.
if (doll != undefined) anim_doll_paint(doll, x, y - hit_z);
else anim_draw(rig, clip, play, x, y, direction, look, false);
