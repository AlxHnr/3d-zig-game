const Error = @import("../error.zig").Error;
const ThirdPersonCamera = @import("../third_person_camera.zig");
const animation = @import("../animation.zig");
const cell_line_iterator = @import("../spatial_partitioning/cell_line_iterator.zig").iterator;
const collision = @import("../collision.zig");
const fp = math.Fix32.fp;
const gl = @import("gl");
const math = @import("../math.zig");
const meshes = @import("../meshes.zig");
const rendering = @import("../rendering.zig");
const simulation = @import("../simulation.zig");
const spatial_partitioning = @import("../spatial_partitioning/grid.zig");
const std = @import("std");
const textures = @import("../textures.zig");
const util = @import("../util.zig");

const Geometry = @This();

id: u64,
change_counter: u32,
allocator: std.mem.Allocator,

walls: struct {
    /// Solid walls have no transparency and are able to block the camera.
    solid: std.ArrayList(Wall),

    /// Translucent walls can be partially transparency and get rendered last. This is needed
    /// for implementing fences. Translucent walls don't obstruct the camera and allow gems to
    /// be collected trough them.
    translucent: std.ArrayList(Wall),
},

spatial_wall_index: struct { all: SpatialGrid, solid: SpatialGrid },
obstacle_grid: ObstacleGrid,

/// Floors in this array will be rendered last to first without overpainting one another. This
/// leads to the last floor in the array being shown above all others.
floors: std.ArrayList(Floor),
floor_animation_state: animation.FourStepCycle,

billboard_objects: std.ArrayList(BillboardObject),

pub const obstacle_grid_cell_size = 5;

const spatial_grid_cell_size = 20;
const SpatialGrid =
    spatial_partitioning.Grid(collision.Rectangle, spatial_grid_cell_size, .insert_remove);

/// Stores the given allocator internally for its entire lifetime.
pub fn create(
    allocator: std.mem.Allocator,
    object_id_generator: *util.ObjectIdGenerator,
) !Geometry {
    return .{
        .id = object_id_generator.makeNewId(),
        .change_counter = 0,
        .allocator = allocator,
        .walls = .{
            .solid = std.ArrayList(Wall).init(allocator),
            .translucent = std.ArrayList(Wall).init(allocator),
        },
        .spatial_wall_index = .{
            .all = SpatialGrid.create(allocator),
            .solid = SpatialGrid.create(allocator),
        },
        .obstacle_grid = ObstacleGrid.create(),
        .floors = std.ArrayList(Floor).init(allocator),
        .floor_animation_state = animation.FourStepCycle.create(),
        .billboard_objects = std.ArrayList(BillboardObject).init(allocator),
    };
}

pub fn destroy(self: *Geometry) void {
    self.billboard_objects.deinit();
    self.floors.deinit();

    self.obstacle_grid.destroy(self.allocator);
    self.spatial_wall_index.solid.destroy();
    self.spatial_wall_index.all.destroy();

    self.walls.translucent.deinit();
    self.walls.solid.deinit();
}

/// Stores the given allocator internally for its entire lifetime.
pub fn createFromSerializableData(
    allocator: std.mem.Allocator,
    object_id_generator: *util.ObjectIdGenerator,
    spritesheet: textures.SpriteSheetTexture,
    data: SerializableData,
) !Geometry {
    var geometry = try create(allocator, object_id_generator);
    errdefer geometry.destroy();

    for (data.walls) |wall| {
        const wall_type = std.meta.stringToEnum(WallType, wall.t) orelse {
            return Error.FailedToDeserializeMapGeometry;
        };
        _ = try geometry
            .addWallUncached(object_id_generator, wall.start, wall.end, wall_type);
    }
    for (data.floors) |floor| {
        const floor_type = std.meta.stringToEnum(FloorType, floor.t) orelse {
            return Error.FailedToDeserializeMapGeometry;
        };
        _ = try geometry.addFloorUncached(
            object_id_generator,
            floor.side_a_start,
            floor.side_a_end,
            floor.side_b_length,
            floor_type,
        );
    }
    for (data.billboard_objects) |billboard| {
        const object_type = std.meta.stringToEnum(BillboardObjectType, billboard.t) orelse {
            return Error.FailedToDeserializeMapGeometry;
        };
        _ = try geometry.addBillboardObjectUncached(
            object_id_generator,
            object_type,
            billboard.pos,
            spritesheet,
        );
    }

    try geometry.updateCache();
    return geometry;
}

pub fn processElapsedTick(self: *Geometry) void {
    self.floor_animation_state.processElapsedTick(
        math.Fix64.fp(1).div(simulation.secondsToTicks(0.8)).convertTo(f32),
    );
}

/// Returned result must be freed with freeSerializableData().
pub fn toSerializableData(self: Geometry, allocator: std.mem.Allocator) !SerializableData {
    var walls = try allocator.alloc(
        SerializableData.Wall,
        self.walls.solid.items.len + self.walls.translucent.items.len,
    );
    errdefer allocator.free(walls);
    for (self.walls.solid.items, 0..) |wall, index| {
        walls[index] = .{
            .t = @tagName(wall.wall_type),
            .start = wall.start_position,
            .end = wall.end_position,
        };
    }
    for (self.walls.translucent.items, 0..) |wall, index| {
        walls[self.walls.solid.items.len + index] = .{
            .t = @tagName(wall.wall_type),
            .start = wall.start_position,
            .end = wall.end_position,
        };
    }

    var floors = try allocator.alloc(SerializableData.Floor, self.floors.items.len);
    errdefer allocator.free(floors);
    for (self.floors.items, 0..) |floor, index| {
        floors[index] = .{
            .t = @tagName(floor.floor_type),
            .side_a_start = floor.side_a_start,
            .side_a_end = floor.side_a_end,
            .side_b_length = floor.side_b_length,
        };
    }

    var billboards = try allocator.alloc(SerializableData.BillboardObject, self.billboard_objects.items.len);
    errdefer allocator.free(billboards);
    for (self.billboard_objects.items, 0..) |billboard, index| {
        billboards[index] = .{
            .t = @tagName(billboard.object_type),
            .pos = billboard.boundaries.position,
        };
    }

    return .{ .walls = walls, .floors = floors, .billboard_objects = billboards };
}

