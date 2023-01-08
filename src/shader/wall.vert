#version 330

in vec3 position;
in mat4 model_matrix;
in int texcoord_scale; // See TextureCoordScale in meshes.zig.
in float texture_layer_id; // Index in the current array texture, will be rounded.
in vec3 texture_repeat_dimensions; // How often the texture should repeat along each axis.
in vec3 tint;
uniform mat4 vp_matrix;

out vec2 fragment_texcoords;
out float fragment_texture_layer_id;
out vec3 fragment_tint;

vec2 getFragmentRepeat() {
  switch (texcoord_scale) {
    case 0:  return vec2(0,                           0);
    case 1:  return vec2(texture_repeat_dimensions.x, 0);
    case 2:  return vec2(texture_repeat_dimensions.x, texture_repeat_dimensions.y);
    case 3:  return vec2(0,                           texture_repeat_dimensions.y);
    case 4:  return vec2(texture_repeat_dimensions.z, 0);
    case 5:  return vec2(texture_repeat_dimensions.z, texture_repeat_dimensions.y);
    case 6:  return vec2(texture_repeat_dimensions.x, texture_repeat_dimensions.z);
    default: return vec2(0,                           texture_repeat_dimensions.z);
  }
}

void main() {
  gl_Position = vp_matrix * model_matrix * vec4(position, 1);
  fragment_texcoords = getFragmentRepeat();
  fragment_texture_layer_id = texture_layer_id;
  fragment_tint = tint;
}
