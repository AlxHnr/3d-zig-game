const animation = @import("animation.zig");
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
        var shader = try Shader.create(vertex_shader_source, level_geometry_fragment_shader);
        errdefer shader.destroy();
        const loc_position = try shader.getAttributeLocation("position");
        const loc_model_matrix = try shader.getAttributeLocation("model_matrix");
        const loc_texcoord_scale = try shader.getAttributeLocation("texcoord_scale");
        const loc_texture_layer_id = try shader.getAttributeLocation("texture_layer_id");
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
        setupLevelGeometryPropertyAttributes(
            loc_model_matrix,
            loc_texture_layer_id,
            loc_tint,
            @sizeOf(WallData),
        );
        setupVertexAttribute(loc_texture_repeat_dimensions, 3, @offsetOf(
            WallData,
            "texture_repeat_dimensions",
        ), @sizeOf(WallData));
        comptime {
            assert(@offsetOf(WallData, "properties") == 0);
            assert(@offsetOf(WallData, "texture_repeat_dimensions") == 80);
            assert(@sizeOf(WallData) == 92);
        }

        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);
        glad.glBindVertexArray(0);
        setTextureSamplerId(shader, loc_texture_sampler);

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

    /// The given walls will be rendered in the same order as in the given slice.
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
    pub fn render(self: WallRenderer, vp_matrix: [16]f32, array_texture_id: c_uint) void {
        const vertex_count = meshes.BottomlessCube.vertices.len;

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, array_texture_id);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        glad.glDrawArraysInstanced(glad.GL_TRIANGLES, 0, vertex_count, self.walls_uploaded_to_vbo);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, 0);
        glad.glBindVertexArray(0);
        glad.glUseProgram(0);
    }

    pub const WallData = extern struct {
        properties: LevelGeometryAttributes,
        // How often the texture should repeat along each axis.
        texture_repeat_dimensions: extern struct {
            x: f32,
            y: f32,
            z: f32,
        },
    };

    const vertex_shader_source =
        \\ #version 330
        \\
        \\ in vec3 position;
        \\ in mat4 model_matrix;
        \\ in int texcoord_scale; // See TextureCoordScale in meshes.zig.
        \\ in float texture_layer_id; // Index in the current array texture, will be rounded.
        \\ in vec3 texture_repeat_dimensions; // How often the texture should repeat along each axis.
        \\ in vec3 tint;
        \\ uniform mat4 vp_matrix;
        \\
        \\ out vec2 fragment_texcoords;
        \\ out float fragment_texture_layer_id;
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
        \\     gl_Position = vp_matrix * model_matrix * vec4(position, 1);
        \\     fragment_texcoords = getFragmentRepeat();
        \\     fragment_texture_layer_id = texture_layer_id;
        \\     fragment_tint = tint;
        \\ }
    ;
};

