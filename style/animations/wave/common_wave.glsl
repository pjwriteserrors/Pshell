// a soft wave of palette colours running across the window: s is where a
// pixel sits along the wave's way (0 first … 1 last)
const vec2 PS_DIR = @opt.dir@;
const float PS_BAND = 0.32;

float ps_wave_s(vec2 coords) {
    // projected on the direction and spread to 0..1 whatever the direction
    float lo = min(0.0, PS_DIR.x) + min(0.0, PS_DIR.y);
    float hi = max(0.0, PS_DIR.x) + max(0.0, PS_DIR.y);
    return (dot(coords, PS_DIR) - lo) / (hi - lo);
}

// the colour of the band, through the palette
vec3 ps_wave_color(float t) {
    vec3 a = @color2@;
    vec3 b = @primary@;
    vec3 c = @color5@;
    return t < 0.5 ? mix(a, b, t * 2.0) : mix(b, c, t * 2.0 - 1.0);
}
