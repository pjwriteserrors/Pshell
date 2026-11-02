// unfold: the window comes down out of its top edge like the panels drop out
// of the bar (or up from the bottom, or open from the middle). The content
// slides along with the edge and settles.
#include "common.glsl"
#include "common_unfold.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float r = ps_enter(p);
    vec2 size = ps_size(size_geo);

    float edge;
    float mask = ps_unfold(coords_geo.xy, size, r, edge);

    // the content travels with the edge: down from the top, up from the bottom
    float travel = (1.0 - clamp(r, 0.0, 1.2)) * 0.05 * (1.0 - 2.0 * PS_FROM);
    vec2 uv = coords_geo.xy - vec2(0.0, travel);
    vec4 win = ps_window(uv) * mask * smoothstep(0.0, 0.3, p);

    float band = edge * @opt.accent@ * 0.6 * (1.0 - smoothstep(0.5, 1.0, p)) * smoothstep(0.0, 0.1, p);
    vec3 accent = @primary@;
    vec4 out_color = ps_over(win, vec4(accent, 1.0) * band * 0.5);
    out_color.rgb += accent * band * win.a * 0.5;
    return clamp(out_color, 0.0, 1.0);
}
