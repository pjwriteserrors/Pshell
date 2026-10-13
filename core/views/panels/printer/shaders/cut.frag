// The cutting plane at the nozzle's height: a soft hot sheet, brightest at
// its rim, with a shimmer running across it.
VARYING vec3 vWorld;
VARYING vec2 vUv;

void MAIN()
{
    vec2 q = abs(vUv - 0.5) * 2.0;
    float edge = max(q.x, q.y);
    float rim = smoothstep(0.86, 0.985, edge) * (1.0 - smoothstep(0.985, 1.0, edge));
    float sheet = 0.035 * (1.0 - edge * 0.5);
    float wave = 0.025 * (0.5 + 0.5 * sin((vUv.x + vUv.y) * 18.0 - time * 3.0));
    FRAGCOLOR = vec4(hot.rgb, (sheet + wave * (1.0 - edge) + rim * 0.38) * opacity);
}
