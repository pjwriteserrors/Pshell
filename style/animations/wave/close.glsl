// wave: the band sweeps on and takes the window with it.
#include "common.glsl"
#include "common_wave.glsl"

vec4 close_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float front = ps_exit(p) * (1.0 + PS_BAND);
    float s = ps_wave_s(coords_geo.xy);

    // ahead of the front the window stays, behind it it is gone
    float k = (front - s) / PS_BAND;
    float shown = 1.0 - smoothstep(0.0, 1.0, k);
    float band = (1.0 - smoothstep(0.0, 1.0, abs(k - 0.5) * 1.6)) * step(0.0, k) * step(k, 1.0);

    vec4 win = ps_window(coords_geo.xy);
    vec3 tint = ps_wave_color(clamp(1.0 - k, 0.0, 1.0));
    float amount = band * @opt.accent@ * 0.85;
    vec4 color = vec4(mix(win.rgb, tint * win.a, amount), win.a);
    return color * max(shown, band * @opt.accent@ * 0.6);
}
