// surface: the window arrives as a calm surface first, in the tone the shell
// uses for raised things (primaryContainer). The surface grows into place
// with rounder corners that tighten as it lands; then the content fades in
// on top of it. No outline: the shell shows depth with tints, not borders.
#include "common.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float e = ps_enter(min(1.0, p / 0.7));

    vec2 size = ps_size(size_geo);
    float scale = mix(0.86, 1.0, e);
    vec2 px = (coords_geo.xy - 0.5) * size;
    float radius = mix(@radius@ * 2.4, @radius@, clamp(e, 0.0, 1.0));
    float d = ps_box(px, size * scale * 0.5, radius * scale);
    float shape = 1.0 - smoothstep(-0.75, 0.75, d);

    vec4 surface = vec4(@opt.tone@, 1.0) * shape * smoothstep(0.0, 0.18, p);

    // the content sits in the surface, scaled with it
    vec2 uv = (coords_geo.xy - 0.5) / scale + 0.5;
    vec4 win = ps_window(uv) * smoothstep(0.42, 0.92, p);

    // once the content is in, the surface is just its background
    surface *= 1.0 - smoothstep(0.85, 1.0, p);
    return ps_over(win, surface);
}
