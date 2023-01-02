const assert = @import("std").debug.assert;
const glad = @cImport(@cInclude("external/glad.h"));
const meshes = @import("meshes.zig");
const Shader = @import("shader.zig").Shader;

pub const WallRenderer = struct {
    vao_id: c_uint,
    vertex_vbo_id: c_uint,
    texture_coord_scales_vbo_id: c_uint,

    wall_data_vbo_id: c_uint,
    walls_uploaded_to_vbo: c_int,

    shader: Shader,
    vp_matrix_location: c_int,

    pub fn create() !WallRenderer {
        var shader = try Shader.create(vertex_shader_source, fragment_shader_source);
        errdefer shader.destroy();
        const loc_position = try shader.getAttributeLocation("position");
        const loc_model_matrix = try shader.getAttributeLocation("model_matrix");
        const loc_texcoord_scale = try shader.getAttributeLocation("texcoord_scale");
        const loc_texture_source_rect = try shader.getAttributeLocation("texture_source_rect");
        const loc_texture_repeat_dimensions = try shader.getAttributeLocation("texture_repeat_dimensions");
        const loc_tint = try shader.getAttributeLocation("tint");
        const loc_vp_matrix = try shader.getUniformLocation("vp_matrix");
        const loc_texture_sampler = try shader.getUniformLocation("texture_sampler");

        var vao_id = createAndBindVao();

        const vertices = meshes.BottomlessCube.vertices;
        var vertex_vbo_id = createAndBindVbo(&vertices, @sizeOf(@TypeOf(vertices)));
        glad.glVertexAttribPointer(loc_position, 3, glad.GL_FLOAT, 0, 0, null);
        glad.glEnableVertexAttribArray(loc_position);

        const texture_coord_scale = meshes.BottomlessCube.texture_coord_scale_values;
        var texture_coord_scales_vbo_id = createAndBindVbo(
            &texture_coord_scale,
            @sizeOf(@TypeOf(texture_coord_scale)),
        );
        glad.glVertexAttribIPointer(loc_texcoord_scale, 1, glad.GL_UNSIGNED_BYTE, 0, null);
        glad.glEnableVertexAttribArray(loc_texcoord_scale);

        var wall_data_vbo_id: c_uint = undefined;
        glad.glGenBuffers(1, &wall_data_vbo_id);
        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, wall_data_vbo_id);

        // // Matrices (mat4) are specifiend in groups of 4 floats.
        setupVertexAttribute(loc_model_matrix, 4, 0, @sizeOf(WallData));
        setupVertexAttribute(loc_model_matrix + 1, 4, @sizeOf([4]f32), @sizeOf(WallData));
        setupVertexAttribute(loc_model_matrix + 2, 4, @sizeOf([8]f32), @sizeOf(WallData));
        setupVertexAttribute(loc_model_matrix + 3, 4, @sizeOf([12]f32), @sizeOf(WallData));
        setupVertexAttribute(loc_texture_source_rect, 4, @offsetOf(
            WallData,
            "texture_source_rect",
        ), @sizeOf(WallData));
        setupVertexAttribute(loc_texture_repeat_dimensions, 3, @offsetOf(
            WallData,
            "texture_repeat_dimensions",
        ), @sizeOf(WallData));
        setupVertexAttribute(loc_tint, 3, @offsetOf(WallData, "tint"), @sizeOf(WallData));
        comptime {
            assert(@sizeOf(WallData) == 104);
            assert(@offsetOf(WallData, "texture_source_rect") == 64);
            assert(@offsetOf(WallData, "texture_repeat_dimensions") == 80);
            assert(@offsetOf(WallData, "tint") == 92);
        }

        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);
        glad.glBindVertexArray(0);

        shader.enable();
        var texture_sampler_id: c_int = 0;
        glad.glUniform1iv(loc_texture_sampler, 1, &texture_sampler_id);
        glad.glUseProgram(0);

        return WallRenderer{
            .vao_id = vao_id,
            .vertex_vbo_id = vertex_vbo_id,
            .texture_coord_scales_vbo_id = texture_coord_scales_vbo_id,
            .wall_data_vbo_id = wall_data_vbo_id,
            .walls_uploaded_to_vbo = 0,
            .shader = shader,
            .vp_matrix_location = loc_vp_matrix,
        };
    }

    pub fn destroy(self: *WallRenderer) void {
        glad.glDeleteBuffers(1, &self.wall_data_vbo_id);
        glad.glDeleteBuffers(1, &self.texture_coord_scales_vbo_id);
        glad.glDeleteBuffers(1, &self.vertex_vbo_id);
        glad.glDeleteVertexArrays(1, &self.vao_id);
        self.shader.destroy();
    }

    pub fn uploadWalls(self: *WallRenderer, walls: []const WallData) void {
        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, self.wall_data_vbo_id);
        defer glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);

        const size = @intCast(c_int, walls.len * @sizeOf(WallData));
        if (walls.len <= self.walls_uploaded_to_vbo) {
            glad.glBufferSubData(glad.GL_ARRAY_BUFFER, 0, size, walls.ptr);
        } else {
            glad.glBufferData(glad.GL_ARRAY_BUFFER, size, walls.ptr, glad.GL_STATIC_DRAW);
        }
        self.walls_uploaded_to_vbo = @intCast(c_int, walls.len);
    }

    /// The given matrix has the same row order as the float16 returned by raymath.MatrixToFloatV().
    pub fn render(self: WallRenderer, vp_matrix: [16]f32, texture_id: c_uint) void {
        const vertex_count = meshes.BottomlessCube.vertices.len;

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D, texture_id);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        glad.glDrawArraysInstanced(glad.GL_TRIANGLES, 0, vertex_count, self.walls_uploaded_to_vbo);
        glad.glBindTexture(glad.GL_TEXTURE_2D, 0);
        glad.glBindVertexArray(0);
        glad.glUseProgram(0);
    }

    pub const WallData = extern struct {
        /// Same row order as the float16 returned by raymath.MatrixToFloatV().
        model_matrix: [16]f32,
        /// These values range from 0 to 1, where (0, 0) is the top left corner of the texture.
        texture_source_rect: extern struct {
            x: f32,
            y: f32,
            w: f32,
            h: f32,
        },
        /// Contains the walls dimensions divided by the textures scale.
        texture_repeat_dimensions: extern struct {
            x: f32,
            y: f32,
            z: f32,
        },
        /// Color values from 0 to 1.
        tint: extern struct {
            r: f32,
            g: f32,
            b: f32,
        },
    };

    const vertex_shader_source =
        \\ #version 330
        \\
        \\ in vec3 position;
        \\ in mat4 model_matrix;
        \\ in vec4 texture_source_rect; // (x, y, w, h) ranging from 0 to 1, (0, 0) == top left.
        \\ in int texcoord_scale; // See TextureCoordScale in meshes.zig.
        \\ in vec3 texture_repeat_dimensions; // The walls dimensions divided by texture scale.
        \\ in vec3 tint;
        \\ uniform mat4 vp_matrix;
        \\
        \\ out vec4 fragment_texture_source_rect;
        \\ out vec2 fragment_texture_repeat;
        \\ out vec3 fragment_tint;
        \\
        \\ vec2 getFragmentRepeat() {
        \\     switch (texcoord_scale) {
        \\         case 0:  return vec2( 0,                           0 );
        \\         case 1:  return vec2( texture_repeat_dimensions.x, 0 );
        \\         case 2:  return vec2( texture_repeat_dimensions.x, texture_repeat_dimensions.y );
        \\         case 3:  return vec2( 0,                           texture_repeat_dimensions.y );
        \\         case 4:  return vec2( texture_repeat_dimensions.z, 0 );
        \\         case 5:  return vec2( texture_repeat_dimensions.z, texture_repeat_dimensions.y );
        \\         case 6:  return vec2( texture_repeat_dimensions.x, texture_repeat_dimensions.z );
        \\         default: return vec2( 0,                           texture_repeat_dimensions.z );
        \\     }
        \\ }
        \\
        \\ void main() {
        \\     gl_Position = vp_matrix * model_matrix * vec4(position, 1.0);
        \\     fragment_texture_source_rect = texture_source_rect;
        \\     fragment_texture_repeat =
        \\         getFragmentRepeat() * vec2(1, texture_source_rect.z / texture_source_rect.w);
        \\     fragment_tint = tint;
        \\ }
    ;
    const fragment_shader_source =
        \\ #version 330
        \\
        \\ in vec4 fragment_texture_source_rect;
        \\ in vec2 fragment_texture_repeat;
        \\ in vec3 fragment_tint;
        \\ uniform sampler2D texture_sampler;
        \\
        \\ out vec4 final_color;
        \\
        \\ void main() {
        \\     vec2 source_position =
        \\         fragment_texture_source_rect.xy
        \\         + mod(fragment_texture_repeat, 1)
        \\         * fragment_texture_source_rect.zw;
        \\     vec4 texel_color = texture(texture_sampler, source_position);
        \\     if (texel_color.a < 0.5) {
        \\         discard;
        \\     }
        \\     final_color = texel_color * vec4(fragment_tint, 1.0);
        \\ }
    ;
};

fn createAndBindVao() c_uint {
    var vao_id: c_uint = undefined;
    glad.glGenVertexArrays(1, &vao_id);
    glad.glBindVertexArray(vao_id);
    return vao_id;
}

fn createAndBindVbo(data: *const anyopaque, size: isize) c_uint {
    var id: c_uint = undefined;
    glad.glGenBuffers(1, &id);
    glad.glBindBuffer(glad.GL_ARRAY_BUFFER, id);
    glad.glBufferData(glad.GL_ARRAY_BUFFER, size, data, glad.GL_STATIC_DRAW);
    return id;
}

fn setupVertexAttribute(
    attribute_location: c_uint,
    component_count: c_int,
    offset_to_first_component: usize,
    all_components_size: c_int,
) void {
    glad.glEnableVertexAttribArray(attribute_location);
    glad.glVertexAttribPointer(
        attribute_location,
        component_count,
        glad.GL_FLOAT,
        0,
        all_components_size,
        @intToPtr(?*u8, offset_to_first_component),
    );
    glad.glVertexAttribDivisor(attribute_location, 1);
}
