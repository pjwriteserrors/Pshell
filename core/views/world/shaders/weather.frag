#version 440

// Rain or snow in front of the world, by screen.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o weather.frag.qsb weather.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float time;
	float snow;
	vec2 res;
};

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void main() {
	vec2 uv = qt_TexCoord0 * res;
	float amount = 0.0;
	for (int layer = 0; layer < 3; layer++) {
		float depth = 1.0 + float(layer) * 0.6;
		if (snow > 0.5) {
			vec2 q = uv * depth / 46.0 + vec2(sin(time * 0.4 + float(layer)) * 0.6, -time * 0.6 * (1.0 + float(layer) * 0.2));
			vec2 cell = floor(q);
			float rnd = hash(cell + float(layer));
			vec2 centre = cell + 0.5 + (vec2(hash(cell + 3.0), hash(cell + 7.0)) - 0.5) * 0.7;
			amount += step(0.72, rnd) * smoothstep(0.08, 0.03, length(q - centre)) * 0.28;
		} else {
			vec2 q = vec2(uv.x + uv.y * 0.14, uv.y) * vec2(depth / 7.0, depth / 90.0) + vec2(0.0, -time * 2.6 * depth);
			vec2 cell = floor(q);
			float rnd = hash(cell + float(layer));
			amount += step(0.965, rnd) * smoothstep(0.42, 0.2, abs(fract(q.x) - 0.5)) * 0.07;
		}
	}
	fragColor = vec4(vec3(0.92, 0.95, 1.0) * amount, amount) * qt_Opacity;
}
