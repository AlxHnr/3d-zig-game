const Shader = @import("shader.zig").Shader;
const animation = @import("animation.zig");
const assert = std.debug.assert;
const fp = math.Fix32.fp;
const gl = @import("gl");
const math = @import("math.zig");
const meshes = @import("meshes.zig");
const std = @import("std");

pub const ScreenDimensions = extern struct { w: u16, h: u16 };

/// Texture pixel coordinates, starting at the top left corner of the sprite at (0, 0).
pub const TextureSourceRectangle = extern struct { x: u16, y: u16, w: u16, h: u16 };

/// Values from 0 to 255.
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,

    /// Used as a neutral tint during color multiplication.
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };

    pub fn create(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn lerp(self: Color, other: Color, t: math.Fix32) Color {
        return .{
            .r = fp(self.r).lerp(fp(other.r), t).clamp(fp(0), fp(255)).convertTo(u8),
            .g = fp(self.g).lerp(fp(other.g), t).clamp(fp(0), fp(255)).convertTo(u8),
            .b = fp(self.b).lerp(fp(other.b), t).clamp(fp(0), fp(255)).convertTo(u8),
        };
    }
};

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
            @embedFile("./shader/map_geometry.frag"),
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
        setupMapGeometryPropertyAttributes(
            WallData,
            loc_model_matrix,
            loc_texture_layer_id,
            loc_tint,
        );
        setupVertexAttribute(
            loc_texture_repeat_dimensions,
            WallData,
            .texture_repeat_dimensions,
            false,
        );
        comptime {
            assert(@offsetOf(WallData, "properties") == 0);
            assert(@offsetOf(WallData, "texture_repeat_dimensions") == 72);
            assert(@sizeOf(WallData) == 84);
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
            @intCast(self.walls_uploaded_to_vbo),
        );
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, 0);
        gl.bindVertexArray(0);
        gl.useProgram(0);
    }

    pub const WallData = extern struct {
        properties: MapGeometryAttributes,
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
            @embedFile("./shader/map_geometry.frag"),
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
        setupMapGeometryPropertyAttributes(
            FloorData,
            loc_model_matrix,
            loc_texture_layer_id,
            loc_tint,
        );
        setupVertexAttribute(
            loc_affected_by_animation_cycle,
            FloorData,
            .affected_by_animation_cycle,
            false,
        );
        setupVertexAttribute(
            loc_texture_repeat_dimensions,
            FloorData,
            .texture_repeat_dimensions,
            false,
        );
        comptime {
            assert(@offsetOf(FloorData, "properties") == 0);
            assert(@offsetOf(FloorData, "affected_by_animation_cycle") == 72);
            assert(@offsetOf(FloorData, "texture_repeat_dimensions") == 76);
            assert(@sizeOf(FloorData) == 84);
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
        properties: MapGeometryAttributes,
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
pub const MapGeometryAttributes = extern struct {
    model_matrix: [16]f32,
    /// Index of the layer in the array texture passed to render(). Will be rounded.
    texture_layer_id: f32,
    tint: Color,
};

/// Renders 2d sprites in screen space where all sizes are specified in pixels. Screen space starts
/// at the top-left corner of the screen at (0, 0) and goes to (screen_w, screen_h).
pub const SpriteRenderer = struct {
    renderer: BillboardRenderer,

    pub fn create() !SpriteRenderer {
        var renderer = try BillboardRenderer.create();
        errdefer renderer.destroy();

        // Invert the Y axis of the wrapped renderers quad mesh.
        var vertex_data = meshes.StandingQuad.vertex_data;
        var index: usize = 1;
        while (index < vertex_data.len) : (index += 4) {
            vertex_data[index] *= -1;
        }
        var size: usize = @sizeOf(@TypeOf(vertex_data));
        updateVbo(renderer.vertex_vbo_id, &vertex_data, size, &size, gl.STATIC_DRAW);

        return .{ .renderer = renderer };
    }

    pub fn destroy(self: *SpriteRenderer) void {
        self.renderer.destroy();
    }

    /// Sprites are rendered in the same order as specified.
    pub fn uploadSprites(self: *SpriteRenderer, sprites: []const SpriteData) void {
        self.renderer.uploadBillboards(sprites);
    }

    pub fn render(
        self: SpriteRenderer,
        screen_dimensions: ScreenDimensions,
        texture_id: c_uint,
    ) void {
        const screen_to_ndc_matrix = .{ .rows = .{
            .{ 2 / @as(f32, @floatFromInt(screen_dimensions.w)), 0, 0, -1 },
            .{ 0, -2 / @as(f32, @floatFromInt(screen_dimensions.h)), 0, 1 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 1 },
        } };
        const forward = .{ .x = fp(0), .y = fp(0), .z = fp(-1) };
        self.renderer.render(screen_to_ndc_matrix, screen_dimensions, forward, texture_id);
    }
};

/// Renders 2d sprites in 3d space which rotate around the Y axis towards the camera.
pub const BillboardRenderer = struct {
    vao_id: c_uint,
    vertex_vbo_id: c_uint,
    sprite_data_vbo_id: c_uint,
    sprites_uploaded_to_vbo: usize,
    sprite_capacity_in_vbo: usize,
    shader: Shader,
    y_rotation_location: c_int,
    screen_dimensions_location: c_int,
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
        const loc_offset_from_origin = try shader.getAttributeLocation("offset_from_origin");
        const loc_z_rotation = try shader.getAttributeLocation("z_rotation");
        const loc_source_rect = try shader.getAttributeLocation("source_rect");
        const loc_tint = try shader.getAttributeLocation("tint");
        const loc_preserve_exact_pixel_size =
            try shader.getAttributeLocation("preserve_exact_pixel_size");
        const loc_y_rotation_towards_camera =
            try shader.getUniformLocation("y_rotation_towards_camera");
        const loc_screen_dimensions = try shader.getUniformLocation("screen_dimensions");
        const loc_vp_matrix = try shader.getUniformLocation("vp_matrix");
        const loc_texture_sampler = try shader.getUniformLocation("texture_sampler");

        const vao_id = createAndBindVao();
        const vertex_vbo_id = setupAndBindStandingQuadVbo(loc_vertex_position, loc_texture_coords);
        const sprite_data_vbo_id = createAndBindEmptyVbo();
        setupVertexAttribute(loc_billboard_center_position, SpriteData, .position, false);
        setupVertexAttribute(loc_size, SpriteData, .size, false);
        setupVertexAttribute(loc_offset_from_origin, SpriteData, .offset_from_origin, false);
        setupVertexAttribute(loc_z_rotation, SpriteData, .z_rotation, false);
        setupVertexAttribute(loc_source_rect, SpriteData, .source_rect, false);
        setupVertexAttribute(loc_tint, SpriteData, .tint, true);
        setupVertexAttribute(
            loc_preserve_exact_pixel_size,
            SpriteData,
            .preserve_exact_pixel_size,
            false,
        );
        comptime {
            assert(@offsetOf(SpriteData, "position") == 0);
            assert(@offsetOf(SpriteData, "size") == 12);
            assert(@offsetOf(SpriteData, "offset_from_origin") == 20);
            assert(@offsetOf(SpriteData, "z_rotation") == 28);
            assert(@offsetOf(SpriteData, "source_rect") == 32);
            assert(@offsetOf(SpriteData, "tint") == 40);
            assert(@offsetOf(SpriteData, "preserve_exact_pixel_size") == 43);
            assert(@sizeOf(SpriteData) == 44);
        }

        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        setTextureSamplerId(shader, loc_texture_sampler);

        return BillboardRenderer{
            .vao_id = vao_id,
            .vertex_vbo_id = vertex_vbo_id,
            .sprite_data_vbo_id = sprite_data_vbo_id,
            .sprites_uploaded_to_vbo = 0,
            .sprite_capacity_in_vbo = 0,
            .shader = shader,
            .y_rotation_location = loc_y_rotation_towards_camera,
            .screen_dimensions_location = loc_screen_dimensions,
            .vp_matrix_location = loc_vp_matrix,
        };
    }

    pub fn destroy(self: *BillboardRenderer) void {
        self.shader.destroy();
        gl.deleteBuffers(1, &self.sprite_data_vbo_id);
        gl.deleteBuffers(1, &self.vertex_vbo_id);
        gl.deleteVertexArrays(1, &self.vao_id);
    }

    /// Billboards are rendered in the same order as specified.
    pub fn uploadBillboards(self: *BillboardRenderer, billboards: []const SpriteData) void {
        updateVbo(
            self.sprite_data_vbo_id,
            billboards.ptr,
            billboards.len * @sizeOf(SpriteData),
            &self.sprite_capacity_in_vbo,
            gl.STREAM_DRAW,
        );
        self.sprites_uploaded_to_vbo = billboards.len;
    }

    pub fn render(
        self: BillboardRenderer,
        vp_matrix: math.Matrix,
        screen_dimensions: ScreenDimensions,
        camera_direction: math.Vector3d,
        texture_id: c_uint,
    ) void {
        const camera_rotation_to_z_axis = camera_direction.toFlatVector()
            .computeRotationToOtherVector(.{ .x = fp(0), .z = fp(-1) });
        const y_rotation_towards_camera = [2]f32{
            camera_rotation_to_z_axis.sin().convertTo(f32),
            camera_rotation_to_z_axis.cos().convertTo(f32),
        };
        const screen_dimensions_f32 = [2]f32{
            @as(f32, @floatFromInt(screen_dimensions.w)),
            @as(f32, @floatFromInt(screen_dimensions.h)),
        };

        self.shader.enable();
        gl.bindVertexArray(self.vao_id);
        gl.bindTexture(gl.TEXTURE_2D, texture_id);
        gl.uniform2fv(self.y_rotation_location, 1, &y_rotation_towards_camera);
        gl.uniform2fv(self.screen_dimensions_location, 1, &screen_dimensions_f32);
        gl.uniformMatrix4fv(self.vp_matrix_location, 1, 0, &vp_matrix.toFloatArray());
        renderStandingQuadInstanced(self.sprites_uploaded_to_vbo);
        gl.bindTexture(gl.TEXTURE_2D, 0);
        gl.bindVertexArray(0);
        gl.useProgram(0);
    }
};

/// Data laid out for upload to the GPU. The values in this struct depend on whether they are used
/// for rendering 2d sprites or 3d billboards.
///
/// * For 2d sprites the x, y, w and h values are specified in pixels. Screen coordinates start at
///   the top-left corner of the screen at (0, 0) and go to (screen_w, screen_h). Z coordinates are
///   ignored.
/// * For 3d billboards the x, y, z and w, h values are specified in game-units relative to the game
///   world.
pub const SpriteData = extern struct {
    /// Center of the object.
    position: extern struct { x: f32, y: f32, z: f32 },
    size: extern struct { w: f32, h: f32 },
    /// Will be applied after scaling but before Z rotation. Can be used to preserve character
    /// order when rendering text.
    offset_from_origin: extern struct { x: f32, y: f32 },
    /// Angle in radians for rotating the sprite around its Z axis.
    z_rotation: f32,
    /// Specifies the part of the currently bound texture which should be stretched onto the
    /// billboard.
    source_rect: TextureSourceRectangle,
    tint: Color,
    /// False if the billboard should shrink with increasing camera distance.
    /// True if the billboard should have a fixed pixel size independently from its distance to the
    /// camera. Only relevant for `BillboardRenderer`.
    preserve_exact_pixel_size: bool,

    pub fn create(
        position: math.Vector3d,
        source_rect: TextureSourceRectangle,
        size_w: math.Fix32,
        size_h: math.Fix32,
    ) SpriteData {
        return std.mem.zeroes(SpriteData)
            .withPosition(position)
            .withSourceRect(source_rect)
            .withSize(size_w, size_h)
            .withTint(Color.white);
    }

    pub fn withPosition(self: SpriteData, position: math.Vector3d) SpriteData {
        var copy = self;
        copy.position.x = position.x.convertTo(f32);
        copy.position.y = position.y.convertTo(f32);
        copy.position.z = position.z.convertTo(f32);
        return copy;
    }

    pub fn withSize(self: SpriteData, w: math.Fix32, h: math.Fix32) SpriteData {
        var copy = self;
        copy.size.w = w.convertTo(f32);
        copy.size.h = h.convertTo(f32);
        return copy;
    }

    pub fn withOffsetFromOrigin(self: SpriteData, x: math.Fix32, y: math.Fix32) SpriteData {
        var copy = self;
        copy.offset_from_origin.x = x.convertTo(f32);
        copy.offset_from_origin.y = y.convertTo(f32);
        return copy;
    }

    pub fn withZRotation(self: SpriteData, angle: math.Fix32) SpriteData {
        var copy = self;
        copy.z_rotation = angle.convertTo(f32);
        return copy;
    }

    pub fn withSourceRect(self: SpriteData, source: TextureSourceRectangle) SpriteData {
        var copy = self;
        copy.source_rect = source;
        return copy;
    }

    pub fn withTint(self: SpriteData, tint: Color) SpriteData {
        var copy = self;
        copy.tint = tint;
        return copy;
    }

    pub fn withPreserveExactPixelSize(self: SpriteData, preserve: bool) SpriteData {
        var copy = self;
        copy.preserve_exact_pixel_size = preserve;
        return copy;
    }
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
    gl.vertexAttribPointer(texture_coords_location, 2, gl.FLOAT, 0, stride, @ptrFromInt(
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
    const signed_size = @as(isize, @intCast(size));

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
    comptime ComponentType: type,
    comptime field: std.meta.FieldEnum(ComponentType),
    normalize: bool,
) void {
    const type_info = @typeInfo(std.meta.FieldType(ComponentType, field));
    const component_count = switch (type_info) {
        .Struct => type_info.Struct.fields.len,
        .Float, .Int, .Bool => 1,
        else => @compileError("unsupported type :" ++ @typeName(@Type(type_info))),
    };
    comptime {
        std.debug.assert(component_count > 0);
    }

    const component_type = switch (type_info) {
        .Struct => type_info.Struct.fields[0].type,
        else => @Type(type_info),
    };
    setupVertexAttributeRaw(
        attribute_location,
        component_type,
        component_count,
        @offsetOf(ComponentType, @tagName(field)),
        normalize,
        @sizeOf(ComponentType),
    );
}

fn setupVertexAttributeRaw(
    attribute_location: c_uint,
    comptime component_type: type,
    component_count: c_int,
    offset_to_first_component: usize,
    normalize: bool,
    all_components_size: c_int,
) void {
    const gl_type = switch (@typeInfo(component_type)) {
        .Bool => gl.UNSIGNED_BYTE,
        .Float => gl.FLOAT,
        .Int => |int| switch (int.bits) {
            8 => if (int.signedness == .signed) gl.BYTE else gl.UNSIGNED_BYTE,
            16 => if (int.signedness == .signed) gl.SHORT else gl.UNSIGNED_SHORT,
            else => |bits| @compileError("unsupported integer size: " ++ bits),
        },
        else => @compileError("unsupported type: " ++ @typeName(component_type)),
    };

    gl.enableVertexAttribArray(attribute_location);
    gl.vertexAttribPointer(
        attribute_location,
        component_count,
        gl_type,
        @intFromBool(normalize),
        all_components_size,
        @ptrFromInt(offset_to_first_component),
    );
    gl.vertexAttribDivisor(attribute_location, 1);
}

/// Configures MapGeometryAttributes as vertex attributes at offset 0.
fn setupMapGeometryPropertyAttributes(
    comptime ComponentType: type,
    loc_model_matrix: c_uint,
    loc_texture_layer_id: c_uint,
    loc_tint: c_uint,
) void {
    const stride = @sizeOf(ComponentType);

    // Matrices (mat4) are specified in groups of 4 floats.
    setupVertexAttributeRaw(loc_model_matrix + 0, f32, 4, 0, false, stride);
    setupVertexAttributeRaw(loc_model_matrix + 1, f32, 4, @sizeOf([4]f32), false, stride);
    setupVertexAttributeRaw(loc_model_matrix + 2, f32, 4, @sizeOf([8]f32), false, stride);
    setupVertexAttributeRaw(loc_model_matrix + 3, f32, 4, @sizeOf([12]f32), false, stride);
    setupVertexAttributeRaw(loc_texture_layer_id, f32, 1, @offsetOf(
        MapGeometryAttributes,
        "texture_layer_id",
    ), false, stride);
    setupVertexAttributeRaw(loc_tint, u8, 3, @offsetOf(
        MapGeometryAttributes,
        "tint",
    ), true, stride);
    comptime {
        assert(@offsetOf(MapGeometryAttributes, "model_matrix") == 0);
        assert(@offsetOf(MapGeometryAttributes, "texture_layer_id") == 64);
        assert(@offsetOf(MapGeometryAttributes, "tint") == 68);
        assert(@sizeOf(MapGeometryAttributes) == 72);
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
    gl.drawArraysInstanced(gl.TRIANGLES, 0, vertex_count, @intCast(instance_count));
}
