const animation = @import("animation.zig");
const std = @import("std");
const assert = std.debug.assert;
const gl = @import("gl");
const math = @import("math.zig");
const meshes = @import("meshes.zig");
const Shader = @import("shader.zig").Shader;

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
        var shader = try Shader.create(
            @embedFile("./shader/wall.vert"),
            @embedFile("./shader/level_geometry.frag"),
        );
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
        gl.vertexAttribPointer(loc_position, 3, gl.FLOAT, 0, 0, null);
        gl.enableVertexAttribArray(loc_position);

        const texture_coord_scale = meshes.BottomlessCube.texture_coord_scale_values;
        const texture_coord_scales_vbo_id = createAndBindVbo(
            &texture_coord_scale,
            @sizeOf(@TypeOf(texture_coord_scale)),
        );
        gl.vertexAttribIPointer(loc_texcoord_scale, 1, gl.UNSIGNED_BYTE, 0, null);
        gl.enableVertexAttribArray(loc_texcoord_scale);

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

        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
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
        gl.deleteBuffers(1, &self.wall_data_vbo_id);
        gl.deleteBuffers(1, &self.texture_coord_scales_vbo_id);
        gl.deleteBuffers(1, &self.vertex_vbo_id);
        gl.deleteVertexArrays(1, &self.vao_id);
        self.shader.destroy();
    }

    /// The given walls will be rendered in the same order as in the given slice.
    pub fn uploadWalls(self: *WallRenderer, walls: []const WallData) void {
        updateVbo(
            self.wall_data_vbo_id,
            walls.ptr,
            walls.len * @sizeOf(WallData),
            &self.wall_capacity_in_vbo,
            gl.STATIC_DRAW,
        );
        self.walls_uploaded_to_vbo = walls.len;
    }

    pub fn render(self: WallRenderer, vp_matrix: math.Matrix, array_texture_id: c_uint) void {
        const vertex_count = meshes.BottomlessCube.vertices.len;

        self.shader.enable();
        gl.bindVertexArray(self.vao_id);
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, array_texture_id);
        gl.uniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix.toFloatArray());
        gl.drawArraysInstanced(
            gl.TRIANGLES,
            0,
            vertex_count,
            @intCast(c_int, self.walls_uploaded_to_vbo),
        );
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, 0);
        gl.bindVertexArray(0);
        gl.useProgram(0);
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
        var shader = try Shader.create(
            @embedFile("./shader/floor.vert"),
            @embedFile("./shader/level_geometry.frag"),
        );
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

        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
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
        gl.deleteBuffers(1, &self.floor_data_vbo_id);
        gl.deleteBuffers(1, &self.vertex_vbo_id);
        gl.deleteVertexArrays(1, &self.vao_id);
    }

    /// The given floors will be rendered in the same order as in the given slice.
    pub fn uploadFloors(self: *FloorRenderer, floors: []const FloorData) void {
        updateVbo(
            self.floor_data_vbo_id,
            floors.ptr,
            floors.len * @sizeOf(FloorData),
            &self.floor_capacity_in_vbo,
            gl.STATIC_DRAW,
        );
        self.floors_uploaded_to_vbo = floors.len;
    }

    pub fn render(
        self: FloorRenderer,
        vp_matrix: math.Matrix,
        array_texture_id: c_uint,
        floor_animation_state: animation.FourStepCycle,
    ) void {
        const animation_frame: c_int = floor_animation_state.getFrame();

        self.shader.enable();
        gl.bindVertexArray(self.vao_id);
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, array_texture_id);
        gl.uniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix.toFloatArray());
        gl.uniform1iv(self.current_animation_frame_location, 1, &animation_frame);
        renderStandingQuadInstanced(self.floors_uploaded_to_vbo);
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, 0);
        gl.bindVertexArray(0);
        gl.useProgram(0);
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
};