pub fn populateRenderSnapshot(self: Geometry, snapshot: *RenderSnapshot) !void {
    snapshot.floor_animation_state = self.floor_animation_state;
    if (!snapshot.render_data_upload_info.syncIfNeededWithGeometry(self)) {
        return;
    }

    snapshot.wall_data.clearRetainingCapacity();
    snapshot.solid_walls.clearRetainingCapacity();
    for (self.walls.solid.items) |wall| {
        try snapshot.wall_data.append(wall.getWallData());
        try snapshot.solid_walls.append(
            .{ .wall_type = wall.wall_type, .boundaries = wall.boundaries },
        );
    }
    for (self.walls.translucent.items) |wall| {
        try snapshot.wall_data.append(wall.getWallData());
    }

    snapshot.floor_data.clearRetainingCapacity();
    for (0..self.floors.items.len) |index| {
        const inverted_index = self.floors.items.len - index - 1;
        const floor = self.floors.items[inverted_index];
        const side_a_length = floor.side_a_end.subtract(floor.side_a_start).length().convertTo(f32);
        try snapshot.floor_data.append(.{
            .properties = makeRenderingAttributes(
                floor.model_matrix,
                floor.getTextureLayerId(),
                floor.tint,
            ),
            .affected_by_animation_cycle = if (floor.isAffectedByAnimationCycle()) 1 else 0,
            .texture_repeat_dimensions = .{
                .x = floor.side_b_length.div(floor.getTextureScale()).convertTo(f32),
                .y = side_a_length / floor.getTextureScale().convertTo(f32),
            },
        });
    }

    snapshot.billboard_data.clearRetainingCapacity();
    for (self.billboard_objects.items) |billboard| {
        try snapshot.billboard_data.append(billboard.sprite_data);
    }
}

pub const RenderSnapshot = struct {
    wall_data: std.ArrayList(rendering.WallRenderer.WallData),
    solid_walls: std.ArrayList(PartialWallData),
    floor_data: std.ArrayList(rendering.FloorRenderer.FloorData),
    floor_animation_state: animation.FourStepCycle,
    billboard_data: std.ArrayList(rendering.SpriteData),
    render_data_upload_info: RenderDataUploadInfo,

    pub fn create(allocator: std.mem.Allocator) RenderSnapshot {
        return .{
            .wall_data = std.ArrayList(rendering.WallRenderer.WallData).init(allocator),
            .solid_walls = std.ArrayList(PartialWallData).init(allocator),
            .floor_data = std.ArrayList(rendering.FloorRenderer.FloorData).init(allocator),
            .floor_animation_state = animation.FourStepCycle.create(),
            .billboard_data = std.ArrayList(rendering.SpriteData).init(allocator),
            .render_data_upload_info = RenderDataUploadInfo.create(),
        };
    }

    pub fn destroy(self: *RenderSnapshot) void {
        self.billboard_data.deinit();
        self.floor_data.deinit();
        self.solid_walls.deinit();
        self.wall_data.deinit();
    }

    pub fn cast3DRayToSolidWalls(
        self: RenderSnapshot,
        ray: collision.Ray3d,
    ) ?collision.Ray3d.ImpactPoint {
        var ray_collision: ?RayCollision = null;
        for (self.solid_walls.items) |wall| {
            ray_collision = getCloserRayCollision(
                Wall.collidesWithRay(wall.wall_type, wall.boundaries, ray),
                0, // Not used.
                ray_collision,
            );
        }
        return if (ray_collision) |result|
            result.impact_point
        else
            null;
    }

    const PartialWallData = struct {
        wall_type: WallType,
        boundaries: collision.Rectangle,
    };
};

pub const Renderer = struct {
    wall_renderer: rendering.WallRenderer,
    floor_renderer: rendering.FloorRenderer,
    floor_animation_state: animation.FourStepCycle,
    billboard_renderer: rendering.BillboardRenderer,
    render_data_upload_info: RenderDataUploadInfo,

    pub fn create() !Renderer {
        var wall_renderer = try rendering.WallRenderer.create();
        errdefer wall_renderer.destroy();
        var floor_renderer = try rendering.FloorRenderer.create();
        errdefer floor_renderer.destroy();
        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        return .{
            .wall_renderer = wall_renderer,
            .floor_renderer = floor_renderer,
            .floor_animation_state = animation.FourStepCycle.create(),
            .billboard_renderer = billboard_renderer,
            .render_data_upload_info = RenderDataUploadInfo.create(),
        };
    }

    pub fn destroy(self: *Renderer) void {
        self.billboard_renderer.destroy();
        self.floor_renderer.destroy();
        self.wall_renderer.destroy();
    }

    pub fn uploadRenderSnapshot(self: *Renderer, snapshot: RenderSnapshot) void {
        if (self.render_data_upload_info.syncIfNeeded(snapshot.render_data_upload_info)) {
            self.wall_renderer.uploadWalls(snapshot.wall_data.items);
            self.floor_renderer.uploadFloors(snapshot.floor_data.items);
            self.billboard_renderer.uploadBillboards(snapshot.billboard_data.items);
        }
        self.floor_animation_state = snapshot.floor_animation_state;
    }

    pub fn render(
        self: Renderer,
        vp_matrix: math.Matrix,
        screen_dimensions: util.ScreenDimensions,
        camera_direction_to_target: math.Vector3d,
        tileable_textures: textures.TileableArrayTexture,
        spritesheet: textures.SpriteSheetTexture,
    ) void {
        // Prevent floors from overpainting each other.
        gl.stencilFunc(gl.NOTEQUAL, 1, 0xff);
        self.floor_renderer.render(vp_matrix, tileable_textures.id, self.floor_animation_state);
        gl.stencilFunc(gl.ALWAYS, 1, 0xff);

        // Fences must be rendered after the floor to allow blending transparent, mipmapped texels.
        self.wall_renderer.render(vp_matrix, tileable_textures.id);
        self.billboard_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera_direction_to_target.toVector3dF32(),
            spritesheet.id,
        );
    }
};

