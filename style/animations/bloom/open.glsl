// bloom: a window opens the way the shell's panels do. It grows out of 92 %,
// rises a touch, and a rim of the bar's accent runs along its corners and
// fades as it lands.
#include "common.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float e = ps_enter(p);

    float scale = mix(0.92, 1.0, e);
    vec2 lift = vec2(0.0, (1.0 - e) * 0.025);
    vec2 uv = (coords_geo.xy - 0.5 - lift) / scale + 0.5;
    vec4 win = ps_window(uv) * smoothstep(0.0, 0.42, p);

    vec2 size = ps_size(size_geo);
    float d = ps_box((uv - 0.5) * size * scale, size * scale * 0.5, @radius@ * scale);
    float strength = smoothstep(0.0, 0.16, p) * (1.0 - smoothstep(0.30, 1.0, p)) * @opt.accent@;
    float line = exp(-abs(d) / 1.6) * 0.9;
    float halo = exp(-max(d, 0.0) / 14.0) * step(0.0, d) * 0.35;
    float inner = exp(-max(-d, 0.0) / 22.0) * step(d, 0.0) * 0.18;

    vec3 accent = @primary@;
    float glow = (line + halo) * strength;
    vec4 out_color = ps_over(win, vec4(accent * glow, glow));
    out_color.rgb += accent * (line * 0.6 + inner) * strength * win.a;
    return clamp(out_color, 0.0, 1.0);
}