pub const FloorRenderer = struct {
    vao_id: c_uint,
    vertex_vbo_id: c_uint,
    floor_data_vbo_id: c_uint,
    floors_uploaded_to_vbo: c_int,
    shader: Shader,
    vp_matrix_location: c_int,
    current_animation_frame_location: c_int,

    pub fn create() !FloorRenderer {
        var shader = try Shader.create(vertex_shader_source, level_geometry_fragment_shader);
        errdefer shader.destroy();
        const loc_position = try shader.getAttributeLocation("position");
        const loc_texture_coords = try shader.getAttributeLocation("texture_coords");
        const loc_texture_layer_id = try shader.getAttributeLocation("texture_layer_id");
        const loc_affected_by_animation_cycle =
            try shader.getAttributeLocation("affected_by_animation_cycle");
        const loc_model_matrix = try shader.getAttributeLocation("model_matrix");
        const loc_texture_repeat_dimensions =
            try shader.getAttributeLocation("texture_repeat_dimensions");
        const loc_tint = try shader.getAttributeLocation("tint");
        const loc_vp_matrix = try shader.getUniformLocation("vp_matrix");
        const loc_current_animation_frame =
            try shader.getUniformLocation("current_animation_frame");
        const loc_texture_sampler = try shader.getUniformLocation("texture_sampler");

        var vao_id = createAndBindVao();

        const vertices = meshes.StandingQuad.vertex_data;
        const stride = @sizeOf([4]f32); // x, y, u, v.
        var vertex_vbo_id = createAndBindVbo(&vertices, @sizeOf(@TypeOf(vertices)));
        glad.glVertexAttribPointer(loc_position, 2, glad.GL_FLOAT, 0, stride, null); // x, y
        glad.glEnableVertexAttribArray(loc_position);
        glad.glVertexAttribPointer(loc_texture_coords, 2, glad.GL_FLOAT, 0, stride, @intToPtr(
            ?*u8,
            @sizeOf([2]f32), // u, v
        ));
        glad.glEnableVertexAttribArray(loc_texture_coords);

        var floor_data_vbo_id: c_uint = undefined;
        glad.glGenBuffers(1, &floor_data_vbo_id);
        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, floor_data_vbo_id);
        setupLevelGeometryPropertyAttributes(
            loc_model_matrix,
            loc_texture_layer_id,
            loc_tint,
            @sizeOf(FloorData),
        );
        setupVertexAttribute(loc_affected_by_animation_cycle, 1, @offsetOf(
            FloorData,
            "affected_by_animation_cycle",
        ), @sizeOf(FloorData));
        setupVertexAttribute(loc_texture_repeat_dimensions, 2, @offsetOf(
            FloorData,
            "texture_repeat_dimensions",
        ), @sizeOf(FloorData));
        comptime {
            assert(@offsetOf(FloorData, "properties") == 0);
            assert(@offsetOf(FloorData, "affected_by_animation_cycle") == 80);
            assert(@offsetOf(FloorData, "texture_repeat_dimensions") == 84);
            assert(@sizeOf(FloorData) == 92);
        }

        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);
        glad.glBindVertexArray(0);
        setTextureSamplerId(shader, loc_texture_sampler);

        return FloorRenderer{
            .vao_id = vao_id,
            .vertex_vbo_id = vertex_vbo_id,
            .floor_data_vbo_id = floor_data_vbo_id,
            .floors_uploaded_to_vbo = 0,
            .shader = shader,
            .vp_matrix_location = loc_vp_matrix,
            .current_animation_frame_location = loc_current_animation_frame,
        };
    }

    pub fn destroy(self: *FloorRenderer) void {
        self.shader.destroy();
        glad.glDeleteBuffers(1, &self.floor_data_vbo_id);
        glad.glDeleteBuffers(1, &self.vertex_vbo_id);
        glad.glDeleteVertexArrays(1, &self.vao_id);
    }

    /// The given floors will be rendered in the same order as in the given slice.
    pub fn uploadFloors(self: *FloorRenderer, floors: []const FloorData) void {
        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, self.floor_data_vbo_id);
        defer glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);

        const size = @intCast(c_int, floors.len * @sizeOf(FloorData));
        if (floors.len <= self.floors_uploaded_to_vbo) {
            glad.glBufferSubData(glad.GL_ARRAY_BUFFER, 0, size, floors.ptr);
        } else {
            glad.glBufferData(glad.GL_ARRAY_BUFFER, size, floors.ptr, glad.GL_STATIC_DRAW);
        }
        self.floors_uploaded_to_vbo = @intCast(c_int, floors.len);
    }

    /// The given matrix has the same row order as the float16 returned by raymath.MatrixToFloatV().
    pub fn render(
        self: FloorRenderer,
        vp_matrix: [16]f32,
        array_texture_id: c_uint,
        floor_animation_state: animation.FourStepCycle,
    ) void {
        const vertex_count = meshes.BottomlessCube.vertices.len;
        const animation_frame: c_int = floor_animation_state.getFrame();

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, array_texture_id);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        glad.glUniform1iv(self.current_animation_frame_location, 1, &animation_frame);
        glad.glDrawArraysInstanced(glad.GL_TRIANGLES, 0, vertex_count, self.floors_uploaded_to_vbo);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, 0);
        glad.glBindVertexArray(0);
        glad.glUseProgram(0);
    }

    pub const FloorData = extern struct {
        properties: LevelGeometryAttributes,
        /// Either 1 or 0. Animations work by adding 0, 1 or 2 to `.properties.texture_layer_id`.
        affected_by_animation_cycle: f32,
        /// How often the texture should repeat along the floors width and height.
        texture_repeat_dimensions: extern struct {
            x: f32,
            y: f32,
        },
    };

    const vertex_shader_source =
        \\ #version 330
        \\
        \\ in vec2 position;
        \\ in vec2 texture_coords;
        \\ in float texture_layer_id; // Index in the current array texture, will be rounded.
        \\ in float affected_by_animation_cycle; // 1 when the floor should cycle trough animations.
        \\ in mat4 model_matrix;
        \\ in vec2 texture_repeat_dimensions; // How often the texture should repeat along each axis.
        \\ in vec3 tint;
        \\ uniform mat4 vp_matrix;
        \\ uniform int current_animation_frame; // Must be 0, 1 or 2.
        \\
        \\ out vec2 fragment_texcoords;
        \\ out float fragment_texture_layer_id;
        \\ out vec3 fragment_tint;
        \\
        \\ void main() {
        \\     gl_Position = vp_matrix * model_matrix * vec4(position, 0, 1);
        \\     fragment_texcoords = texture_coords * texture_repeat_dimensions;
        \\     fragment_texture_layer_id =
        \\         texture_layer_id + current_animation_frame * affected_by_animation_cycle;
        \\     fragment_tint = tint;
        \\ }
    ;
};