/// Simplified representation of a maps geometry.
pub const SerializableData = struct {
    walls: []SerializableData.Wall,
    floors: []SerializableData.Floor,
    billboard_objects: []SerializableData.BillboardObject,

    pub const Wall = struct {
        /// Type enum as string.
        t: []const u8,
        start: math.FlatVector,
        end: math.FlatVector,
    };

    pub const Floor = struct {
        /// Type enum as string.
        t: []const u8,
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
        side_b_length: math.Fix32,
    };

    pub const BillboardObject = struct {
        /// Type enum as string.
        t: []const u8,
        pos: math.FlatVector,
    };
};

pub fn freeSerializableData(allocator: std.mem.Allocator, data: *SerializableData) void {
    allocator.free(data.billboard_objects);
    allocator.free(data.floors);
    allocator.free(data.walls);
}

pub const WallType = enum {
    small_wall,
    medium_wall,
    castle_wall,
    castle_tower,
    metal_fence,
    short_metal_fence,
    tall_hedge,
    giga_wall,
};

/// Returns the object id of the created wall on success.
pub fn addWall(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    start_position: math.FlatVector,
    end_position: math.FlatVector,
    wall_type: WallType,
) !u64 {
    const wall_id = try self.addWallUncached(
        object_id_generator,
        start_position,
        end_position,
        wall_type,
    );
    errdefer self.removeObjectUncached(wall_id);
    try self.updateCache();
    return wall_id;
}

pub fn removeObject(self: *Geometry, object_id: u64) !void {
    self.removeObjectUncached(object_id);
    try self.updateCache();
}

/// If the given object id does not exist, this function will do nothing.
pub fn updateWall(
    self: *Geometry,
    object_id: u64,
    start_position: math.FlatVector,
    end_position: math.FlatVector,
) !void {
    var wall = self.findWall(object_id) orelse return;
    var old_wall = wall.*;
    wall.* = Wall.create(
        object_id,
        old_wall.wall_type,
        start_position,
        end_position,
    );
    wall.tint = old_wall.tint;

    self.removeWallFromSpatialGrid(&old_wall);
    wall.grid_handles.all =
        try insertWallIntoSpatialGrid(&self.spatial_wall_index.all, wall.*);
    if (!Wall.isFence(wall.wall_type)) {
        wall.grid_handles.solid =
            try insertWallIntoSpatialGrid(&self.spatial_wall_index.solid, wall.*);
    }
    try self.updateCache();
}

pub const FloorType = enum {
    grass,
    stone,
    water,
};

/// Side a and b can be chosen arbitrarily, but must be adjacent. Returns the object id of the
/// created floor on success.
pub fn addFloor(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    side_a_start: math.FlatVector,
    side_a_end: math.FlatVector,
    side_b_length: math.Fix32,
    floor_type: FloorType,
) !u64 {
    const floor_id = try self.addFloorUncached(
        object_id_generator,
        side_a_start,
        side_a_end,
        side_b_length,
        floor_type,
    );
    errdefer self.removeObjectUncached(floor_id);
    try self.updateCache();
    return floor_id;
}

/// If the given object id does not exist, this function will do nothing.
pub fn updateFloor(
    self: *Geometry,
    object_id: u64,
    side_a_start: math.FlatVector,
    side_a_end: math.FlatVector,
    side_b_length: math.Fix32,
) !void {
    var floor = self.findFloor(object_id) orelse return;
    const tint = floor.tint;
    floor.* = Floor.create(
        object_id,
        floor.floor_type,
        side_a_start,
        side_a_end,
        side_b_length,
    );
    floor.tint = tint;
    try self.updateCache();
}

pub const BillboardObjectType = enum {
    small_bush,
};

/// Returns the object id of the created billboard object on success.
pub fn addBillboardObject(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    object_type: BillboardObjectType,
    position: math.FlatVector,
    spritesheet: textures.SpriteSheetTexture,
) !u64 {
    const billboard_id = try self.addBillboardObjectUncached(
        object_id_generator,
        object_type,
        position,
        spritesheet,
    );
    errdefer self.removeObjectUncached(billboard_id);
    try self.updateCache();
    return billboard_id;
}

pub fn tintObject(self: *Geometry, object_id: u64, tint: util.Color) !void {
    if (self.findWall(object_id)) |wall| {
        wall.tint = tint;
    } else if (self.findFloor(object_id)) |floor| {
        floor.tint = tint;
    } else if (self.findBillboardObject(object_id)) |billboard| {
        billboard.setTint(tint);
    }
    try self.updateCache();
}

pub fn untintObject(self: *Geometry, object_id: u64) !void {
    if (self.findWall(object_id)) |wall| {
        wall.tint = Wall.getDefaultTint(wall.wall_type);
    } else if (self.findFloor(object_id)) |floor| {
        floor.tint = Floor.getDefaultTint(floor.floor_type);
    } else if (self.findBillboardObject(object_id)) |billboard| {
        billboard.setTint(BillboardObject.getDefaultTint(billboard.object_type));
    }
    try self.updateCache();
}

pub const RayCollision = struct {
    object_id: u64,
    impact_point: collision.Ray3d.ImpactPoint,
};

/// Find the id of the closest wall hit by the given ray, if available.
pub fn cast3DRayToWalls(self: Geometry, ray: collision.Ray3d) ?RayCollision {
    var result: ?RayCollision = null;
    for (self.walls.solid.items) |wall| {
        result = getCloserRayCollision(
            Wall.collidesWithRay(wall.wall_type, wall.boundaries, ray),
            wall.object_id,
            result,
        );
    }
    for (self.walls.translucent.items) |wall| {
        result = getCloserRayCollision(
            Wall.collidesWithRay(wall.wall_type, wall.boundaries, ray),
            wall.object_id,
            result,
        );
    }
    return result;
}

