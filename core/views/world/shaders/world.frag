#version 440

// The land from baked pictures, the sea alive over it, trees in the wind, the
// clouds' shadows, night and its windows. One pass, so that it stays cheap.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o world.frag.qsb world.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float time;
	float zoom;
	float until;
	float focusDay;
	float focusAmount;
	float night;
	vec2 camera;
	vec2 view;
	vec2 size;
	vec4 deep;
	vec4 shallow;
};
layout(binding = 1) uniform sampler2D ground;
layout(binding = 2) uniform sampler2D objects;
layout(binding = 3) uniform sampler2D water;
layout(binding = 4) uniform sampler2D birth;
layout(binding = 5) uniform sampler2D sway;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
	return value(p) * 0.55 + value(p * 2.1 + 7.0) * 0.3 + value(p * 4.3 + 3.0) * 0.15;
}

vec3 sea(vec2 world, float depth, float coverage) {
	vec3 color = mix(shallow.rgb, deep.rgb, smoothstep(0.0, 0.75, depth));
	vec2 p = world * vec2(0.04, 0.075);
	float a = fbm(p + vec2(time * 0.09, time * 0.05));
	float b = fbm(p * 1.7 - vec2(time * 0.07, -time * 0.1));
	float crest = 1.0 - smoothstep(0.0, 0.025, abs(a - b));
	color *= 0.97 + (a - 0.5) * 0.17;
	color += vec3(0.75, 0.9, 1.0) * crest * 0.045;
	color += vec3(1.0) * smoothstep(0.86, 0.95, value(world * 0.35 + time * 0.35) * (a + 0.2)) * 0.12;
	float shore = (1.0 - smoothstep(0.55, 0.88, coverage)) * smoothstep(0.35, 0.55, coverage);
	color = mix(color, vec3(0.89, 0.93, 0.83), shore * (0.65 + 0.35 * sin(coverage * 31.0 - time * 1.1 + a * 3.0)) * 0.45);
	return color;
}

void main() {
	vec2 world = camera + (qt_TexCoord0 - 0.5) * view / zoom;
	vec2 at = world / size;
	vec2 ddx = dFdx(at), ddy = dFdy(at);  // the same mip level on either side of the map's edge
	bool off = at.x < 0.002 || at.y < 0.002 || at.x > 0.998 || at.y > 0.998;
	vec4 w = off ? vec4(1.0, 1.0, 0.0, 1.0) : textureGrad(water, at, ddx, ddy);
	vec3 born = off ? vec3(255.0) : textureGrad(birth, at, ddx, ddy).rgb * 255.0;
	float wet = smoothstep(0.38, 0.55, w.r);
	bool whole = until >= 254.0;
	if (!whole) {
		if (born.r > until + 0.5) {
			wet = 1.0;
			w.r = 1.0;
			w.g = max(w.g, 0.45);
		}
		if (born.b < 254.5 && born.b > until) wet = 0.0;
	}
	vec3 color = sea(world, w.g, w.r);
	if (!off && wet < 1.0) color = mix(textureGrad(ground, at, ddx, ddy).rgb, color, wet);
	if (!off) {
		float tree = textureGrad(sway, at, ddx, ddy).r;
		vec2 shift = vec2(sin(time * 1.25 + world.x * 0.21 + world.y * 0.13) + 0.45 * sin(time * 2.7 + world.y * 0.4), 0.0) * tree * 0.55;
		float fresh = 1.0;
		if (!whole && born.g < 254.5) fresh = clamp(until + 0.6 - born.g, 0.0, 1.0);
		vec4 thing = textureGrad(objects, (world + shift + vec2(0.0, (1.0 - fresh) * 7.0)) / size, ddx, ddy);
		if (!whole && born.g < 254.5) thing *= fresh;
		else if (!whole && thing.a > 0.0) thing *= step(254.5, born.g) * 0.0 + 1.0;
		color = color * (1.0 - thing.a) + thing.rgb;
	}
	if (focusAmount > 0.001) {
		float hit = 1.0 - smoothstep(0.4, 1.0, abs(born.g - focusDay));
		float grey = dot(color, vec3(0.3, 0.59, 0.11));
		color = mix(color, mix(vec3(grey), color, 0.18) * 0.48, (1.0 - hit) * focusAmount);
	}
	if (zoom < 3.2) color *= 1.0 - smoothstep(0.54, 0.74, fbm(world / 170.0 + vec2(time * 0.014, time * 0.006))) * 0.12;
	color *= mix(vec3(1.0), vec3(0.32, 0.38, 0.6), night);
	color += vec3(1.0, 0.72, 0.36) * w.b * night * (0.82 + 0.18 * sin(time * 2.0 + world.x * 1.7));
	vec2 edge = qt_TexCoord0 - 0.5;
	color *= 1.0 - dot(edge, edge) * 0.18;
	fragColor = vec4(color, 1.0) * qt_Opacity;
}
