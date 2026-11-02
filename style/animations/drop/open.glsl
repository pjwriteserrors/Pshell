// drop: the window spreads out like a drop of ink, from the middle, the top
// or a corner. Its front is inked in the accent (or a palette colour) and
// clears as it settles.
#include "common.glsl"
#include "common_drop.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float r = ps_enter(p);
    vec2 size = ps_size(size_geo);

    float rim;
    float mask = ps_drop(coords_geo.xy, size, r, rim);
    vec4 win = ps_window(coords_geo.xy) * mask;

    float ink = rim * mask * @opt.accent@ * (1.0 - smoothstep(0.45, 1.0, p));
    win.rgb = mix(win.rgb, @opt.ink@ * win.a, ink * 0.8);
    return win;
}