/// Find the id of the closest object hit by the given ray, if available.
pub fn cast3DRayToObjects(self: Geometry, ray: collision.Ray3d) ?RayCollision {
    var result = self.cast3DRayToWalls(ray);
    for (self.billboard_objects.items) |billboard| {
        result = getCloserRayCollision(billboard.cast3DRay(ray), billboard.object_id, result);
    }

    // Walls and billboards are covering floors and are prioritized.
    if (result != null) {
        return result;
    }

    const impact_point = ray.collidesWithGround() orelse return null;
    for (self.floors.items, 0..) |_, index| {
        // The last floor in this array is always drawn at the top.
        const floor = self.floors.items[self.floors.items.len - index - 1];
        if (floor.boundaries.collidesWithPoint(impact_point.position.toFlatVector())) {
            return RayCollision{
                .object_id = floor.object_id,
                .impact_point = impact_point,
            };
        }
    }
    return null;
}

/// If a collision occurs, return a displacement vector for moving the given circle out of the
/// map geometry. The returned displacement vector must be added to the given circles position
/// to resolve the collision.
pub fn collidesWithCircle(
    self: Geometry,
    circle: collision.Circle,
    ignore_fences: bool,
) ?math.FlatVector {
    var found_collision = false;
    var displaced_circle = circle;

    const spatial_index = if (ignore_fences)
        &self.spatial_wall_index.solid
    else
        &self.spatial_wall_index.all;

    // Move displaced_circle out of all walls.
    const bounding_box = circle.getOuterBoundingBoxInGameCoordinates();
    const bounding_boxF32 = .{
        .min = bounding_box.min.toFlatVectorF32(),
        .max = bounding_box.max.toFlatVectorF32(),
    };
    var iterator = spatial_index.areaIterator(bounding_boxF32);
    while (iterator.next()) |boundaries| {
        if (displaced_circle.collidesWithRectangle(boundaries)) |displacement_vector| {
            displaced_circle.position = displaced_circle.position.add(displacement_vector);
            found_collision = true;
        }
    }

    return if (found_collision)
        displaced_circle.position.subtract(circle.position)
    else
        null;
}

/// Check if two points are separated by a solid wall. Fences are not solid.
pub fn isSolidWallBetweenPoints(self: Geometry, a: math.FlatVector, b: math.FlatVector) bool {
    var iterator = self.spatial_wall_index.solid.straightLineIterator(
        a.toFlatVectorF32(),
        b.toFlatVectorF32(),
    );
    while (iterator.next()) |boundaries| {
        if (boundaries.collidesWithLine(a, b)) {
            return true;
        }
    }
    return false;
}

/// Return the type of obstacles bordering on the tile specified by the given position. This
/// check has the granularity of `obstacle_grid_cell_size` and is imprecise.
pub fn getObstacleTile(self: Geometry, position: math.FlatVector) TileType {
    return self.obstacle_grid.getObstacleTile(position);
}

pub const TileType = enum {
    none,
    neighbor_of_obstacle,
    obstacle_tranclucent,
    obstacle_solid,

    pub fn isObstacle(self: TileType) bool {
        return self == .obstacle_tranclucent or self == .obstacle_solid;
    }
};

/// Returns the object id of the created wall on success.
fn addWallUncached(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    start_position: math.FlatVector,
    end_position: math.FlatVector,
    wall_type: WallType,
) !u64 {
    const wall = try if (Wall.isFence(wall_type))
        self.walls.translucent.addOne()
    else
        self.walls.solid.addOne();
    wall.* = Wall.create(
        object_id_generator.makeNewId(),
        wall_type,
        start_position,
        end_position,
    );
    errdefer if (Wall.isFence(wall_type)) {
        _ = self.walls.translucent.pop();
    } else {
        _ = self.walls.solid.pop();
    };

    errdefer self.removeWallFromSpatialGrid(wall);
    wall.grid_handles.all = try insertWallIntoSpatialGrid(&self.spatial_wall_index.all, wall.*);
    if (!Wall.isFence(wall_type)) {
        wall.grid_handles.solid =
            try insertWallIntoSpatialGrid(&self.spatial_wall_index.solid, wall.*);
    }

    return wall.object_id;
}

fn addFloorUncached(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    side_a_start: math.FlatVector,
    side_a_end: math.FlatVector,
    side_b_length: math.Fix32,
    floor_type: FloorType,
) !u64 {
    const floor = try self.floors.addOne();
    floor.* = Floor.create(
        object_id_generator.makeNewId(),
        floor_type,
        side_a_start,
        side_a_end,
        side_b_length,
    );
    return floor.object_id;
}

fn addBillboardObjectUncached(
    self: *Geometry,
    object_id_generator: *util.ObjectIdGenerator,
    object_type: BillboardObjectType,
    position: math.FlatVector,
    spritesheet: textures.SpriteSheetTexture,
) !u64 {
    const billboard = try self.billboard_objects.addOne();
    billboard.* = BillboardObject.create(
        object_id_generator.makeNewId(),
        object_type,
        position,
        spritesheet,
    );
    return billboard.object_id;
}

/// If the given object id does not exist, this function will do nothing.
fn removeObjectUncached(self: *Geometry, object_id: u64) void {
    for (self.walls.solid.items, 0..) |*wall, index| {
        if (wall.object_id == object_id) {
            self.removeWallFromSpatialGrid(wall);
            _ = self.walls.solid.orderedRemove(index);
            return;
        }
    }
    for (self.walls.translucent.items, 0..) |*wall, index| {
        if (wall.object_id == object_id) {
            self.removeWallFromSpatialGrid(wall);
            _ = self.walls.translucent.orderedRemove(index);
            return;
        }
    }
    for (self.floors.items, 0..) |*floor, index| {
        if (floor.object_id == object_id) {
            _ = self.floors.orderedRemove(index);
            return;
        }
    }
    for (self.billboard_objects.items, 0..) |billboard, index| {
        if (billboard.object_id == object_id) {
            _ = self.billboard_objects.orderedRemove(index);
            return;
        }
    }
}

fn updateCache(self: *Geometry) !void {
    self.change_counter += 1;
    try self.obstacle_grid.recompute(self.*);
}

