const Geometry = @import("geometry.zig");
const ObjectIdGenerator = @import("../util.zig").ObjectIdGenerator;
const ScreenDimensions = @import("../rendering.zig").ScreenDimensions;
const math = @import("../math.zig");
const std = @import("std");
const textures = @import("../textures.zig");

pub const Map = struct {
    geometry: Geometry,

    /// Returned object will keep a reference to the given allocator.
    pub fn createEmpty(allocator: std.mem.Allocator, object_id_generator: *ObjectIdGenerator) !Map {
        var geometry = try Geometry.create(allocator, object_id_generator);
        errdefer geometry.destroy();

        return .{ .geometry = geometry };
    }

    /// Returned object will keep a reference to the given allocator.
    pub fn createFromSerializableData(
        allocator: std.mem.Allocator,
        object_id_generator: *ObjectIdGenerator,
        spritesheet: textures.SpriteSheetTexture,
        data: SerializableData,
    ) !Map {
        var geometry = try Geometry.createFromSerializableData(
            allocator,
            object_id_generator,
            spritesheet,
            .{
                .walls = data.walls,
                .floors = data.floors,
                .billboard_objects = data.billboard_objects,
            },
        );
        errdefer geometry.destroy();

        return .{ .geometry = geometry };
    }

    pub fn destroy(self: *Map) void {
        self.geometry.destroy();
    }

    /// Returned result must be freed with freeSerializableData().
    pub fn toSerializableData(self: Map, allocator: std.mem.Allocator) !SerializableData {
        const serialized_geometry = try self.geometry.toSerializableData(allocator);
        errdefer Geometry.freeSerializableData(allocator, serialized_geometry);

        return .{
            .walls = serialized_geometry.walls,
            .floors = serialized_geometry.floors,
            .billboard_objects = serialized_geometry.billboard_objects,
        };
    }

    pub const SerializableData = struct {
        /// Data from Geometry.SerializableData is duplicated here to prevent json nesting.
        walls: []Geometry.SerializableData.Wall,
        floors: []Geometry.SerializableData.Floor,
        billboard_objects: []Geometry.SerializableData.BillboardObject,
    };

    pub fn freeSerializableData(allocator: std.mem.Allocator, data: *SerializableData) void {
        allocator.free(data.billboard_objects);
        allocator.free(data.floors);
        allocator.free(data.walls);
    }

    pub fn processElapsedTick(self: *Map) void {
        self.geometry.processElapsedTick();
    }

    pub fn prepareRender(self: *Map, spritesheet: textures.SpriteSheetTexture) !void {
        try self.geometry.prepareRender(spritesheet);
    }

    pub fn render(
        self: Map,
        vp_matrix: math.Matrix,
        screen_dimensions: ScreenDimensions,
        camera_direction_to_target: math.Vector3d,
        tileable_textures: textures.TileableArrayTexture,
        spritesheet: textures.SpriteSheetTexture,
    ) void {
        self.geometry.render(
            vp_matrix,
            screen_dimensions,
            camera_direction_to_target,
            tileable_textures,
            spritesheet,
        );
    }
};
