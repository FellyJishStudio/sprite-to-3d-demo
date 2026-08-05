//
// Standard passthrough vertex shader.
//
attribute vec3 in_Position;                  // (x,y,z)
attribute vec4 in_Colour;                    // (r,g,b,a)
attribute vec2 in_TextureCoord;              // (u,v)

varying vec2 v_vTexcoord;
varying vec4 v_vColour;

void main()
{
    vec4 object_space_pos = vec4( in_Position.x, in_Position.y, in_Position.z, 1.0);
    gl_Position = gm_Matrices[MATRIX_WORLD_VIEW_PROJECTION] * object_space_pos;

    v_vColour = in_Colour;
    v_vTexcoord = in_TextureCoord;
}

//######################_==_YOYO_SHADER_MARKER_==_######################@~
//
// Silhouette: the texture contributes ONLY its alpha shape; the flat output colour comes
// from the vertex colour. This is what shadow stamps need -- the art's own colours must
// not leak into the shadow's darkness (black hair once cast no shadow at all, and the
// dark horse cast weakly, because the fixed pipeline multiplies colour by texture).
//
varying vec2 v_vTexcoord;
varying vec4 v_vColour;

void main()
{
    float a = texture2D( gm_BaseTexture, v_vTexcoord ).a;
    gl_FragColor = vec4( v_vColour.rgb, v_vColour.a * a );
}