fn insertWallIntoSpatialGrid(grid: *SpatialGrid, wall: Wall) !*SpatialGrid.ObjectHandle {
    const boundaries = wall.boundaries.getCornersInGameCoordinates();
    const boundariesF32 = .{
        boundaries[0].toFlatVectorF32(),
        boundaries[1].toFlatVectorF32(),
        boundaries[2].toFlatVectorF32(),
        boundaries[3].toFlatVectorF32(),
    };
    return try grid.insertIntoPolygonBorders(
        wall.boundaries,
        &boundariesF32,
    );
}

fn removeWallFromSpatialGrid(self: *Geometry, wall: *Wall) void {
    if (wall.grid_handles.all) |handle| {
        self.spatial_wall_index.all.remove(handle);
        wall.grid_handles.all = null;
    }
    if (!Wall.isFence(wall.wall_type) and wall.grid_handles.solid != null) {
        self.spatial_wall_index.solid.remove(wall.grid_handles.solid.?);
        wall.grid_handles.solid = null;
    }
}

fn findWall(self: *Geometry, object_id: u64) ?*Wall {
    for (self.walls.solid.items) |*wall| {
        if (wall.object_id == object_id) {
            return wall;
        }
    }
    for (self.walls.translucent.items) |*wall| {
        if (wall.object_id == object_id) {
            return wall;
        }
    }
    return null;
}

fn findFloor(self: *Geometry, object_id: u64) ?*Floor {
    for (self.floors.items) |*floor| {
        if (floor.object_id == object_id) {
            return floor;
        }
    }
    return null;
}

fn findBillboardObject(self: *Geometry, object_id: u64) ?*BillboardObject {
    for (self.billboard_objects.items) |*billboard| {
        if (billboard.object_id == object_id) {
            return billboard;
        }
    }
    return null;
}

fn getCloserRayCollision(
    impact_point: ?collision.Ray3d.ImpactPoint,
    object_id: u64,
    current_collision: ?RayCollision,
) ?RayCollision {
    const point = impact_point orelse return current_collision;
    const current = current_collision orelse
        return .{ .object_id = object_id, .impact_point = point };
    if (point.distance_from_start_position.lt(current.impact_point.distance_from_start_position)) {
        return .{ .object_id = object_id, .impact_point = point };
    }
    return current_collision;
}

const Floor = struct {
    object_id: u64,
    floor_type: FloorType,
    model_matrix: math.Matrix,
    boundaries: collision.Rectangle,
    tint: util.Color,

    /// Values used to generate this floor.
    side_a_start: math.FlatVector,
    side_a_end: math.FlatVector,
    side_b_length: math.Fix32,

    /// Side a and b can be chosen arbitrarily, but must be adjacent.
    fn create(
        object_id: u64,
        floor_type: FloorType,
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
        side_b_length: math.Fix32,
    ) Floor {
        const offset_a = side_a_end.subtract(side_a_start);
        const side_a_length = offset_a.length();
        const rotation = offset_a.computeRotationToOtherVector(.{ .x = fp(0), .z = fp(1) });
        const offset_b = offset_a.rotateRightBy90Degrees().negate().normalize().scale(side_b_length);
        const center = side_a_start.add(offset_a.scale(fp(0.5))).add(offset_b.scale(fp(0.5)));
        return Floor{
            .object_id = object_id,
            .floor_type = floor_type,
            .model_matrix = math.Matrix.identity
                .rotate(math.Vector3dF32.x_axis, std.math.degreesToRadians(-90))
                .scale(.{
                .x = side_b_length.convertTo(f32),
                .y = 1,
                .z = side_a_length.convertTo(f32),
            })
                .rotate(math.Vector3dF32.y_axis, rotation.neg().convertTo(f32))
                .translate(center.toVector3d().toVector3dF32()),
            .boundaries = collision.Rectangle.create(side_a_start, side_a_end, side_b_length),
            .tint = getDefaultTint(floor_type),
            .side_a_start = side_a_start,
            .side_a_end = side_a_end,
            .side_b_length = side_b_length,
        };
    }

    fn getTextureScale(self: Floor) math.Fix32 {
        return switch (self.floor_type) {
            else => fp(5),
            .grass => fp(2),
            .water => fp(3),
        };
    }

    fn getDefaultTint(floor_type: FloorType) util.Color {
        return switch (floor_type) {
            else => util.Color.white,
        };
    }

    fn getTextureLayerId(self: Floor) textures.TileableArrayTexture.LayerId {
        return switch (self.floor_type) {
            .grass => .grass,
            .stone => .stone_floor,
            .water => .water_frame_0, // Animation offsets are applied by the renderer.
        };
    }

    fn isAffectedByAnimationCycle(self: Floor) bool {
        return self.floor_type == .water;
    }
};

