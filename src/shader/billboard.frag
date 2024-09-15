#version 330

in vec2 fragment_texcoords;
in vec3 fragment_tint;
uniform sampler2D texture_sampler;

out vec4 final_color;

void main() {
    vec2 texcoords = fragment_texcoords / textureSize(texture_sampler, 0);
    vec4 texel_color = texture(texture_sampler, texcoords);
    if (texel_color.a < 0.01) {
        discard;
    }
    final_color = texel_color * vec4(fragment_tint, 1);
}
