//! Contains a shader for rendering unordered billboards with fully transparent pixels.

const rl = @import("raylib");
const rlgl = @cImport(@cInclude("rlgl.h"));
const util = @import("util.zig");

const vertex_shader =
    \\ #version 330
    \\
    \\ in vec3 vertex_position;
    \\ in vec2 vertex_texture_coordinate;
    \\ out vec2 fragment_texture_coordinate;
    \\ uniform mat4 mvp;
    \\
    \\ void main() {
    \\     fragment_texture_coordinate = vertex_texture_coordinate;
    \\     gl_Position = mvp * vec4(vertex_position, 1.0);
    \\ }
;
const fragment_shader =
    \\ #version 330
    \\
    \\ in vec2 fragment_texture_coordinate;
    \\ out vec4 final_color;
    \\ uniform sampler2D texture0;
    \\ uniform vec4 colDiffuse;
    \\
    \\ void main() {
    \\     vec4 texel_color = texture(texture0, fragment_texture_coordinate);
    \\     if (texel_color.a < 0.5) {
    \\         discard;
    \\     }
    \\     final_color = texel_color * colDiffuse;
    \\ }
;

/// Returns a shader for rendering unordered billboards with fully transparent pixels. To be freed
/// with raylib.UnloadShader().
pub fn load() util.RaylibError!rl.Shader {
    const shader = rl.LoadShaderFromMemory(vertex_shader, fragment_shader);
    if (shader.id == rlgl.rlGetShaderIdDefault()) {
        return util.RaylibError.FailedToCompileAndLinkShader;
    }
    return shader;
}
