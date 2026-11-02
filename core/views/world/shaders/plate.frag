#version 440

// A city's sharp picture, whose trees move with those of the map below.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o plate.frag.qsb plate.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float time;
	float night;
	vec4 rect;
	vec2 size;
};
layout(binding = 1) uniform sampler2D plate;
layout(binding = 2) uniform sampler2D sway;

void main() {
	vec2 world = rect.xy + qt_TexCoord0 * rect.zw;
	float tree = texture(sway, world / size).r;
	vec2 shift = vec2(sin(time * 1.25 + world.x * 0.21 + world.y * 0.13) + 0.45 * sin(time * 2.7 + world.y * 0.4), 0.0) * tree * 0.55;
	vec4 color = texture(plate, qt_TexCoord0 + shift / rect.zw);
	color.rgb *= mix(vec3(1.0), vec3(0.32, 0.38, 0.6), night);
	fragColor = color * qt_Opacity;
}
