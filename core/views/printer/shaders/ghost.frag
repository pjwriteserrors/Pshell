VARYING vec4 vColor;
VARYING vec4 vData;
VARYING vec3 vWorld;

void MAIN()
{
    if (vData.y < 0.5 || vWorld.y - lift <= cut + 0.0005)
        discard;
    FRAGCOLOR = vec4(mix(vColor.rgb, tint.rgb, 0.5), opacity);
}