const Wall = struct {
    object_id: u64,
    wall_type: WallType,
    model_matrix: math.Matrix,
    boundaries: collision.Rectangle,
    tint: util.Color,

    grid_handles: struct {
        all: ?*SpatialGrid.ObjectHandle,
        solid: ?*SpatialGrid.ObjectHandle,
    },

    /// Values used to generate this wall.
    start_position: math.FlatVector,
    end_position: math.FlatVector,

    fn create(
        object_id: u64,
        wall_type: WallType,
        start_position: math.FlatVector,
        end_position: math.FlatVector,
    ) Wall {
        const wall_type_properties = getWallTypeProperties(start_position, end_position, wall_type);
        const offset = wall_type_properties.corrected_end_position.subtract(
            wall_type_properties.corrected_start_position,
        );
        const length = offset.length().convertTo(math.Fix32);
        const x_axis = math.FlatVector{ .x = fp(1), .z = fp(0) };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);
        const height = wall_type_properties.height;
        const thickness = wall_type_properties.thickness;

        // Fences are flat, thickness is only for collision.
        const render_thickness = if (isFence(wall_type)) fp(0) else thickness;

        const side_a_up_offset = math.FlatVector.normalize(.{ .x = offset.z, .z = offset.x.neg() })
            .scale(thickness.div(fp(2)));
        const center = wall_type_properties.corrected_start_position.add(offset.scale(fp(0.5)));
        return Wall{
            .object_id = object_id,
            .model_matrix = math.Matrix.identity
                .scale(.{
                .x = length.convertTo(f32),
                .y = height.convertTo(f32),
                .z = render_thickness.convertTo(f32),
            })
                .rotate(math.Vector3d.y_axis.toVector3dF32(), rotation_angle.convertTo(f32))
                .translate(center.toVector3d().add(math.Vector3d.y_axis.scale(height.div(fp(2))))
                .toVector3dF32()),
            .tint = Wall.getDefaultTint(wall_type),
            .boundaries = collision.Rectangle.create(
                wall_type_properties.corrected_start_position.add(side_a_up_offset),
                wall_type_properties.corrected_start_position.subtract(side_a_up_offset),
                length,
            ),
            .wall_type = wall_type,
            .grid_handles = .{ .all = null, .solid = null },
            .start_position = start_position,
            .end_position = end_position,
        };
    }

    fn collidesWithRay(
        wall_type: WallType,
        boundaries: collision.Rectangle,
        ray: collision.Ray3d,
    ) ?collision.Ray3d.ImpactPoint {
        const bottom_corners_2d = boundaries.getCornersInGameCoordinates();
        const bottom_corners = [_]math.Vector3d{
            bottom_corners_2d[0].toVector3d(),
            bottom_corners_2d[1].toVector3d(),
            bottom_corners_2d[2].toVector3d(),
            bottom_corners_2d[3].toVector3d(),
        };
        const vertical_offset = math.Vector3d.y_axis.scale(getWallTypeHeight(wall_type));
        var closest_impact_point: ?collision.Ray3d.ImpactPoint = null;

        var side: usize = 0;
        while (side < 4) : (side += 1) {
            const side_bottom_corners = .{ bottom_corners[side], bottom_corners[(side + 1) % 4] };
            const quad = .{
                side_bottom_corners[0],
                side_bottom_corners[1],
                side_bottom_corners[1].add(vertical_offset),
                side_bottom_corners[0].add(vertical_offset),
            };
            updateClosestImpactPoint(ray, quad, &closest_impact_point);
        }
        const top_side_of_wall = .{
            bottom_corners[0].add(vertical_offset),
            bottom_corners[1].add(vertical_offset),
            bottom_corners[2].add(vertical_offset),
            bottom_corners[3].add(vertical_offset),
        };
        updateClosestImpactPoint(ray, top_side_of_wall, &closest_impact_point);

        return closest_impact_point;
    }

    fn updateClosestImpactPoint(
        ray: collision.Ray3d,
        quad: [4]math.Vector3d,
        closest_impact_point: *?collision.Ray3d.ImpactPoint,
    ) void {
        const current_impact_point = ray.collidesWithQuad(quad) orelse return;
        if (closest_impact_point.*) |previous_impact_point| {
            if (current_impact_point.distance_from_start_position.lt(
                previous_impact_point.distance_from_start_position,
            )) {
                closest_impact_point.* = current_impact_point;
            }
        } else {
            closest_impact_point.* = current_impact_point;
        }
    }

    const WallTypeProperties = struct {
        corrected_start_position: math.FlatVector,
        corrected_end_position: math.FlatVector,
        height: math.Fix32,
        thickness: math.Fix32,
        texture_scale: math.Fix32,
    };

    fn getWallTypeProperties(
        start_position: math.FlatVector,
        end_position: math.FlatVector,
        wall_type: WallType,
    ) WallTypeProperties {
        const fence_thickness = fp(0.25); // Only needed for collision boundaries, fences are flat.
        var properties = WallTypeProperties{
            .corrected_start_position = start_position,
            .corrected_end_position = end_position,
            .height = getWallTypeHeight(wall_type),
            .thickness = fence_thickness,
            .texture_scale = fp(1),
        };
        switch (wall_type) {
            .small_wall => {
                properties.texture_scale = fp(5);
            },
            .medium_wall => {
                properties.thickness = fp(1);
                properties.texture_scale = fp(5);
            },
            .castle_wall => {
                properties.thickness = fp(2);
                properties.texture_scale = fp(7.5);
            },
            .castle_tower => {
                // Towers are centered around their start position.
                const half_side_length = fp(3);
                const rescaled_offset =
                    end_position.subtract(start_position).normalize().scale(half_side_length);
                properties.corrected_start_position = start_position.subtract(rescaled_offset);
                properties.corrected_end_position = start_position.add(rescaled_offset);
                properties.thickness = half_side_length.mul(fp(2));
                properties.texture_scale = fp(9);
            },
            .metal_fence => {
                properties.texture_scale = fp(3.5);
            },
            .short_metal_fence => {
                properties.texture_scale = fp(1.5);
            },
            .tall_hedge => {
                properties.thickness = fp(3);
                properties.texture_scale = fp(3.5);
            },
            .giga_wall => {
                properties.thickness = fp(6);
                properties.texture_scale = fp(16);
            },
        }
        return properties;
    }

    fn getWallTypeHeight(wall_type: WallType) math.Fix32 {
        return switch (wall_type) {
            .small_wall => fp(5),
            .medium_wall => fp(10),
            .castle_wall => fp(15),
            .castle_tower => fp(18),
            .metal_fence => fp(3.5),
            .short_metal_fence => fp(1),
            .tall_hedge => fp(8),
            .giga_wall => fp(1000),
        };
    }

    fn isFence(wall_type: WallType) bool {
        return switch (wall_type) {
            else => false,
            .metal_fence, .short_metal_fence => true,
        };
    }

    fn getDefaultTint(wall_type: WallType) util.Color {
        return switch (wall_type) {
            .castle_tower => util.Color.fromRgb8(248, 248, 248),
            .giga_wall => util.Color.fromRgb8(170, 170, 170),
            else => util.Color.white,
        };
    }

    fn getTextureLayerId(self: Wall) textures.TileableArrayTexture.LayerId {
        return switch (self.wall_type) {
            .metal_fence, .short_metal_fence => .metal_fence,
            .tall_hedge => .hedge,
            else => .wall,
        };
    }

    fn getWallData(self: Wall) rendering.WallRenderer.WallData {
        const wall_properties =
            Wall.getWallTypeProperties(self.start_position, self.end_position, self.wall_type);
        const length = wall_properties.corrected_end_position
            .subtract(wall_properties.corrected_start_position).length().convertTo(f32);
        const texture_scale = wall_properties.texture_scale.convertTo(f32);
        return .{
            .properties = makeRenderingAttributes(
                self.model_matrix,
                self.getTextureLayerId(),
                self.tint,
            ),
            .texture_repeat_dimensions = .{
                .x = length / texture_scale,
                .y = wall_properties.height.convertTo(f32) / texture_scale,
                .z = wall_properties.thickness.convertTo(f32) / texture_scale,
            },
        };
    }
};

