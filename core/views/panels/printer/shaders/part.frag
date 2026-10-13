// The part up to the cut: what lies above is not printed yet. The layer
// right under the cut glows hot, outer walls are a touch brighter.
VARYING vec4 vColor;
VARYING vec4 vData;
VARYING vec3 vWorld;

void MAIN()
{
    float y = vWorld.y - lift;
    if (y > cut + 0.0005)
        discard;
    float heat = smoothstep(cut - layerHeight * 1.05, cut - layerHeight * 0.2, y);
    vec3 base = vColor.rgb * (0.84 + 0.16 * vData.y);
    BASE_COLOR = vec4(mix(base, hot.rgb, heat * glow), 1.0);
    EMISSIVE_COLOR = hot.rgb * heat * glow * 0.65;
    ROUGHNESS = 0.6;
    METALNESS = 0.0;
    SPECULAR_AMOUNT = 0.3;
}
