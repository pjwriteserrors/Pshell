// Shared by the style's window animations, pulled in with #include.
// niri's clock runs linear; the shell's own curves (Motion.qml) are solved here.

const float PS_SWING = @opt.swing@;

float ps_bezier(float x, vec2 a, vec2 b) {
    float t = x;
    for (int i = 0; i < 6; i++) {
        float u = 1.0 - t;
        float fx = 3.0 * u * u * t * a.x + 3.0 * u * t * t * b.x + t * t * t - x;
        float dx = 3.0 * u * u * a.x + 6.0 * u * t * (b.x - a.x) + 3.0 * t * t * (1.0 - b.x);
        if (abs(dx) < 1e-5) break;
        t = clamp(t - fx / dx, 0.0, 1.0);
    }
    float u = 1.0 - t;
    return 3.0 * u * u * t * a.y + 3.0 * u * t * t * b.y + t * t * t;
}

// entering: "land" without swing (gets there and stops, like the rest of
// niri's motion in motion.kdl), Motion.spatial with it (and beyond)
float ps_enter(float p) {
    float plain = ps_bezier(p, vec2(0.3, 0.8), vec2(0.5, 1.0));
    float spatial = ps_bezier(p, vec2(0.38, 1.21), vec2(0.22, 1.0));
    return plain + (spatial - plain) * PS_SWING;
}

// leaving: Motion.accel, it holds and then lets go
float ps_exit(float p) {
    return ps_bezier(p, vec2(0.3, 0.0), vec2(0.8, 0.15));
}

// Studio's preview hands a 1x1 size; shapes are drawn for a typical window there
vec2 ps_size(vec3 size_geo) {
    return size_geo.x < 2.0 ? vec2(640.0, 400.0) : size_geo.xy;
}

// distance in px to a rounded rectangle centred on the origin
float ps_box(vec2 p, vec2 half_size, float r) {
    r = min(r, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// the window at uv (0..1 over its geometry), nothing outside it
vec4 ps_window(vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return vec4(0.0);
    vec3 tex = niri_geo_to_tex * vec3(uv, 1.0);
    return texture2D(niri_tex, tex.st);
}

// premultiplied a over b
vec4 ps_over(vec4 a, vec4 b) {
    return a + b * (1.0 - a.a);
}