/// Basic geometry data to be uploaded as vertex attributes to the GPU.
pub const LevelGeometryAttributes = extern struct {
    /// Same row order as the float16 returned by raymath.MatrixToFloatV().
    model_matrix: [16]f32,
    /// Index of the layer in the array texture passed to render(). Will be rounded.
    texture_layer_id: f32,
    /// Color values from 0 to 1.
    tint: extern struct {
        r: f32,
        g: f32,
        b: f32,
    },
};

const level_geometry_fragment_shader =
    \\ #version 330
    \\
    \\ in vec2 fragment_texcoords;
    \\ in float fragment_texture_layer_id;
    \\ in vec3 fragment_tint;
    \\ uniform sampler2DArray texture_sampler;
    \\
    \\ out vec4 final_color;
    \\
    \\ void main() {
    \\     vec4 texel_color = texture(texture_sampler,
    \\         vec3(fragment_texcoords, fragment_texture_layer_id));
    \\     if (texel_color.a < 0.5) {
    \\         discard;
    \\     }
    \\     final_color = texel_color * vec4(fragment_tint, 1);
    \\ }
;

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

/// Configures LevelGeometryAttributes as vertex attributes at offset 0.
fn setupLevelGeometryPropertyAttributes(
    loc_model_matrix: c_uint,
    loc_texture_layer_id: c_uint,
    loc_tint: c_uint,
    stride: c_int,
) void {
    // Matrices (mat4) are specified in groups of 4 floats.
    setupVertexAttribute(loc_model_matrix + 0, 4, 0, stride);
    setupVertexAttribute(loc_model_matrix + 1, 4, @sizeOf([4]f32), stride);
    setupVertexAttribute(loc_model_matrix + 2, 4, @sizeOf([8]f32), stride);
    setupVertexAttribute(loc_model_matrix + 3, 4, @sizeOf([12]f32), stride);
    setupVertexAttribute(loc_texture_layer_id, 1, @offsetOf(
        LevelGeometryAttributes,
        "texture_layer_id",
    ), stride);
    setupVertexAttribute(loc_tint, 3, @offsetOf(LevelGeometryAttributes, "tint"), stride);
    comptime {
        assert(@offsetOf(LevelGeometryAttributes, "model_matrix") == 0);
        assert(@offsetOf(LevelGeometryAttributes, "texture_layer_id") == 64);
        assert(@offsetOf(LevelGeometryAttributes, "tint") == 68);
        assert(@sizeOf(LevelGeometryAttributes) == 80);
    }
}

fn setTextureSamplerId(shader: Shader, loc_texture_sampler: c_int) void {
    shader.enable();
    var texture_sampler_id: c_int = 0;
    glad.glUniform1iv(loc_texture_sampler, 1, &texture_sampler_id);
    glad.glUseProgram(0);
}
