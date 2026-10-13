// The bed: a 10 mm grid that fades out around the part.
VARYING vec3 vWorld;
VARYING vec2 vUv;

void MAIN()
{
    vec2 p = (vWorld.xz - center) / spacing;
    vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);
    float line = 1.0 - min(min(g.x, g.y), 1.0);
    float fade = 1.0 - smoothstep(radius * 0.35, radius, length(vWorld.xz - center));
    FRAGCOLOR = vec4(tint.rgb, (0.06 + 0.22 * line) * fade * opacity);
}
