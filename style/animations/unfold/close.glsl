// unfold: folds back into the edge it came from, quicker than it opened.
#include "common.glsl"
#include "common_unfold.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float r = 1.0 - ps_exit(p);
    vec2 size = ps_size(size_geo);

    float edge;
    float mask = ps_unfold(coords_geo.xy, size, r, edge);

    float travel = (1.0 - r) * 0.05 * (1.0 - 2.0 * PS_FROM);
    vec2 uv = coords_geo.xy - vec2(0.0, travel);
    vec4 win = ps_window(uv) * mask * (1.0 - smoothstep(0.7, 1.0, p));

    float band = edge * @opt.accent@ * 0.5 * smoothstep(0.0, 0.15, p) * (1.0 - smoothstep(0.7, 1.0, p));
    vec3 accent = @primary@;
    vec4 out_color = ps_over(win, vec4(accent, 1.0) * band * 0.5);
    out_color.rgb += accent * band * win.a * 0.5;
    return clamp(out_color, 0.0, 1.0);
}
