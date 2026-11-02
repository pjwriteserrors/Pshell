// wave: a soft band of wallpaper colours sweeps across and leaves the window
// behind it.
#include "common.glsl"
#include "common_wave.glsl"

vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    float front = ps_enter(p) * (1.0 + PS_BAND);
    float s = ps_wave_s(coords_geo.xy);

    // behind the front the window, inside the band the colour
    float k = (front - s) / PS_BAND;
    float shown = smoothstep(0.0, 1.0, k);
    float band = (1.0 - smoothstep(0.0, 1.0, abs(k - 0.35) * 1.6)) * step(0.0, k);

    vec4 win = ps_window(coords_geo.xy);
    vec3 tint = ps_wave_color(clamp(k, 0.0, 1.0));
    float amount = band * @opt.accent@ * 0.85;
    vec4 color = vec4(mix(win.rgb, tint * win.a, amount), win.a);
    return color * max(shown, band * @opt.accent@);
}
