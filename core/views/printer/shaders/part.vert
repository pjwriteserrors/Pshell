// one extrusion of the part (an instance of a stretched cube, mesh.py)
VARYING vec4 vColor;
VARYING vec4 vData;
VARYING vec3 vWorld;

void MAIN()
{
    vColor = INSTANCE_COLOR;
    vData = INSTANCE_DATA;
    vWorld = (INSTANCE_MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
