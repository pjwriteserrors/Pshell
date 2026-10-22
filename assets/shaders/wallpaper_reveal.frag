#version 440

// A new wallpaper blooms out of the bar: a wave with a soft, slightly
// uneven front runs from `origin` over the screen. Just behind the front
// the new picture is bent towards the origin like through a lens and a
// thin rim of the theme's accent glows; the new picture settles from a
// slight zoom while the old one drifts closer and dims.
// Both pictures are cropped here (PreserveAspectCrop), so the Images can
// hand over their textures as they are.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o wallpaper_reveal.frag.qsb wallpaper_reveal.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float progress;
	float aspect;
	float seed;
	vec2 origin;
	vec2 fromScale;
	vec2 toScale;
	vec4 accent;
};

layout(binding = 1) uniform sampler2D from;
layout(binding = 2) uniform sampler2D to;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash(vec2(i, seed)), hash(vec2(i + 1.0, seed)), f);
}

vec2 crop(vec2 uv, vec2 scale) {
	return vec2(0.5) + (uv - vec2(0.5)) * scale;
}

void main() {
	vec2 uv = qt_TexCoord0;
	vec2 delta = (uv - origin) * vec2(aspect, 1.0);
	float dist = length(delta);
	float angle = atan(delta.y, delta.x);

	// the farthest corner, so the wave has left the screen at progress 1
	vec2 far = max(origin, vec2(1.0) - origin) * vec2(aspect, 1.0);
	float reach = length(far) + 0.25;

	// a front that eases in and out, uneven by a few percent along its arc
	float eased = 0.5 - 0.5 * cos(3.14159265 * progress);
	float wobble = (noise(angle * 5.0 + 3.0) - 0.5) * 0.09 + (noise(angle * 13.0) - 0.5) * 0.03;
	float front = eased * reach + wobble * eased;
	float soft = 0.035 + 0.05 * eased;
	float inside = 1.0 - smoothstep(front - soft, front, dist);

	// a narrow band just behind the front
	float rim = smoothstep(front - soft * 2.5, front - soft * 0.6, dist) * inside;

	// new picture: settles from a zoom around the origin, bent at the rim
	float zoom = mix(1.08, 1.0, eased);
	vec2 dir = dist > 0.0001 ? delta / dist : vec2(0.0);
	vec2 bent = uv - dir / vec2(aspect, 1.0) * rim * 0.035;
	vec2 toUv = origin + (bent - origin) / zoom;
	vec4 next = texture(to, crop(toUv, toScale));

	// old picture: drifts a little closer and dims as the wave nears
	vec2 fromUv = origin + (uv - origin) / mix(1.0, 1.03, eased);
	vec4 last = texture(from, crop(fromUv, fromScale));
	float near = smoothstep(front + 0.5, front, dist);
	last.rgb *= 1.0 - 0.35 * near * (1.0 - inside);

	vec4 colour = mix(last, next, inside);
	colour.rgb = mix(colour.rgb, colour.rgb + accent.rgb * 0.6, rim * 0.5 * (1.0 - eased * 0.5));
	colour.rgb += (hash(uv * 977.0 + seed) - 0.5) / 255.0;
	fragColor = vec4(colour.rgb, 1.0) * qt_Opacity;
}
