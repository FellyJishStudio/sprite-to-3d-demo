//
// Caustics: passthrough, plus the WORLD position handed on to the fragment stage.
//
// The pattern has to be anchored to the ground, not to the quad -- a projector's caustics
// stay put on the floor while the camera moves over them. Texture coordinates could not do
// it: GameMaker's are page coordinates, so they depend on where the sprite happens to land
// in the atlas. The vertex position is already exactly what is wanted, in the units the
// rest of the demo measures the ground in.
//
attribute vec3 in_Position;                  // (x,y,z)
attribute vec4 in_Colour;                    // (r,g,b,a)
attribute vec2 in_TextureCoord;              // (u,v)

varying vec2 v_vWorld;
varying vec4 v_vColour;

void main()
{
    vec4 object_space_pos = vec4( in_Position.x, in_Position.y, in_Position.z, 1.0);
    gl_Position = gm_Matrices[MATRIX_WORLD_VIEW_PROJECTION] * object_space_pos;

    v_vWorld  = ( gm_Matrices[MATRIX_WORLD] * object_space_pos ).xy;
    v_vColour = in_Colour;
}
