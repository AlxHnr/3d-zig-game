/* For rendering sprites which rotate around the Y axis towards the camera. */

#version 330

in vec2 vertex_position;
in vec2 texture_coords;
in vec3 billboard_center_position;
in vec2 size; // Width and height of the billboard.
in vec2 offset_from_origin;
in float z_rotation; // Angle in radians for rotating the billboard around its Z axis.
in vec4 source_rect; // X, y, w and h values specified in pixels on the spritesheet, with (0, 0)
                     // being the top-left corner.
in vec4 tint;
// 0 if the billboard should shrink with increasing camera distance.
// 1 if the billboard should have a fixed pixel size independently from its distance to the camera.
in float preserve_exact_pixel_size;

// (sine, cosine) for rotating towards the camera around the Y axis.
uniform vec2 y_rotation_towards_camera;
uniform vec2 screen_dimensions; // Width/height in pixels.
uniform mat4 vp_matrix;

out vec2 fragment_texcoords;
out vec4 fragment_tint;

void main() {
    vec2 scaled_position = vertex_position * size + offset_from_origin;

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

    gl_Position = vp_matrix * vec4(billboard_center_position + offset_from_position, 1);
    gl_Position /= mix(1, gl_Position.w, preserve_exact_pixel_size);
    gl_Position.xy += offset_on_screen;

    fragment_texcoords = source_rect.xy + source_rect.zw * texture_coords;
    fragment_tint = tint;
}
