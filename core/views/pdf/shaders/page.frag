#version 440

// A page as it is read: at night its lightness turned over with the hue
// kept (black type on white becomes pale type on a dark sheet, a red stays
// a red and a photo stays a photo, only darker), and grey when the file will
// be made grey on saving (the editor's preview of finish.grayscale).
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o page.frag.qsb page.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float night;
	float gray;
};

layout(binding = 1) uniform sampler2D source;

void main() {
	vec4 c = texture(source, qt_TexCoord0);
	vec3 rgb = c.a > 0.0 ? c.rgb / c.a : c.rgb;
	float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	rgb = mix(rgb, vec3(l), gray);
	// lightness over: x + (1 - max - min) keeps hue and saturation
	float hi = max(max(rgb.r, rgb.g), rgb.b), lo = min(min(rgb.r, rgb.g), rgb.b);
	vec3 turned = rgb + vec3(1.0 - hi - lo);
	// onto a soft dark sheet, the type not glaring white
	vec3 dark = mix(vec3(0.105, 0.11, 0.125), vec3(0.88, 0.88, 0.86), turned);
	rgb = mix(rgb, dark, night);
	fragColor = vec4(rgb * c.a, c.a) * qt_Opacity;
}
