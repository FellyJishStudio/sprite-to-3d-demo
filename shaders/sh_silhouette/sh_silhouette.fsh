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
