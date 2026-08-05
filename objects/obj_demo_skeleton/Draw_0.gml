// Off-camera skip, and ONLY when the controller has switched it on -- fun mode, or the
// THRONE_CHARCULL probe. See the note where global.cull_on is set: this demo deliberately
// poses and paints every instance every frame so the fps readout means something, and the
// exception exists for the case where the point is spectacle rather than measurement.
if (global.cull_on && (x < global.cull_x0 || x > global.cull_x1
                    || y < global.cull_y0 || y > global.cull_y1)) exit;

anim_draw(rig, clip, play, x, y, direction, look, false);
