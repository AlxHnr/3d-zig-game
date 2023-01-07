const animation = @import("animation.zig");
const assert = @import("std").debug.assert;
const glad = @cImport(@cInclude("external/glad.h"));
const math = @import("std").math;
const meshes = @import("meshes.zig");
const Shader = @import("shader.zig").Shader;
const FlatVector = @import("flat_vector.zig").FlatVector;

pub const WallRenderer = struct {
    vao_id: c_uint,
    vertex_vbo_id: c_uint,
    texture_coord_scales_vbo_id: c_uint,

    wall_data_vbo_id: c_uint,
    walls_uploaded_to_vbo: usize,
    wall_capacity_in_vbo: usize,

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

        const vao_id = createAndBindVao();

        const vertices = meshes.BottomlessCube.vertices;
        const vertex_vbo_id = createAndBindVbo(&vertices, @sizeOf(@TypeOf(vertices)));
        glad.glVertexAttribPointer(loc_position, 3, glad.GL_FLOAT, 0, 0, null);
        glad.glEnableVertexAttribArray(loc_position);

        const texture_coord_scale = meshes.BottomlessCube.texture_coord_scale_values;
        const texture_coord_scales_vbo_id = createAndBindVbo(
            &texture_coord_scale,
            @sizeOf(@TypeOf(texture_coord_scale)),
        );
        glad.glVertexAttribIPointer(loc_texcoord_scale, 1, glad.GL_UNSIGNED_BYTE, 0, null);
        glad.glEnableVertexAttribArray(loc_texcoord_scale);

        const wall_data_vbo_id = createAndBindEmptyVbo();
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
            .wall_capacity_in_vbo = 0,
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
        updateVbo(
            self.wall_data_vbo_id,
            walls.ptr,
            walls.len * @sizeOf(WallData),
            &self.wall_capacity_in_vbo,
            glad.GL_STATIC_DRAW,
        );
        self.walls_uploaded_to_vbo = walls.len;
    }

    /// The given matrix has the same row order as the float16 returned by raymath.MatrixToFloatV().
    pub fn render(self: WallRenderer, vp_matrix: [16]f32, array_texture_id: c_uint) void {
        const vertex_count = meshes.BottomlessCube.vertices.len;

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, array_texture_id);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        glad.glDrawArraysInstanced(
            glad.GL_TRIANGLES,
            0,
            vertex_count,
            @intCast(c_int, self.walls_uploaded_to_vbo),
        );
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
    floors_uploaded_to_vbo: usize,
    floor_capacity_in_vbo: usize,
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

        const vao_id = createAndBindVao();
        const vertex_vbo_id = setupAndBindStandingQuadVbo(loc_position, loc_texture_coords);

        const floor_data_vbo_id = createAndBindEmptyVbo();
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
            .floor_capacity_in_vbo = 0,
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
        updateVbo(
            self.floor_data_vbo_id,
            floors.ptr,
            floors.len * @sizeOf(FloorData),
            &self.floor_capacity_in_vbo,
            glad.GL_STATIC_DRAW,
        );
        self.floors_uploaded_to_vbo = floors.len;
    }

    /// The given matrix has the same row order as the float16 returned by raymath.MatrixToFloatV().
    pub fn render(
        self: FloorRenderer,
        vp_matrix: [16]f32,
        array_texture_id: c_uint,
        floor_animation_state: animation.FourStepCycle,
    ) void {
        const animation_frame: c_int = floor_animation_state.getFrame();

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D_ARRAY, array_texture_id);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        glad.glUniform1iv(self.current_animation_frame_location, 1, &animation_frame);
        renderStandingQuadInstanced(self.floors_uploaded_to_vbo);
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

