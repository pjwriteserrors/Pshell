// surface: the content goes first, the surface it sat on shrinks after it.
#include "common.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float e = ps_exit(p);

    vec2 size = ps_size(size_geo);
    float scale = mix(1.0, 0.9, e);
    vec2 px = (coords_geo.xy - 0.5) * size;
    float radius = mix(@radius@, @radius@ * 2.4, e);
    float d = ps_box(px, size * scale * 0.5, radius * scale);
    float shape = 1.0 - smoothstep(-0.75, 0.75, d);

    vec2 uv = (coords_geo.xy - 0.5) / scale + 0.5;
    vec4 win = ps_window(uv) * (1.0 - smoothstep(0.0, 0.4, p));
    vec4 surface = vec4(@opt.tone@, 1.0) * shape
        * smoothstep(0.0, 0.08, p) * (1.0 - smoothstep(0.45, 1.0, p));
    return ps_over(win, surface);
}
