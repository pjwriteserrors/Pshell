// calm: shrinks to 97 % and fades out.
#include "common.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float e = ps_exit(p);
    float scale = mix(1.0, 0.97, e);
    vec2 uv = (coords_geo.xy - 0.5) / scale + 0.5;
    return ps_window(uv) * (1.0 - smoothstep(0.0, 0.9, p));
}
