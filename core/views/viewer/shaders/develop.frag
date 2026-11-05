#version 440

// A picture developed: where each pixel of the result comes from (turn,
// mirror, straighten, perspective and crop in one projective map `geo` from
// the result's 0..1 to the source's 0..1), then light and colour. The export
// is a grab of the same item at full size, so what is seen is what is saved.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o develop.frag.qsb develop.frag
//
// The tone steps (x a channel 0..1, L its luminance), the same as
// scripts/viewer/viewer.py's `auto` assumes:
//   temperature t   rgb *= (1 + 0.2t, 1, 1 - 0.2t)
//   tint g          rgb *= (1 + 0.1g, 1 - 0.15g, 1 + 0.1g)
//   exposure e      linear (x^2.2) * 2^(2e)
//   brightness b    x^(2^(-0.7b))
//   contrast c      (x - 0.5) * (c >= 0 ? 1 + c : 1 + 0.8c) + 0.5
//   highlights h    + h * 0.4 * smoothstep(0.45, 1, L) * (h > 0 ? 1 - x : x)
//   shadows s       + s * 0.4 * (1 - smoothstep(0, 0.55, L)) * (s > 0 ? 1 - x : x)
//   curves          the lookup texture, a row per channel (master folded in)
//   saturation      mix(L, rgb, 1 + saturation)
//   vibrance v      mix(L, rgb, 1 + v * (1 - (max - min)) * 1.5)
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	mat4 geo;
	float exposure;
	float brightness;
	float contrast;
	float highlights;
	float shadows;
	float temperature;
	float tint;
	float saturation;
	float vibrance;
	float fade;
	float vignette;
	float grain;
	float sharpen;
	float curves;
	float masked;
	float clip;
	float split;
	vec4 shadowTone;
	vec4 highlightTone;
	vec2 texel;
	vec2 outSize;
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D lut;
layout(binding = 3) uniform sampler2D mask;

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float hash(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

vec3 straight(vec4 c) {
	return c.a > 0.0001 ? c.rgb / c.a : vec3(0.0);
}

void main() {
	vec4 p = geo * vec4(qt_TexCoord0, 1.0, 0.0);
	vec2 st = p.xy / p.z;
	// soft edges where a turned picture ends
	vec2 inside = min(st, 1.0 - st) / max(fwidth(st), vec2(1e-6));
	float cover = clamp(min(inside.x, inside.y) + 0.5, 0.0, 1.0);
	if (cover <= 0.0) {
		fragColor = vec4(0.0);
		return;
	}
	vec4 texelColor = texture(source, st);
	float alpha = texelColor.a;
	vec3 c = straight(texelColor);

	if (sharpen > 0.0 && qt_TexCoord0.x >= split) {
		vec3 around = straight(texture(source, st + vec2(texel.x, 0.0))) + straight(texture(source, st - vec2(texel.x, 0.0)))
			+ straight(texture(source, st + vec2(0.0, texel.y))) + straight(texture(source, st - vec2(0.0, texel.y)));
		c += (c - around * 0.25) * sharpen * 1.6;
	}
	if (masked > 0.5) alpha *= texture(mask, st).r;
	// before / after: left of the split the colours as they were
	if (qt_TexCoord0.x < split) {
		float a0 = alpha * cover * qt_Opacity;
		fragColor = vec4(c * a0, a0);
		return;
	}

	c *= vec3(1.0 + 0.2 * temperature, 1.0, 1.0 - 0.2 * temperature);
	c *= vec3(1.0 + 0.1 * tint, 1.0 - 0.15 * tint, 1.0 + 0.1 * tint);
	if (exposure != 0.0) c = pow(pow(max(c, 0.0), vec3(2.2)) * exp2(2.0 * exposure), vec3(1.0 / 2.2));
	if (brightness != 0.0) c = pow(max(c, 0.0), vec3(exp2(-0.7 * brightness)));
	c = (c - 0.5) * (contrast >= 0.0 ? 1.0 + contrast : 1.0 + 0.8 * contrast) + 0.5;
	c = clamp(c, 0.0, 1.0);

	float L = luma(c);
	if (highlights != 0.0) c += highlights * 0.4 * smoothstep(0.45, 1.0, L) * (highlights > 0.0 ? 1.0 - c : c);
	if (shadows != 0.0) c += shadows * 0.4 * (1.0 - smoothstep(0.0, 0.55, L)) * (shadows > 0.0 ? 1.0 - c : c);
	c = clamp(c, 0.0, 1.0);

	if (curves > 0.5) {
		vec3 at = c * (255.0 / 256.0) + 0.5 / 256.0;
		c = vec3(texture(lut, vec2(at.r, 0.125)).r, texture(lut, vec2(at.g, 0.375)).r, texture(lut, vec2(at.b, 0.625)).r);
	}

	L = luma(c);
	c = mix(vec3(L), c, 1.0 + saturation);
	if (vibrance != 0.0) {
		float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
		c = mix(vec3(L), c, 1.0 + vibrance * (1.0 - sat) * 1.5);
	}
	c = clamp(c, 0.0, 1.0);

	L = luma(c);
	if (shadowTone.a > 0.0) c += (shadowTone.rgb - 0.5) * shadowTone.a * (1.0 - L) * (1.0 - L) * 0.7;
	if (highlightTone.a > 0.0) c += (highlightTone.rgb - 0.5) * highlightTone.a * L * L * 0.7;
	if (fade > 0.0) c = mix(c, c * 0.82 + 0.09, fade);

	if (vignette != 0.0) {
		float aspect = outSize.x / max(outSize.y, 1.0);
		vec2 q = (qt_TexCoord0 - 0.5) * vec2(aspect, 1.0);
		float d = length(q) / length(vec2(aspect, 1.0) * 0.5);
		float v = smoothstep(0.3, 1.05, d);
		c = vignette < 0.0 ? c * (1.0 + vignette * 0.85 * v) : mix(c, vec3(1.0), vignette * 0.7 * v);
	}
	if (grain > 0.0) {
		float n = hash(floor(qt_TexCoord0 * outSize)) - 0.5;
		float mid = 1.0 - abs(luma(c) * 2.0 - 1.0);
		c += n * grain * 0.22 * (0.35 + 0.65 * mid);
	}
	c = clamp(c, 0.0, 1.0);

	// what is clipped, for the histogram's warning: blown red, crushed blue
	if (clip > 0.5) {
		if (max(c.r, max(c.g, c.b)) > 0.996) c = vec3(1.0, 0.15, 0.25);
		else if (max(c.r, max(c.g, c.b)) < 0.004) c = vec3(0.15, 0.35, 1.0);
	}

	float a = alpha * cover * qt_Opacity;
	fragColor = vec4(c * a, a);
}
