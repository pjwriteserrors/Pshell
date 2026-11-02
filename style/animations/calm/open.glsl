// calm: no effect, only the shell's curve. Grows out of 96 % and fades in.
#include "common.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float scale = mix(0.96, 1.0, ps_enter(p));
    vec2 uv = (coords_geo.xy - 0.5) / scale + 0.5;
    return ps_window(uv) * smoothstep(0.0, 0.55, p);
}