/// Basic geometry data to be uploaded as vertex attributes to the GPU.
pub const LevelGeometryAttributes = extern struct {
    /// Same row order as the float16 returned by raymath.MatrixToFloatV().
    model_matrix: [16]f32,
    /// Index of the layer in the array texture passed to render(). Will be rounded.
    texture_layer_id: f32,
    /// Color values from 0 to 1.
    tint: extern struct { r: f32, g: f32, b: f32 },
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
        var shader = try Shader.create(
            @embedFile("./shader/billboard.vert"),
            @embedFile("./shader/billboard.frag"),
        );
        errdefer shader.destroy();
        const loc_vertex_position = try shader.getAttributeLocation("vertex_position");
        const loc_texture_coords = try shader.getAttributeLocation("texture_coords");
        const loc_billboard_center_position =
            try shader.getAttributeLocation("billboard_center_position");
        const loc_size = try shader.getAttributeLocation("size");
        const loc_x_offset_from_origin = try shader.getAttributeLocation("x_offset_from_origin");
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
        setupVertexAttribute(loc_x_offset_from_origin, 1, @offsetOf(
            BillboardData,
            "x_offset_from_origin",
        ), @sizeOf(BillboardData));
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
            assert(@offsetOf(BillboardData, "x_offset_from_origin") == 20);
            assert(@offsetOf(BillboardData, "z_rotation") == 24);
            assert(@offsetOf(BillboardData, "source_rect") == 32);
            assert(@offsetOf(BillboardData, "tint") == 48);
            assert(@sizeOf(BillboardData) == 60);
        }

        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
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
        gl.deleteBuffers(1, &self.billboard_data_vbo_id);
        gl.deleteBuffers(1, &self.vertex_vbo_id);
        gl.deleteVertexArrays(1, &self.vao_id);
    }

    /// Billboards are rendered in the same order as specified.
    pub fn uploadBillboards(self: *BillboardRenderer, billboards: []const BillboardData) void {
        updateVbo(
            self.billboard_data_vbo_id,
            billboards.ptr,
            billboards.len * @sizeOf(BillboardData),
            &self.billboard_capacity_in_vbo,
            gl.STREAM_DRAW,
        );
        self.billboards_uploaded_to_vbo = billboards.len;
    }

    pub fn render(
        self: BillboardRenderer,
        vp_matrix: math.Matrix,
        camera_direction: math.Vector3d,
        texture_id: c_uint,
    ) void {
        const camera_rotation_to_z_axis =
            camera_direction.toFlatVector().computeRotationToOtherVector(.{ .x = 0, .z = -1 });
        const y_rotation_towards_camera = [2]f32{
            std.math.sin(camera_rotation_to_z_axis),
            std.math.cos(camera_rotation_to_z_axis),
        };

        self.shader.enable();
        gl.bindVertexArray(self.vao_id);
        gl.bindTexture(gl.TEXTURE_2D, texture_id);
        gl.uniform2fv(self.y_rotation_location, 1, &y_rotation_towards_camera);
        gl.uniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix.toFloatArray());
        renderStandingQuadInstanced(self.billboards_uploaded_to_vbo);
        gl.bindTexture(gl.TEXTURE_2D, 0);
        gl.bindVertexArray(0);
        gl.useProgram(0);
    }

    /// Render all uploaded billboards without perspective projection. All billboards are assumed to
    /// contain screen coordinates (x, y), where (0, 0) represents the top left corner of the
    /// screen. Z will be ignored.
    pub fn render2d(
        self: BillboardRenderer,
        screen_width: u16,
        screen_height: u16,
        texture_id: c_uint,
    ) void {
        // Flip V texture coordinate to preserve orientation when inverting Y.
        var vertex_data = meshes.StandingQuad.vertex_data;
        var index: usize = 3;
        while (index < vertex_data.len) : (index += 4) {
            vertex_data[index] = 1 - vertex_data[index];
        }
        var size: usize = @sizeOf(@TypeOf(vertex_data));
        updateVbo(self.vertex_vbo_id, &vertex_data, size, &size, gl.STATIC_DRAW);

        const screen_to_ndc_matrix = math.Matrix{ .rows = .{
            .{ 2 / @intToFloat(f32, screen_width), 0, 0, -1 },
            .{ 0, -2 / @intToFloat(f32, screen_height), 0, 1 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 1 },
        } };
        self.render(screen_to_ndc_matrix, .{ .x = 0, .y = 0, .z = 1 }, texture_id);

        updateVbo(self.vertex_vbo_id, &meshes.StandingQuad.vertex_data, size, &size, gl.STATIC_DRAW);
    }

    pub const BillboardData = extern struct {
        /// Center of the object. Must either contain game-world coordinates when calling render()
        /// or screen coordinates when calling render2d().
        position: extern struct { x: f32, y: f32, z: f32 },
        size: extern struct { w: f32, h: f32 },
        /// Will be applied after scaling but before Z rotation. Can be used to preserve character
        /// order when rendering text.
        x_offset_from_origin: f32 = 0,
        /// Precomputed angle at which the billboard should be rotated around the Z axis. Defaults
        /// to no rotation.
        z_rotation: extern struct { sine: f32, cosine: f32 } = .{
            .sine = std.math.sin(@floatCast(f32, 0)),
            .cosine = std.math.cos(@floatCast(f32, 0)),
        },
        /// Specifies the part of the currently bound texture which should be stretched onto the
        /// billboard. Values range from 0 to 1, where (0, 0) is the top left corner of the texture.
        source_rect: extern struct { x: f32, y: f32, w: f32, h: f32 },
        /// Color values from 0 to 1. Defaults to white (no tint).
        tint: extern struct { r: f32, g: f32, b: f32 } = .{ .r = 1, .g = 1, .b = 1 },
    };
};