const BillboardObject = struct {
    object_id: u64,
    object_type: BillboardObjectType,
    boundaries: collision.Circle,
    sprite_data: rendering.SpriteData,

    fn create(
        object_id: u64,
        object_type: BillboardObjectType,
        position: math.FlatVector,
        spritesheet: textures.SpriteSheetTexture,
    ) BillboardObject {
        const width = fp(switch (object_type) {
            else => 1,
        });
        const sprite_id: textures.SpriteSheetTexture.SpriteId = switch (object_type) {
            .small_bush => .small_bush,
        };
        const source = spritesheet.getSpriteTexcoords(sprite_id);
        const boundaries = .{
            .position = position,
            .radius = width.div(fp(2)),
        };
        const half_height =
            boundaries.radius.convertTo(f32) * spritesheet.getSpriteAspectRatio(sprite_id);
        const tint = getDefaultTint(object_type);
        return .{
            .object_id = object_id,
            .object_type = object_type,
            .boundaries = boundaries,
            .sprite_data = .{
                .position = .{
                    .x = boundaries.position.x.convertTo(f32),
                    .y = half_height,
                    .z = boundaries.position.z.convertTo(f32),
                },
                .size = .{
                    .w = boundaries.radius.convertTo(f32) * 2,
                    .h = half_height * 2,
                },
                .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
                .tint = .{ .r = tint.r, .g = tint.g, .b = tint.b },
            },
        };
    }

    fn getTint(self: BillboardObject) util.Color {
        return .{
            .r = self.sprite_data.tint.r,
            .g = self.sprite_data.tint.g,
            .b = self.sprite_data.tint.b,
        };
    }

    fn setTint(self: *BillboardObject, tint: util.Color) void {
        self.sprite_data.tint.r = tint.r;
        self.sprite_data.tint.g = tint.g;
        self.sprite_data.tint.b = tint.b;
    }

    fn cast3DRay(self: BillboardObject, ray: collision.Ray3d) ?collision.Ray3d.ImpactPoint {
        const offset_to_top = math.Vector3d.y_axis.scale(self.boundaries.radius.mul(fp(2)));
        const offset_to_right = ray.direction.toFlatVector().normalize().rotateRightBy90Degrees()
            .scale(self.boundaries.radius).toVector3d();
        return ray.collidesWithQuad(.{
            self.boundaries.position.toVector3d().subtract(offset_to_right),
            self.boundaries.position.toVector3d().add(offset_to_right),
            self.boundaries.position.toVector3d().add(offset_to_right).add(offset_to_top),
            self.boundaries.position.toVector3d().subtract(offset_to_right).add(offset_to_top),
        });
    }

    fn getDefaultTint(object_type: BillboardObjectType) util.Color {
        return switch (object_type) {
            else => util.Color.white,
        };
    }
};

fn makeRenderingAttributes(
    model_matrix: math.Matrix,
    layer_id: textures.TileableArrayTexture.LayerId,
    tint: util.Color,
) rendering.MapGeometryAttributes {
    return .{
        .model_matrix = model_matrix.toFloatArray(),
        .texture_layer_id = @as(f32, @floatFromInt(@intFromEnum(layer_id))),
        .tint = .{ .r = tint.r, .g = tint.g, .b = tint.b },
    };
}

/// Used to prevent reuploading the same unchanged data to the GPU multiple times.
const RenderDataUploadInfo = struct {
    has_been_synchronized: bool,
    geometry_object_id: u64,
    geometry_change_counter: u64,

    fn create() RenderDataUploadInfo {
        return .{
            .has_been_synchronized = false,
            .geometry_object_id = 0,
            .geometry_change_counter = 0,
        };
    }

    /// Returns false if this object is already up to date.
    fn syncIfNeeded(self: *RenderDataUploadInfo, newer_state: RenderDataUploadInfo) bool {
        if (self.has_been_synchronized and
            self.geometry_object_id == newer_state.geometry_object_id and
            self.geometry_change_counter == newer_state.geometry_change_counter)
        {
            return false;
        }
        self.* = newer_state;
        return true;
    }

    /// Returns false if this object is already up to date.
    fn syncIfNeededWithGeometry(self: *RenderDataUploadInfo, geometry: Geometry) bool {
        if (self.has_been_synchronized and
            self.geometry_object_id == geometry.id and
            self.geometry_change_counter == geometry.change_counter)
        {
            return false;
        }
        self.* = .{
            .has_been_synchronized = true,
            .geometry_object_id = geometry.id,
            .geometry_change_counter = geometry.change_counter,
        };
        return true;
    }
};

