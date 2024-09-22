// Renders sprites which rotate around the Y axis towards the camera. See `SpriteData` in
// rendering.zig for an explanation of the input values.

#version 330

in vec4 vertex_data;

in vec3 position;
in vec2 size;
in uvec4 source_rect;
in vec2 offset_from_origin;
in vec4 tint;

in uint animation_start_tick;
in vec3 animation_offset_to_target_position;
in uint animation_index;

in float preserve_exact_pixel_size;

uniform vec2 y_rotation_towards_camera;
uniform vec2 screen_dimensions;
uniform mat4 vp_matrix;
uniform uint previous_tick;
uniform float interval_between_previous_and_current_tick;

layout (std140) uniform Animations {
    uvec4 packed_animations[128];
};

struct PackedKeyframe
{
    vec4 position_offset_and_target_interval;
    uvec4 tint_and_z_rotation;
};
layout (std140) uniform Keyframes {
    PackedKeyframe packed_keyframes[512];
};

out vec2 fragment_texcoords;
out vec4 fragment_tint;

struct Keyframe
{
    vec3 position_offset;
    float target_position_interval;
    vec4 tint;
    float z_rotation;
};

// Does not unpack `position_offset`.
void unpackPartialKeyframe(in int keyframe_index, out Keyframe keyframe)
{
    keyframe.target_position_interval =
      packed_keyframes[keyframe_index].position_offset_and_target_interval[3];
    int tint32 = int(packed_keyframes[keyframe_index].tint_and_z_rotation[0]);
    keyframe.tint = vec4(
      float(tint32 >>  0 & 0xff),
      float(tint32 >>  8 & 0xff),
      float(tint32 >> 16 & 0xff),
      float(tint32 >> 24 & 0xff)
    ) / 255;
    keyframe.z_rotation = uintBitsToFloat(packed_keyframes[keyframe_index].tint_and_z_rotation[1]);
}

void computeInterpolatedKeyframe(out Keyframe result)
{
    float keyframe_duration = uintBitsToFloat(packed_animations[animation_index][0]);
    float elapsed_ticks = float(int(previous_tick) - int(animation_start_tick))
      + interval_between_previous_and_current_tick;
    float keyframe_interval = mod(elapsed_ticks / keyframe_duration, 1);
    int keyframe_count = int(packed_animations[animation_index][2]);
    int elapsed_keyframes = int(elapsed_ticks / keyframe_duration);
    int offset_to_first_keyframe = int(packed_animations[animation_index][1]);

    // 4 Keyframes are required for Catmull-Rom splines.
    ivec4 keyframe_indices = ivec4(
      elapsed_keyframes + keyframe_count - 1, // pre-previous keyframe
      elapsed_keyframes,                      // previous keyframe
      elapsed_keyframes + 1,                  // next keyframe
      elapsed_keyframes + 2                   // post-next keyframe
    ) % keyframe_count + offset_to_first_keyframe;

    vec3 position_offsets[4];
    for(int i = 0; i < 4; i++)
    {
      position_offsets[i] =
        packed_keyframes[keyframe_indices[i]].position_offset_and_target_interval.xyz;
    }

    // Catmull-Rom spline interpolation.
    float interval_squared = keyframe_interval * keyframe_interval;
    float interval_cubed = interval_squared * keyframe_interval;
    result.position_offset =
        position_offsets[0] * (-interval_cubed + 2 * interval_squared - keyframe_interval)
      + position_offsets[1] * (3 * interval_cubed - 5 * interval_squared + 2)
      + position_offsets[2] * (-3 * interval_cubed + 4 * interval_squared + keyframe_interval)
      + position_offsets[3] * (interval_cubed - interval_squared);

    // Interpolate remaining fields.
    Keyframe previous_keyframe, next_keyframe;
    unpackPartialKeyframe(keyframe_indices[1], previous_keyframe);
    unpackPartialKeyframe(keyframe_indices[2], next_keyframe);
    result.target_position_interval = mix(
        previous_keyframe.target_position_interval,
        next_keyframe.target_position_interval,
        keyframe_interval
    );
    result.tint = mix(previous_keyframe.tint, next_keyframe.tint, keyframe_interval);
    result.z_rotation = mix(
      previous_keyframe.z_rotation, next_keyframe.z_rotation, keyframe_interval
    );
}

void main() {
    Keyframe keyframe;
    computeInterpolatedKeyframe(keyframe);
    vec2 scaled_position = vertex_data.xy * size + offset_from_origin;
    vec3 animated_position = mix(
        position, position + animation_offset_to_target_position, keyframe.target_position_interval
    ) + keyframe.position_offset;

    // Sizes specified in pixels must be multiplied by 2 when they exist in 3d game space.
    scaled_position *= preserve_exact_pixel_size + 1;

    vec3 z_rotated_position = vec3(
        scaled_position.x * cos(keyframe.z_rotation) + scaled_position.y * sin(keyframe.z_rotation),
        -scaled_position.x * sin(keyframe.z_rotation) + scaled_position.y * cos(keyframe.z_rotation),
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

    gl_Position = vp_matrix * vec4(animated_position + offset_from_position, 1);
    gl_Position /= mix(1, gl_Position.w, preserve_exact_pixel_size);
    gl_Position.xy += offset_on_screen;

    fragment_texcoords = source_rect.xy + source_rect.zw * vertex_data.pq;
    fragment_tint = tint * keyframe.tint;
}
