#version 440

// A leaf of the book turning: soft paper rolled over a cylinder. The leaf is
// worked out in its own space – u the distance from the spine, v down from
// its top edge (a left leaf is mirrored by dir) – where the axis of the roll
// is the line through axisP across axisN (axisN points to the free edge).
// What lies beyond the axis is wound round the cylinder of radius r and comes
// back flat on top, its back showing; under it the page below shows through
// (transparent here) with the shadow the curl throws. The gutter shade near
// the spine is the same as the still pages' (PdfReader's gutter), so a leaf
// lies down without a seam.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o leaf.frag.qsb leaf.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	vec2 itemSize;
	vec2 origin;     // the spine at the leaf's top edge, in item px
	vec2 leafSize;   // W, H
	float dir;       // 1: a right leaf turning on, -1: a left leaf turning back
	vec2 axisP;
	vec2 axisN;
	float r;
	float gutterFront;
	float gutterBack;
	float shadow;    // 0..1, how much the curl darkens what is under it
};

layout(binding = 1) uniform sampler2D front;
layout(binding = 2) uniform sampler2D back;

const float PI = 3.14159265;

float outside(vec2 q) {
	vec2 o = max(vec2(0.0) - q, q - leafSize);
	return length(max(o, vec2(0.0))) + min(max(o.x, o.y), 0.0);
}

float gutter(float u) {
	float a = u / (leafSize.x * 0.10);
	if (a < 0.3) return mix(0.22, 0.08, a / 0.3);
	if (a < 1.0) return mix(0.08, 0.0, (a - 0.3) / 0.7);
	return 0.0;
}

vec4 sideOf(vec2 q, bool isBack) {
	float fu = dir > 0.0 ? q.x / leafSize.x : 1.0 - q.x / leafSize.x;
	vec2 tc = vec2(isBack ? 1.0 - fu : fu, q.y / leafSize.y);
	vec4 c = isBack ? texture(back, tc) : texture(front, tc);
	float g = gutter(q.x) * (isBack ? gutterBack : gutterFront);
	return vec4(c.rgb * (1.0 - g), c.a);
}

void main() {
	vec2 px = qt_TexCoord0 * itemSize - origin;
	vec2 p = vec2(px.x * dir, px.y);
	float d = dot(p - axisP, axisN);
	float R = max(r, 0.5);

	vec4 col = vec4(0.0);
	// how far the sheet lying on top misses this point (for its shadow)
	float miss = 1e5;
	bool frontUp = false;

	if (d < 0.0) {
		// the part come back flat on top, its back up
		vec2 q = p + (PI * R - 2.0 * d) * axisN;
		float o = outside(q);
		if (o <= 0.0) {
			col = sideOf(q, true);
			col.rgb *= 0.93;
		} else {
			miss = o;
			if (outside(p) <= 0.0) {
				col = sideOf(p, false);
				frontUp = true;
				// the roll darkens the flat page next to it a little
				col.rgb *= 1.0 - 0.16 * exp(d / (R * 1.5 + 3.0));
			}
		}
	} else if (d <= R) {
		float th = asin(clamp(d / R, 0.0, 1.0));
		// the upper half of the roll, back up; else the lower half, front up
		vec2 q2 = p + (R * (PI - th) - d) * axisN;
		vec2 q1 = p + (R * th - d) * axisN;
		if (outside(q2) <= 0.0) {
			float lit = 0.66 + 0.30 * cos(th) + 0.08 * pow(cos(th), 8.0);
			col = sideOf(q2, true);
			col.rgb *= lit;
		} else if (outside(q1) <= 0.0) {
			float lit = 1.0 - 0.42 * pow(sin(th), 1.6);
			col = sideOf(q1, false);
			frontUp = true;
			col.rgb *= lit;
			miss = outside(q2);
		} else {
			miss = min(outside(q1), outside(q2));
		}
	}

	// the shadow the leaf throws: past the roll onto the page under it, and
	// round the edges of the sheet lying on top (onto the front as well)
	float under = 0.0;
	if (d > 0.0 && outside(vec2(abs(p.x), p.y)) <= 0.0) {
		float w = max(R * 3.0, 10.0);
		float t = clamp((d - R * 0.6) / w, 0.0, 1.0);
		under = 0.42 * (1.0 - t) * (1.0 - t);
	}
	float edge = miss < 1e4 ? 0.30 * exp(-miss / (4.0 + R * 0.8)) : 0.0;
	if (frontUp) col.rgb *= 1.0 - edge * shadow;
	// premultiplied: what shows through gets the shadow as black over it
	float sh = max(under, edge) * shadow;
	fragColor = (col + vec4(0.0, 0.0, 0.0, sh) * (1.0 - col.a)) * qt_Opacity;
}
