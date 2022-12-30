//! Contains a shader for rendering textures with fully transparent pixels.

const util = @import("util.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const rlgl = @cImport(@cInclude("rlgl.h"));
const glad = @cImport(@cInclude("external/glad.h"));

const vertex_shader =
    \\ #version 330
    \\
    \\ in vec3 vertex_position;
    \\ in vec2 vertex_texture_coordinate;
    \\ out vec2 fragment_texture_coordinate;
    \\ uniform mat4 mvp_matrix;
    \\
    \\ void main() {
    \\     fragment_texture_coordinate = vertex_texture_coordinate;
    \\     gl_Position = mvp_matrix * vec4(vertex_position, 1.0);
    \\ }
;
const fragment_shader =
    \\ #version 330
    \\
    \\ in vec2 fragment_texture_coordinate;
    \\ out vec4 final_color;
    \\ uniform sampler2D texture_sampler;
    \\ uniform vec4 tint;
    \\
    \\ void main() {
    \\     vec4 texel_color = texture(texture_sampler, fragment_texture_coordinate);
    \\     if (texel_color.a < 0.5) {
    \\         discard;
    \\     }
    \\     final_color = texel_color * tint;
    \\ }
;

pub const GenericShader = struct {
    shader: rl.Shader,
    mvp_location: glad.GLint,
    texture_sampler_location: glad.GLint,
    tint_location: glad.GLint,

    pub fn create() util.RaylibError!GenericShader {
        const shader = rl.LoadShaderFromMemory(vertex_shader, fragment_shader);
        if (shader.id == rlgl.rlGetShaderIdDefault()) {
            return util.RaylibError.FailedToCompileAndLinkShader;
        }

        const mvp_location = glad.glGetUniformLocation(shader.id, "mvp_matrix");
        const texture_sampler_location = glad.glGetUniformLocation(shader.id, "texture_sampler");
        const tint_location = glad.glGetUniformLocation(shader.id, "tint");
        if (mvp_location == -1 or texture_sampler_location == -1 or tint_location == -1) {
            return util.RaylibError.FailedToCompileAndLinkShader;
        }
        return GenericShader{
            .shader = shader,
            .mvp_location = mvp_location,
            .texture_sampler_location = texture_sampler_location,
            .tint_location = tint_location,
        };
    }

    pub fn destroy(self: *GenericShader) void {
        rl.UnloadShader(self.shader);
    }

    pub fn enable(self: GenericShader) void {
        rl.BeginShaderMode(self.shader);
        rlgl.rlEnableShader(self.shader.id);
        rlgl.rlActiveTextureSlot(0);
        var sampler2d_id: glad.GLint = 0;
        glad.glUniform1iv(self.texture_sampler_location, 1, &sampler2d_id);
    }

    pub fn disable(_: GenericShader) void {
        rl.EndShaderMode();
        rlgl.rlDisableShader();
    }

    /// Only callable when the shader is active.
    pub fn drawMesh(
        self: GenericShader,
        mesh: rl.Mesh,
        model_matrix: rl.Matrix,
        texture: rl.Texture,
        tint: rl.Color,
    ) void {
        const raylib_view_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixModelview());
        const raylib_projection_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixProjection());
        const raylib_transform_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixTransform());
        const mvp_matrix = rm.MatrixMultiply(rm.MatrixMultiply(
            rm.MatrixMultiply(model_matrix, raylib_transform_matrix),
            raylib_view_matrix,
        ), raylib_projection_matrix);
        const tint_vec4 = [4]glad.GLfloat{
            @intToFloat(f32, tint.r) / 255.0,
            @intToFloat(f32, tint.g) / 255.0,
            @intToFloat(f32, tint.b) / 255.0,
            @intToFloat(f32, tint.a) / 255.0,
        };

        _ = rlgl.rlEnableVertexArray(mesh.vaoId);
        rlgl.rlEnableTexture(texture.id);
        rlgl.rlSetUniformMatrix(self.mvp_location, @bitCast(rlgl.Matrix, mvp_matrix));
        glad.glUniform4fv(self.tint_location, 1, &tint_vec4);

        rlgl.rlDrawVertexArray(0, mesh.vertexCount);

        rlgl.rlDisableVertexArray();
        rlgl.rlDisableTexture();
    }
};
