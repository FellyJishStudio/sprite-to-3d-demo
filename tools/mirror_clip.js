// Mirror a baked v3 clip front-to-back, so a fall that goes one way goes the other.
//
// v3 layout (docs/animation-format.md):
//   u32 totalFrames, u32 boneCount, f32 playbackSpeed, f32 sequenceLength,
//   per bone: u32 byteLen + UTF-8 name,
//   f32[frames * bones * 6]  components relX, relY, angle, xscale, yscale, alpha
//
// Positions are already composed to root-relative world space, so a reflection about the
// character's vertical axis is just: negate relX, and reflect the angle about that same
// axis (a -> 180 - a). relY is untouched -- the body still falls DOWN, it just goes over
// the other side. Scales and alpha carry no handedness.
'use strict';
const fs = require('fs');

const [, , inPath, outPath] = process.argv;
const buf = fs.readFileSync(inPath);

let o = 0;
const frames = buf.readUInt32LE(o); o += 4;
const bones  = buf.readUInt32LE(o); o += 4;
o += 4; // playbackSpeed
o += 4; // sequenceLength
for (let b = 0; b < bones; b++) {
    const len = buf.readUInt32LE(o); o += 4 + len;
}
const payload = o;
const need = payload + frames * bones * 6 * 4;
if (need !== buf.length) {
    console.error(`size mismatch: header implies ${need}, file is ${buf.length}`);
    process.exit(1);
}

const out = Buffer.from(buf);           // copy; header and names unchanged
for (let i = 0; i < frames * bones; i++) {
    const base = payload + i * 6 * 4;
    const x = buf.readFloatLE(base);
    const a = buf.readFloatLE(base + 8);
    out.writeFloatLE(-x, base);
    let m = 180 - a;                    // reflect about the vertical axis
    while (m > 180)  m -= 360;          // keep it in -180..180 as the baker does
    while (m < -180) m += 360;
    out.writeFloatLE(m, base + 8);
}
fs.writeFileSync(outPath, out);
console.log(`mirrored ${frames} frames x ${bones} bones -> ${outPath}`);