/// Bitset containing all walkable and non-walkable tiles in the map.
const ObstacleGrid = struct {
    grid: []TileType,
    map_boundaries: collision.AxisAlignedBoundingBox,
    map_cell_count_horizontal: usize,

    fn create() ObstacleGrid {
        return .{
            .grid = &.{},
            .map_boundaries = .{ .min = math.FlatVector.zero, .max = math.FlatVector.zero },
            .map_cell_count_horizontal = 1,
        };
    }

    fn destroy(self: *ObstacleGrid, allocator: std.mem.Allocator) void {
        allocator.free(self.grid);
    }

    fn recompute(self: *ObstacleGrid, geometry: Geometry) !void {
        if (geometry.walls.solid.items.len == 0 and
            geometry.walls.translucent.items.len == 0)
        {
            self.* = .{
                .grid = self.grid,
                .map_boundaries = .{ .min = math.FlatVector.zero, .max = math.FlatVector.zero },
                .map_cell_count_horizontal = 1,
            };
            return;
        }

        // Don't assume the map covers (0, 0).
        const any_wall = geometry.walls.solid.getLastOrNull() orelse
            geometry.walls.translucent.getLast();
        const any_point = any_wall.boundaries.getCornersInGameCoordinates()[0];

        var map_boundaries = collision.AxisAlignedBoundingBox{ .min = any_point, .max = any_point };
        for (geometry.walls.solid.items) |wall| {
            updateBoundaries(&map_boundaries, wall);
        }
        for (geometry.walls.translucent.items) |wall| {
            updateBoundaries(&map_boundaries, wall);
        }

        const cell_size = fp(obstacle_grid_cell_size);
        const padding_for_storing_extra_neighbors = .{ .x = cell_size, .z = cell_size };
        map_boundaries.min = map_boundaries.min.subtract(padding_for_storing_extra_neighbors);
        map_boundaries.max = map_boundaries.max.add(padding_for_storing_extra_neighbors);

        const map_dimensions = .{
            .w = map_boundaries.max.x.sub(map_boundaries.min.x).convertTo(f32),
            .h = map_boundaries.max.z.sub(map_boundaries.min.z).convertTo(f32),
        };
        const map_cell_count = .{
            .w = @as(usize, @intFromFloat(map_dimensions.w / cell_size.convertTo(f32))) + 1,
            .h = @as(usize, @intFromFloat(map_dimensions.h / cell_size.convertTo(f32))) + 1,
        };
        const total_cell_count = map_cell_count.w * map_cell_count.h;
        self.* = .{
            .grid = if (total_cell_count <= self.grid.len)
                self.grid
            else
                try geometry.allocator.realloc(self.grid, total_cell_count),
            .map_boundaries = map_boundaries,
            .map_cell_count_horizontal = map_cell_count.w,
        };
        @memset(self.grid, .none);

        for (geometry.walls.solid.items) |wall| {
            self.insert(wall);
        }
        for (geometry.walls.translucent.items) |wall| {
            self.insert(wall);
        }
    }

    fn getObstacleTile(self: ObstacleGrid, position: math.FlatVector) TileType {
        if (!self.map_boundaries.collidesWithPoint(position)) {
            return .none;
        }
        const index = self.getIndex(
            CellIndex.fromPosition(position.subtract(self.map_boundaries.min).toFlatVectorF32()),
        );
        return self.grid[index];
    }

    fn insert(self: *ObstacleGrid, wall: Wall) void {
        var corners = wall.boundaries.getCornersInGameCoordinates();
        for (&corners) |*corner| {
            // Make game coordinates positive, starting at (0, 0).
            corner.* = corner.subtract(self.map_boundaries.min);
        }
        const tile_type: TileType =
            if (Wall.isFence(wall.wall_type)) .obstacle_tranclucent else .obstacle_solid;
        self.insertLine(tile_type, corners[0], corners[1]);
        self.insertLine(tile_type, corners[1], corners[2]);
        self.insertLine(tile_type, corners[2], corners[3]);
        self.insertLine(tile_type, corners[3], corners[0]);
    }

    fn insertLine(
        self: *ObstacleGrid,
        tile_type: TileType,
        start: math.FlatVector,
        end: math.FlatVector,
    ) void {
        var iterator = cell_line_iterator(CellIndex, start.toFlatVectorF32(), end.toFlatVectorF32());
        while (iterator.next()) |cell_index| {
            const index = self.getIndex(cell_index);
            if (self.grid[index] != .obstacle_solid) {
                self.grid[index] = tile_type;
            }
            self.markNeighborOfObstacle(cell_index.x - 1, cell_index.z);
            self.markNeighborOfObstacle(cell_index.x + 1, cell_index.z);
            self.markNeighborOfObstacle(cell_index.x - 1, cell_index.z - 1);
            self.markNeighborOfObstacle(cell_index.x, cell_index.z - 1);
            self.markNeighborOfObstacle(cell_index.x + 1, cell_index.z - 1);
            self.markNeighborOfObstacle(cell_index.x - 1, cell_index.z + 1);
            self.markNeighborOfObstacle(cell_index.x, cell_index.z + 1);
            self.markNeighborOfObstacle(cell_index.x + 1, cell_index.z + 1);
        }
    }

    fn getIndex(self: ObstacleGrid, cell_index: CellIndex) usize {
        return @as(usize, @intCast(cell_index.z)) * self.map_cell_count_horizontal +
            @as(usize, @intCast(cell_index.x));
    }

    /// Drop-in replacement for `spatial_partitioning.CellIndex` using larger integers.
    const CellIndex = struct {
        x: isize,
        z: isize,
        pub const side_length = obstacle_grid_cell_size;

        pub fn fromPosition(position: math.FlatVectorF32) CellIndex {
            return .{
                .x = @intFromFloat(position.x / @as(f32, @floatFromInt(side_length))),
                .z = @intFromFloat(position.z / @as(f32, @floatFromInt(side_length))),
            };
        }
    };

    fn markNeighborOfObstacle(self: *ObstacleGrid, x: isize, z: isize) void {
        const index = self.getIndex(.{ .x = x, .z = z });
        self.grid[index] = switch (self.grid[index]) {
            .none => .neighbor_of_obstacle,
            .neighbor_of_obstacle, .obstacle_tranclucent, .obstacle_solid => |current| current,
        };
    }

    fn updateBoundaries(boundaries: *collision.AxisAlignedBoundingBox, wall: Wall) void {
        for (wall.boundaries.getCornersInGameCoordinates()) |corner| {
            boundaries.min.x = boundaries.min.x.min(corner.x);
            boundaries.min.z = boundaries.min.z.min(corner.z);
            boundaries.max.x = boundaries.max.x.max(corner.x);
            boundaries.max.z = boundaries.max.z.max(corner.z);
        }
    }
};
