// bloom: panels bloom open and snap shut. The window holds, drops to 95 %
// and is gone; its rim flashes in the bar's accent as it lets go.
#include "common.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float e = ps_exit(p);

    float scale = mix(1.0, 0.95, e);
    vec2 uv = (coords_geo.xy - 0.5 - vec2(0.0, e * 0.012)) / scale + 0.5;
    vec4 win = ps_window(uv) * (1.0 - smoothstep(0.15, 1.0, e));

    vec2 size = ps_size(size_geo);
    float d = ps_box((uv - 0.5) * size * scale, size * scale * 0.5, @radius@ * scale);
    float strength = smoothstep(0.0, 0.12, p) * (1.0 - smoothstep(0.25, 0.85, p)) * @opt.accent@;
    float line = exp(-abs(d) / 1.4) * 0.8;
    float halo = exp(-max(d, 0.0) / 10.0) * step(0.0, d) * 0.25;

    vec3 accent = @primary@;
    float glow = (line + halo) * strength;
    vec4 out_color = ps_over(win, vec4(accent * glow, glow));
    out_color.rgb += accent * line * 0.5 * strength * win.a;
    return clamp(out_color, 0.0, 1.0);
}
