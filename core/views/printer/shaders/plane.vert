// a flat square in the scene's xz plane (the bed, the cut)
VARYING vec3 vWorld;
VARYING vec2 vUv;

void MAIN()
{
    vWorld = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vUv = UV0;
    POSITION = MODELVIEWPROJECTION_MATRIX * vec4(VERTEX, 1.0);
}
