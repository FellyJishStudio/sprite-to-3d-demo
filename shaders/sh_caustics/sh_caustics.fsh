//
// Caustics: the bright veins light makes on a floor when it passes through moving water.
//
// Physically they are the folds of a wavy surface focusing light into lines, and that is
// what this builds -- several sets of wave crests laid over each other, each one BENT by
// the one before it, with the bright output taken where the folds nearly touch. The
// bending is the whole difference between caustics and graph paper: unwarped sine grids
// give a rigid lattice that reads as a texture, not as water.
//
// Everything works in GROUND units, taken from the world position rather than from texture
// coordinates, so the pattern lies on the floor and stays put as the camera moves over it.
// The y axis is doubled to undo the demo's 2:1 isometric squash -- a cell that is round on
// the ground has to be drawn as an ellipse on screen, and this is where that happens.
//
varying vec2 v_vWorld;
varying vec4 v_vColour;

uniform vec2  u_centre;      // pool centre, world
uniform float u_radius;      // ground reach
uniform float u_time;        // seconds
uniform vec3  u_tint;        // the water's own colour
uniform float u_fade;        // overall strength

float caustic(vec2 p, float t)
{
    float acc = 0.0;
    vec2  q   = p;
    for (int i = 0; i < 3; i++)
    {
        float fi = float(i);
        // Each layer is finer than the last and drifts on its own slow circle, so the
        // crests never settle into a repeating alignment.
        q = q * 1.63 + vec2(sin(t * 0.61 + fi * 2.1), cos(t * 0.47 + fi * 1.3));
        vec2 w = vec2(sin(q.y * 1.07 + t * 0.90), cos(q.x * 1.07 - t * 0.80));
        acc += abs(sin(q.x + w.x) * cos(q.y + w.y));
    }
    // Ridged and sharpened: bright only where the folds come together. The high power is
    // what turns broad bands into thin veins.
    return pow(1.0 - clamp(acc / 3.0, 0.0, 1.0), 5.0);
}

void main()
{
    vec2  d  = v_vWorld - u_centre;
    d.y     *= 2.0;                                   // iso 1:2 -> ground units
    float rn = length(d) / u_radius;
    if (rn > 1.0) discard;                            // the quad is square; the pool is not

    vec2  p = d / 34.0;                               // ~34 ground units per cell
    float c = caustic(p, u_time);
    // A second, coarser and slower pass: the big slow swell under the fine detail. Water
    // moves on more than one scale at once and one scale alone reads as a screensaver.
    c += 0.45 * caustic(p * 0.47 + vec2(3.1, 1.7), u_time * 0.63);

    // Ripples running outward from the projector, and a slow breathing over the whole
    // pool, so the pattern travels instead of merely churning in place.
    c *= 0.62 + 0.52 * (0.5 + 0.5 * sin(rn * 17.0 - u_time * 3.2));
    c *= 0.85 + 0.15 * sin(u_time * 0.9);

    // Soft to the rim, hard nowhere: an edge is the one thing that would give away that
    // this is a quad with a pattern on it.
    float mask = 1.0 - smoothstep(0.48, 1.0, rn);

    // The veins go pale, nearly white at their brightest, over the water's own colour --
    // concentrated light loses its tint, which is why real caustics look white-hot.
    vec3  col = mix(u_tint * 0.6, vec3(0.74, 0.95, 1.0), clamp(c * 1.25, 0.0, 1.0));
    float a   = mask * u_fade * v_vColour.a * clamp(0.14 + c * 1.45, 0.0, 1.0);

    gl_FragColor = vec4(col, a);
}