/// Renders sprites which rotate around the Y axis towards the camera.
pub const BillboardRenderer = struct {
    vao_id: c_uint,
    vertex_vbo_id: c_uint,
    billboard_data_vbo_id: c_uint,
    billboards_uploaded_to_vbo: usize,
    billboard_capacity_in_vbo: usize,
    shader: Shader,
    y_rotation_location: c_int,
    vp_matrix_location: c_int,

    pub fn create() !BillboardRenderer {
        var shader = try Shader.create(vertex_shader_source, fragment_shader_source);
        errdefer shader.destroy();
        const loc_vertex_position = try shader.getAttributeLocation("vertex_position");
        const loc_texture_coords = try shader.getAttributeLocation("texture_coords");
        const loc_billboard_center_position =
            try shader.getAttributeLocation("billboard_center_position");
        const loc_size = try shader.getAttributeLocation("size");
        const loc_z_rotation = try shader.getAttributeLocation("z_rotation");
        const loc_source_rect = try shader.getAttributeLocation("source_rect");
        const loc_tint = try shader.getAttributeLocation("tint");
        const loc_y_rotation_towards_camera =
            try shader.getUniformLocation("y_rotation_towards_camera");
        const loc_vp_matrix = try shader.getUniformLocation("vp_matrix");
        const loc_texture_sampler = try shader.getUniformLocation("texture_sampler");

        const vao_id = createAndBindVao();
        const vertex_vbo_id = setupAndBindStandingQuadVbo(loc_vertex_position, loc_texture_coords);
        const billboard_data_vbo_id = createAndBindEmptyVbo();
        setupVertexAttribute(loc_billboard_center_position, 3, @offsetOf(
            BillboardData,
            "position",
        ), @sizeOf(BillboardData));
        setupVertexAttribute(loc_size, 2, @offsetOf(BillboardData, "size"), @sizeOf(BillboardData));
        setupVertexAttribute(loc_z_rotation, 2, @offsetOf(
            BillboardData,
            "z_rotation",
        ), @sizeOf(BillboardData));
        setupVertexAttribute(loc_source_rect, 4, @offsetOf(BillboardData, "source_rect"), @sizeOf(
            BillboardData,
        ));
        setupVertexAttribute(loc_tint, 3, @offsetOf(BillboardData, "tint"), @sizeOf(BillboardData));
        comptime {
            assert(@offsetOf(BillboardData, "position") == 0);
            assert(@offsetOf(BillboardData, "size") == 12);
            assert(@offsetOf(BillboardData, "z_rotation") == 20);
            assert(@offsetOf(BillboardData, "source_rect") == 28);
            assert(@offsetOf(BillboardData, "tint") == 44);
            assert(@sizeOf(BillboardData) == 56);
        }

        glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);
        glad.glBindVertexArray(0);
        setTextureSamplerId(shader, loc_texture_sampler);

        return BillboardRenderer{
            .vao_id = vao_id,
            .vertex_vbo_id = vertex_vbo_id,
            .billboard_data_vbo_id = billboard_data_vbo_id,
            .billboards_uploaded_to_vbo = 0,
            .billboard_capacity_in_vbo = 0,
            .shader = shader,
            .y_rotation_location = loc_y_rotation_towards_camera,
            .vp_matrix_location = loc_vp_matrix,
        };
    }

    pub fn destroy(self: *BillboardRenderer) void {
        self.shader.destroy();
        glad.glDeleteBuffers(1, &self.billboard_data_vbo_id);
        glad.glDeleteBuffers(1, &self.vertex_vbo_id);
        glad.glDeleteVertexArrays(1, &self.vao_id);
    }

    /// Billboards are rendered in the same order as specified.
    pub fn uploadBillboards(self: *BillboardRenderer, billboards: []const BillboardData) void {
        updateVbo(
            self.billboard_data_vbo_id,
            billboards.ptr,
            billboards.len * @sizeOf(BillboardData),
            &self.billboard_capacity_in_vbo,
            glad.GL_STREAM_DRAW,
        );
        self.billboards_uploaded_to_vbo = billboards.len;
    }

    pub fn render(
        self: BillboardRenderer,
        vp_matrix: [16]f32,
        camera_direction: FlatVector,
        texture_id: c_uint,
    ) void {
        const camera_rotation_to_z_axis =
            camera_direction.computeRotationToOtherVector(.{ .x = 0, .z = 1 });
        const y_rotation_towards_camera = [2]f32{
            math.sin(camera_rotation_to_z_axis),
            math.cos(camera_rotation_to_z_axis),
        };

        self.shader.enable();
        glad.glBindVertexArray(self.vao_id);
        glad.glBindTexture(glad.GL_TEXTURE_2D, texture_id);
        glad.glUniform2fv(self.y_rotation_location, 1, &y_rotation_towards_camera);
        glad.glUniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix);
        renderStandingQuadInstanced(self.billboards_uploaded_to_vbo);
        glad.glBindTexture(glad.GL_TEXTURE_2D, 0);
        glad.glBindVertexArray(0);
        glad.glUseProgram(0);
    }

    pub const BillboardData = extern struct {
        /// Center of the object in game-world coordinates.
        position: extern struct { x: f32, y: f32, z: f32 },
        /// Game-world dimensions.
        size: extern struct { w: f32, h: f32 },
        /// Precomputed angle at which the billboard should be rotated around the Z axis.
        z_rotation: extern struct { sine: f32, cosine: f32 },
        /// Specifies the part of the currently bound texture which should be stretched onto the
        /// billboard. Values range from 0 to 1, where (0, 0) is the top left corner of the texture.
        source_rect: extern struct { x: f32, y: f32, w: f32, h: f32 },
        /// Color values from 0 to 1.
        tint: extern struct { r: f32, g: f32, b: f32 },
    };

    const vertex_shader_source =
        \\ #version 330
        \\
        \\ in vec2 vertex_position;
        \\ in vec2 texture_coords;
        \\ in vec3 billboard_center_position;
        \\ in vec2 size; // Width and height of the billboard.
        \\ in vec2 z_rotation; // (sine, cosine) for rotating the billboard around the Z axis.
        \\ in vec4 source_rect; // Values from 0 to 1, where (0, 0) is the top left of the texture.
        \\ in vec3 tint;
        \\ // (sine, cosine) for rotating towards the camera around the Y axis.
        \\ uniform vec2 y_rotation_towards_camera;
        \\ uniform mat4 vp_matrix;
        \\
        \\ out vec2 fragment_texcoords;
        \\ out vec3 fragment_tint;
        \\
        \\ void main() {
        \\     vec2 scaled_position = vertex_position * size;
        \\     vec2 z_rotated_position = vec2(
        \\         scaled_position.x * z_rotation[1] + scaled_position.y * z_rotation[0],
        \\         -scaled_position.x * z_rotation[0] + scaled_position.y * z_rotation[1]
        \\     );
        \\     vec3 y_rotated_position = vec3(
        \\         z_rotated_position.x * y_rotation_towards_camera[1],
        \\         z_rotated_position.y,
        \\         z_rotated_position.x * y_rotation_towards_camera[0]
        \\     );
        \\
        \\     gl_Position = vp_matrix * vec4(y_rotated_position + billboard_center_position, 1);
        \\     fragment_texcoords = source_rect.xy + source_rect.zw * texture_coords;
        \\     fragment_tint = tint;
        \\ }
    ;
    const fragment_shader_source =
        \\ #version 330
        \\
        \\ in vec2 fragment_texcoords;
        \\ in vec3 fragment_tint;
        \\ uniform sampler2D texture_sampler;
        \\
        \\ out vec4 final_color;
        \\
        \\ void main() {
        \\     vec4 texel_color = texture(texture_sampler, fragment_texcoords);
        \\     if (texel_color.a < 0.01) {
        \\         discard;
        \\     }
        \\     final_color = texel_color * vec4(fragment_tint, 1);
        \\ }
    ;
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
    \\     if (texel_color.a < 0.01) {
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

fn createAndBindEmptyVbo() c_uint {
    var id: c_uint = undefined;
    glad.glGenBuffers(1, &id);
    glad.glBindBuffer(glad.GL_ARRAY_BUFFER, id);
    return id;
}

fn createAndBindVbo(data: *const anyopaque, size: isize) c_uint {
    const id = createAndBindEmptyVbo();
    glad.glBufferData(glad.GL_ARRAY_BUFFER, size, data, glad.GL_STATIC_DRAW);
    return id;
}

/// Returns a bound vbo containing StandingQuad.vertex_data.
fn setupAndBindStandingQuadVbo(position_location: c_uint, texture_coords_location: c_uint) c_uint {
    const vertices = meshes.StandingQuad.vertex_data;
    const vbo_id = createAndBindVbo(&vertices, @sizeOf(@TypeOf(vertices)));
    const stride = @sizeOf([4]f32); // x, y, u, v.
    glad.glVertexAttribPointer(position_location, 2, glad.GL_FLOAT, 0, stride, null); // x, y
    glad.glEnableVertexAttribArray(position_location);
    glad.glVertexAttribPointer(texture_coords_location, 2, glad.GL_FLOAT, 0, stride, @intToPtr(
        ?*u8,
        @sizeOf([2]f32), // u, v
    ));
    glad.glEnableVertexAttribArray(texture_coords_location);
    return vbo_id;
}

fn updateVbo(
    vbo_id: c_uint,
    data: *const anyopaque,
    size: usize,
    /// Will be updated by this function.
    current_capacity: *usize,
    usage: glad.GLenum,
) void {
    const signed_size = @intCast(isize, size);

    glad.glBindBuffer(glad.GL_ARRAY_BUFFER, vbo_id);
    if (size <= current_capacity.*) {
        glad.glBufferSubData(glad.GL_ARRAY_BUFFER, 0, signed_size, data);
    } else {
        glad.glBufferData(glad.GL_ARRAY_BUFFER, signed_size, data, usage);
        current_capacity.* = size;
    }
    glad.glBindBuffer(glad.GL_ARRAY_BUFFER, 0);
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

fn renderStandingQuadInstanced(instance_count: usize) void {
    const vertex_count = meshes.StandingQuad.vertex_data.len / 2;
    glad.glDrawArraysInstanced(glad.GL_TRIANGLES, 0, vertex_count, @intCast(c_int, instance_count));
}
