#version 330

in vec2 fragment_texcoords;
in float fragment_texture_layer_id;
in vec4 fragment_tint;
uniform sampler2DArray texture_sampler;

out vec4 final_color;

void main() {
    vec4 texel_color = texture(texture_sampler,
        vec3(fragment_texcoords, fragment_texture_layer_id));
    if (texel_color.a < 0.01) {
        discard;
    }
    final_color = texel_color * fragment_tint;
}
