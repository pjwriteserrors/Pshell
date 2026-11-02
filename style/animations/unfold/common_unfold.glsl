// the part of the window an unfold has reached (r: 0 none … 1 all), and the
// soft accent band along its moving edge
const float PS_FROM = @opt.from@;

float ps_unfold(vec2 coords, vec2 size, float r, out float edge) {
    float h = max(0.0, r) * size.y;
    // anchored at the top (0), the bottom (1) or the middle (0.5)
    float cy = mix(h * 0.5, size.y - h * 0.5, PS_FROM);
    vec2 px = coords * size - vec2(size.x * 0.5, cy);
    float d = ps_box(px, vec2(size.x * 0.5, h * 0.5), @radius@);

    // the moving edge: below from the top, above from the bottom, both ways
    // from the middle
    float side = abs(PS_FROM - 0.5) < 0.1 ? 1.0 : step(0.0, px.y * (1.0 - 2.0 * PS_FROM));
    float dy = abs(abs(px.y) - h * 0.5);
    edge = exp(-dy / 9.0) * side * (1.0 - smoothstep(-4.0, 4.0, d - 6.0));
    return 1.0 - smoothstep(-0.75, 0.75, d);
}
