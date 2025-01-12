#version 330

in vec4 vertex_data;
in float texture_layer_id; // Index in the current array texture, will be rounded.
in float affected_by_animation_cycle; // 1 when the floor should cycle trough animations.
in mat4 model_matrix;
in vec2 texture_repeat_dimensions; // How often the texture should repeat along each axis.
in vec4 tint;
uniform mat4 vp_matrix;
uniform int current_animation_frame; // Must be 0, 1 or 2.

out vec2 fragment_texcoords;
out float fragment_texture_layer_id;
out vec4 fragment_tint;

void main() {
  gl_Position = vp_matrix * model_matrix * vec4(vertex_data.xy, 0, 1);
  fragment_texcoords = vertex_data.pq * texture_repeat_dimensions;
  fragment_texture_layer_id =
    texture_layer_id + current_animation_frame * affected_by_animation_cycle;
  fragment_tint = tint;
}
