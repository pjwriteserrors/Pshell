// drop: draws back into the origin, quicker than it spread.
#include "common.glsl"
#include "common_drop.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float r = 1.0 - ps_exit(p);
    vec2 size = ps_size(size_geo);

    float rim;
    float mask = ps_drop(coords_geo.xy, size, r, rim);
    vec4 win = ps_window(coords_geo.xy) * mask * (1.0 - smoothstep(0.75, 1.0, p));

    float ink = rim * mask * @opt.accent@ * smoothstep(0.0, 0.2, p);
    win.rgb = mix(win.rgb, @opt.ink@ * win.a, ink * 0.8);
    return win;
}
