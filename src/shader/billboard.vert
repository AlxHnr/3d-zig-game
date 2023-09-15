/* For rendering sprites which rotate around the Y axis towards the camera. */

#version 330

in vec2 vertex_position;
in vec2 texture_coords;
in vec3 billboard_center_position;
in vec2 size; // Width and height of the billboard.
in vec2 offset_from_origin;
in vec2 z_rotation; // (sine, cosine) for rotating the billboard around the Z axis.
in vec4 source_rect; // Values from 0 to 1, where (0, 0) is the top left of the texture.
in vec3 tint;

// (sine, cosine) for rotating towards the camera around the Y axis.
uniform vec2 y_rotation_towards_camera;
uniform vec2 screen_dimensions; // Width/height in pixels.
uniform mat4 vp_matrix;

out vec2 fragment_texcoords;
out vec3 fragment_tint;

void main() {
    vec2 scaled_position = vertex_position * size + offset_from_origin;
    vec2 z_rotated_position = vec2(
        scaled_position.x * z_rotation[1] + scaled_position.y * z_rotation[0],
        -scaled_position.x * z_rotation[0] + scaled_position.y * z_rotation[1]
    );
    vec3 y_rotated_position = vec3(
        z_rotated_position.x * y_rotation_towards_camera[1],
        z_rotated_position.y,
        z_rotated_position.x * y_rotation_towards_camera[0]
    );

    gl_Position = vp_matrix * vec4(y_rotated_position + billboard_center_position, 1);

    // Prevent screen_dimensions from being optimized out.
    if(screen_dimensions.x == 89723) gl_Position *= 1.2;

    fragment_texcoords = source_rect.xy + source_rect.zw * texture_coords;
    fragment_tint = tint;
}
