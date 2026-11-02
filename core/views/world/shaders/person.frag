#version 440

// One walker, cut away where something nearer stands: every baked thing has
// written how near it stands (depth.png), so people go behind houses and walls.
// Compiled with: qsb --glsl "300 es,330" --hlsl 50 --msl 12 -o person.frag.qsb person.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
	mat4 qt_Matrix;
	float qt_Opacity;
	float foot;
	float frame;
	float flip;
	float night;
	float lift;
	vec2 pos;
	vec2 size;
};
layout(binding = 1) uniform sampler2D person;
layout(binding = 2) uniform sampler2D depth;

void main() {
	vec2 world = pos + qt_TexCoord0 * vec2(6.0, 8.0);
	vec3 near = texture(depth, world / size).rgb;
	float stands = (near.r * 65280.0 + near.g * 255.0) / 65535.0 * size.y;
	if (stands > foot + 0.8) discard;
	// a higher terrace under the feet: this one walks behind it
	float ground = texture(depth, vec2(pos.x + 3.0, foot) / size).b * 510.0;
	if (ground > lift + 1.5) discard;
	float u = flip > 0.5 ? 1.0 - qt_TexCoord0.x : qt_TexCoord0.x;
	vec4 color = texture(person, vec2((u + frame) * 0.5, qt_TexCoord0.y));
	color.rgb *= mix(vec3(1.0), vec3(0.4, 0.45, 0.68), night);
	fragColor = color * qt_Opacity;
}
