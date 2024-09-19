/* For rendering sprites which rotate around the Y axis towards the camera. */

#version 330

in vec4 vertex_data; // x, y, u, v

in vec3 position; // Center of the billboard.
in vec2 size; // w, h
// (x, y, w, h) values specified in pixels. (0, 0) is the top-left corner of the spritesheet.
in uvec4 source_rect;
// Offsets will be applied after scaling but before Z rotation. Can be used to preserve
// character order when rendering text.
in vec2 offset_from_origin;
in vec4 tint;

in float preserve_exact_pixel_size;

// (sine, cosine) for rotating towards the camera around the Y axis.
uniform vec2 y_rotation_towards_camera;
uniform vec2 screen_dimensions; // Width/height in pixels.
uniform mat4 vp_matrix;

out vec2 fragment_texcoords;
out vec4 fragment_tint;

#define z_rotation 0

void main() {
    vec2 scaled_position = vertex_data.xy * size + offset_from_origin;

    // Sizes specified in pixels must be multiplied by 2 when they exist in 3d game space.
    scaled_position *= preserve_exact_pixel_size + 1;

    vec3 z_rotated_position = vec3(
        scaled_position.x * cos(z_rotation) + scaled_position.y * sin(z_rotation),
        -scaled_position.x * sin(z_rotation) + scaled_position.y * cos(z_rotation),
        0
    );
    vec3 y_rotated_position = vec3(
        z_rotated_position.x * y_rotation_towards_camera[1],
        z_rotated_position.y,
        z_rotated_position.x * y_rotation_towards_camera[0]
    );
    vec3 offset_from_position = mix(y_rotated_position, vec3(0, 0, 0), preserve_exact_pixel_size);
    vec2 offset_on_screen =
      mix(vec2(0, 0), z_rotated_position.xy, preserve_exact_pixel_size) / screen_dimensions;

    gl_Position = vp_matrix * vec4(position + offset_from_position, 1);
    gl_Position /= mix(1, gl_Position.w, preserve_exact_pixel_size);
    gl_Position.xy += offset_on_screen;

    fragment_texcoords = source_rect.xy + source_rect.zw * vertex_data.pq;
    fragment_tint = tint;
}
