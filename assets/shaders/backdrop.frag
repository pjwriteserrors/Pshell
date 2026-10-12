#version 440

// What the chats of Messages are drawn on when no picture was picked: the
// palette as slow light (0), as contour lines (1) or as a field of dots (2).
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o backdrop.frag.qsb backdrop.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float time;
	float kind;
	float shift;
	vec2 res;
	vec4 base;
	vec4 first;
	vec4 second;
	vec4 third;
};

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float weight = 0.5;
	for (int i = 0; i < 4; i += 1) {
		value += weight * noise(p);
		p = p * 2.03 + 17.0;
		weight *= 0.5;
	}
	return value;
}

void main() {
	vec2 uv = qt_TexCoord0;
	vec2 p = vec2(uv.x * res.x / max(res.y, 1.0), uv.y + shift);
	vec3 colour = base.rgb;

	if (kind < 0.5) {
		vec2 q = p * 1.15;
		float one = fbm(q + vec2(time * 0.05, time * 0.03));
		float two = fbm(q * 1.3 + vec2(-time * 0.04, time * 0.06) + one * 1.5);
		float three = fbm(q * 0.8 + vec2(time * 0.03, -time * 0.05) + two * 1.2);
		colour = mix(colour, first.rgb, smoothstep(0.3, 0.8, one) * 0.46);
		colour = mix(colour, second.rgb, smoothstep(0.38, 0.85, two) * 0.38);
		colour = mix(colour, third.rgb, smoothstep(0.42, 0.9, three) * 0.3);
	} else if (kind < 1.5) {
		float field = fbm(p * 1.5 + vec2(time * 0.02, -time * 0.015)) * 9.0;
		float edge = abs(fract(field) - 0.5);
		float line = 1.0 - smoothstep(0.0, fwidth(field) * 1.3, edge);
		colour = mix(colour, first.rgb, 0.1 * smoothstep(2.0, 7.0, field));
		colour = mix(colour, mix(first.rgb, second.rgb, clamp(field / 9.0, 0.0, 1.0)), line * 0.4);
	} else {
		vec2 grid = vec2(uv.x * res.x, (uv.y + shift) * res.y) / 22.0;
		vec2 cell = floor(grid);
		vec2 at = fract(grid) - 0.5;
		float swell = (0.5 + 0.5 * sin(dot(cell, vec2(0.33, 0.27)) - time * 0.6)) * fbm(cell * 0.11 + time * 0.03) * 1.8;
		float radius = mix(0.06, 0.3, clamp(swell, 0.0, 1.0));
		float dot_ = 1.0 - smoothstep(radius - 0.05, radius, length(at));
		colour = mix(colour, mix(first.rgb, second.rgb, uv.y), dot_ * (0.14 + 0.3 * clamp(swell, 0.0, 1.0)));
	}

	// no banding in the slow gradients
	colour += (hash(uv * res) - 0.5) / 160.0;
	fragColor = vec4(colour, 1.0) * qt_Opacity;
}