fn createAndBindVao() c_uint {
    var vao_id: c_uint = undefined;
    gl.genVertexArrays(1, &vao_id);
    gl.bindVertexArray(vao_id);
    return vao_id;
}

fn createAndBindEmptyVbo() c_uint {
    var id: c_uint = undefined;
    gl.genBuffers(1, &id);
    gl.bindBuffer(gl.ARRAY_BUFFER, id);
    return id;
}

fn createAndBindVbo(data: *const anyopaque, size: isize) c_uint {
    const id = createAndBindEmptyVbo();
    gl.bufferData(gl.ARRAY_BUFFER, size, data, gl.STATIC_DRAW);
    return id;
}

/// Returns a bound vbo containing StandingQuad.vertex_data.
fn setupAndBindStandingQuadVbo(position_location: c_uint, texture_coords_location: c_uint) c_uint {
    const vertices = meshes.StandingQuad.vertex_data;
    const vbo_id = createAndBindVbo(&vertices, @sizeOf(@TypeOf(vertices)));
    const stride = @sizeOf([4]f32); // x, y, u, v.
    gl.vertexAttribPointer(position_location, 2, gl.FLOAT, 0, stride, null); // x, y
    gl.enableVertexAttribArray(position_location);
    gl.vertexAttribPointer(texture_coords_location, 2, gl.FLOAT, 0, stride, @intToPtr(
        ?*u8,
        @sizeOf([2]f32), // u, v
    ));
    gl.enableVertexAttribArray(texture_coords_location);
    return vbo_id;
}

fn updateVbo(
    vbo_id: c_uint,
    data: ?*const anyopaque,
    size: usize,
    /// Will be updated by this function.
    current_capacity: *usize,
    usage: gl.GLenum,
) void {
    const signed_size = @intCast(isize, size);

    gl.bindBuffer(gl.ARRAY_BUFFER, vbo_id);
    if (size <= current_capacity.*) {
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, signed_size, data);
    } else {
        gl.bufferData(gl.ARRAY_BUFFER, signed_size, data, usage);
        current_capacity.* = size;
    }
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);
}

fn setupVertexAttribute(
    attribute_location: c_uint,
    component_count: c_int,
    offset_to_first_component: usize,
    all_components_size: c_int,
) void {
    gl.enableVertexAttribArray(attribute_location);
    gl.vertexAttribPointer(
        attribute_location,
        component_count,
        gl.FLOAT,
        0,
        all_components_size,
        @intToPtr(?*u8, offset_to_first_component),
    );
    gl.vertexAttribDivisor(attribute_location, 1);
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
    gl.uniform1iv(loc_texture_sampler, 1, &texture_sampler_id);
    gl.useProgram(0);
}

fn renderStandingQuadInstanced(instance_count: usize) void {
    const vertex_count = meshes.StandingQuad.vertex_data.len / 2;
    gl.drawArraysInstanced(gl.TRIANGLES, 0, vertex_count, @intCast(c_int, instance_count));
}
