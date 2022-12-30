//! Contains an adaption of raylibs default shader for rendering textures with fully transparent
//! fragments.

const util = @import("util.zig");
const rl = @import("raylib");
const rlgl = @cImport(@cInclude("rlgl.h"));

const vertex_shader =
    \\ #version 330
    \\
    \\ in vec3 vertexPosition;
    \\ in vec2 vertexTexCoord;
    \\ in vec4 vertexColor;
    \\ out vec2 fragTexCoord;
    \\ out vec4 fragColor;
    \\ uniform mat4 mvp;
    \\
    \\ void main() {
    \\     fragTexCoord = vertexTexCoord;
    \\     fragColor = vertexColor;
    \\     gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\ }
;

const fragment_shader =
    \\ #version 330
    \\
    \\ in vec2 fragTexCoord;
    \\ in vec4 fragColor;
    \\ out vec4 finalColor;
    \\ uniform sampler2D texture0;
    \\ uniform vec4 colDiffuse;
    \\
    \\ void main() {
    \\     vec4 texelColor = texture(texture0, fragTexCoord);
    \\     if (texelColor.a < 0.5) {
    \\       discard;
    \\     }
    \\     finalColor = texelColor * colDiffuse * fragColor;
    \\ }
;

/// To be freed via raylib.UnloadShader();
pub fn load() util.RaylibError!rl.Shader {
    const shader = rl.LoadShaderFromMemory(vertex_shader, fragment_shader);
    if (shader.id == rlgl.rlGetShaderIdDefault()) {
        return util.RaylibError.FailedToCompileAndLinkShader;
    }
    return shader;
}
