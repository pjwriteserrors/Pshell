// a drop of colour spreading from the origin: how far it has reached, and
// the inked rim of its front
const vec2 PS_ORIGIN = @opt.origin@;

float ps_drop(vec2 coords, vec2 size, float r, out float rim) {
    vec2 px = (coords - PS_ORIGIN) * size;
    vec2 far = max(PS_ORIGIN, 1.0 - PS_ORIGIN) * size;
    float reach = length(far) * r;
    // the front ripples a little and calms as the drop spreads out
    float angle = atan(px.y, px.x);
    float wobble = sin(angle * 5.0 + niri_random_seed * 6.2831) * 7.0 * (1.0 - clamp(r, 0.0, 1.0));
    float d = length(px) - reach - wobble;
    rim = exp(-abs(d + 10.0) / 12.0);
    return 1.0 - smoothstep(-18.0, 2.0, d);
}
