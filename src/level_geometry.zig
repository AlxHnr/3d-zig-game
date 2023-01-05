const animation = @import("animation.zig");
const collision = @import("collision.zig");
const FlatVector = @import("flat_vector.zig").FlatVector;
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const textures = @import("textures.zig");
const glad = @cImport(@cInclude("external/glad.h"));
const Error = @import("error.zig").Error;
const rendering = @import("rendering.zig");
const meshes = @import("meshes.zig");

pub const LevelGeometry = struct {
    /// Gives every object owned by this struct a unique id.
    object_id_counter: u64,

    /// Contains all textures needed to render the environment.
    array_texture_id: c_uint,

    walls: std.ArrayList(Wall),
    wall_renderer: rendering.WallRenderer,
    walls_have_changed: bool,

    /// Floors in this array will be rendered last to first without overpainting one another. This
    /// leads to the last floor in the array being shown above all others.
    floors: std.ArrayList(Floor),
    floor_animation_state: animation.FourStepCycle,
    floor_renderer: rendering.FloorRenderer,
    floors_have_changed: bool,

    billboard_objects: std.ArrayList(BillboardObject),

    /// Stores the given allocator internally for its entire lifetime.
    pub fn create(allocator: std.mem.Allocator) !LevelGeometry {
        const array_texture_id = try textures.loadTextureArray();
        errdefer glad.glDeleteTextures(1, &array_texture_id);
        var wall_renderer = try rendering.WallRenderer.create();
        errdefer wall_renderer.destroy();
        var floor_renderer = try rendering.FloorRenderer.create();
        errdefer floor_renderer.destroy();

        return LevelGeometry{
            .object_id_counter = 0,
            .array_texture_id = array_texture_id,
            .walls = std.ArrayList(Wall).init(allocator),
            .wall_renderer = wall_renderer,
            .walls_have_changed = false,
            .floors = std.ArrayList(Floor).init(allocator),
            .floor_animation_state = animation.FourStepCycle.create(),
            .floor_renderer = floor_renderer,
            .floors_have_changed = false,
            .billboard_objects = std.ArrayList(BillboardObject).init(allocator),
        };
    }

    pub fn destroy(self: *LevelGeometry) void {
        self.billboard_objects.deinit();

        self.floor_renderer.destroy();
        self.floors.deinit();

        self.wall_renderer.destroy();
        self.walls.deinit();
        glad.glDeleteTextures(1, &self.array_texture_id);
    }

    /// Stores the given allocator internally for its entire lifetime.
    pub fn createFromJson(allocator: std.mem.Allocator, json: []const u8) !LevelGeometry {
        var geometry = try create(allocator);
        errdefer geometry.destroy();

        const options = .{ .allocator = allocator };
        const tree = try std.json
            .parse(Json.SerializableData, &std.json.TokenStream.init(json), options);
        defer std.json.parseFree(Json.SerializableData, tree, options);

        for (tree.walls) |wall| {
            const wall_type = std.meta.stringToEnum(WallType, wall.wall_type) orelse {
                return Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addWall(wall.start_position, wall.end_position, wall_type);
        }
        for (tree.floors) |floor| {
            const floor_type = std.meta.stringToEnum(FloorType, floor.floor_type) orelse {
                return Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addFloor(
                floor.side_a_start,
                floor.side_a_end,
                floor.side_b_length,
                floor_type,
            );
        }
        for (tree.billboard_objects) |billboard| {
            const object_type = std.meta.stringToEnum(BillboardObjectType, billboard.object_type) orelse {
                return Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addBillboardObject(object_type, billboard.position);
        }

        return geometry;
    }

    pub fn prepareRender(self: *LevelGeometry, allocator: std.mem.Allocator) !void {
        if (self.walls_have_changed) {
            try self.uploadWallsToRenderer(allocator);
            self.walls_have_changed = false;
        }
        if (self.floors_have_changed) {
            try self.uploadFloorsToRenderer(allocator);
            self.floors_have_changed = false;
        }
    }

    pub fn render(
        self: LevelGeometry,
        camera: rl.Camera,
        shader: rl.Shader,
        texture_collection: textures.Collection,
    ) void {
        const vp_matrix = rm.MatrixToFloatV(util.getCurrentRaylibVpMatrix()).v;
        self.wall_renderer.render(vp_matrix, self.array_texture_id);

        // Prevent floors from overpainting each other.
        glad.glStencilFunc(glad.GL_NOTEQUAL, 1, 0xff);
        self.floor_renderer.render(vp_matrix, self.array_texture_id, self.floor_animation_state);
        glad.glStencilFunc(glad.GL_ALWAYS, 1, 0xff);

        rl.BeginShaderMode(shader);
        for (self.billboard_objects.items) |billboard| {
            rl.DrawBillboard(
                camera,
                billboard.getTexture(texture_collection),
                rl.Vector3{
                    .x = billboard.boundaries.position.x,
                    .y = billboard.boundaries.radius,
                    .z = billboard.boundaries.position.z,
                },
                billboard.boundaries.radius * 2,
                billboard.tint,
            );
        }
        rl.EndShaderMode();
    }

    pub fn processElapsedTick(self: *LevelGeometry) void {
        self.floor_animation_state.processStep(0.02);
    }

    pub fn toJson(self: LevelGeometry, allocator: std.mem.Allocator, outstream: anytype) !void {
        var walls = try allocator.alloc(Json.Wall, self.walls.items.len);
        defer allocator.free(walls);
        for (self.walls.items) |wall, index| {
            walls[index] = .{
                .wall_type = @tagName(wall.wall_type),
                .start_position = wall.start_position,
                .end_position = wall.end_position,
            };
        }

        var floors = try allocator.alloc(Json.Floor, self.floors.items.len);
        defer allocator.free(floors);
        for (self.floors.items) |floor, index| {
            floors[index] = .{
                .floor_type = @tagName(floor.floor_type),
                .side_a_start = floor.side_a_start,
                .side_a_end = floor.side_a_end,
                .side_b_length = floor.side_b_length,
            };
        }

        var billboards = try allocator.alloc(Json.BillboardObject, self.billboard_objects.items.len);
        defer allocator.free(billboards);
        for (self.billboard_objects.items) |billboard, index| {
            billboards[index] = .{
                .object_type = @tagName(billboard.object_type),
                .position = billboard.boundaries.position,
            };
        }

        const data = Json.SerializableData{
            .walls = walls,
            .floors = floors,
            .billboard_objects = billboards,
        };
        try std.json.stringify(data, .{ .whitespace = .{ .indent = .{ .Space = 2 } } }, outstream);
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
        self: *LevelGeometry,
        start_position: FlatVector,
        end_position: FlatVector,
        wall_type: WallType,
    ) !u64 {
        const wall = try self.walls.addOne();
        wall.* = Wall.create(
            self.object_id_counter,
            wall_type,
            start_position,
            end_position,
        );
        self.object_id_counter = self.object_id_counter + 1;
        self.walls_have_changed = true;
        return wall.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn updateWall(
        self: *LevelGeometry,
        object_id: u64,
        start_position: FlatVector,
        end_position: FlatVector,
    ) void {
        if (self.findWall(object_id)) |wall| {
            const tint = wall.tint;
            const wall_type = wall.wall_type;
            wall.* = Wall.create(
                object_id,
                wall_type,
                start_position,
                end_position,
            );
            wall.tint = tint;
            self.walls_have_changed = true;
        }
    }

    pub const FloorType = enum {
        grass,
        stone,
        water,
    };

    /// Side a and b can be chosen arbitrarily, but must be adjacent. Returns the object id of the
    /// created floor on success.
    pub fn addFloor(
        self: *LevelGeometry,
        side_a_start: FlatVector,
        side_a_end: FlatVector,
        side_b_length: f32,
        floor_type: FloorType,
    ) !u64 {
        const floor = try self.floors.addOne();
        floor.* = Floor.create(
            self.object_id_counter,
            floor_type,
            side_a_start,
            side_a_end,
            side_b_length,
        );
        self.object_id_counter = self.object_id_counter + 1;
        self.floors_have_changed = true;
        return floor.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn updateFloor(
        self: *LevelGeometry,
        object_id: u64,
        side_a_start: FlatVector,
        side_a_end: FlatVector,
        side_b_length: f32,
    ) void {
        if (self.findFloor(object_id)) |floor| {
            const tint = floor.tint;
            const floor_type = floor.floor_type;
            floor.* = Floor.create(
                object_id,
                floor_type,
                side_a_start,
                side_a_end,
                side_b_length,
            );
            floor.tint = tint;
            self.floors_have_changed = true;
        }
    }

    pub const BillboardObjectType = enum {
        small_bush,
    };

    /// Returns the object id of the created billboard object on success.
    pub fn addBillboardObject(
        self: *LevelGeometry,
        object_type: BillboardObjectType,
        position: FlatVector,
    ) !u64 {
        const billboard = try self.billboard_objects.addOne();
        billboard.* = BillboardObject.create(self.object_id_counter, object_type, position);
        self.object_id_counter = self.object_id_counter + 1;
        return billboard.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn removeObject(self: *LevelGeometry, object_id: u64) void {
        for (self.walls.items) |*wall, index| {
            if (wall.object_id == object_id) {
                _ = self.walls.orderedRemove(index);
                self.walls_have_changed = true;
                return;
            }
        }
        for (self.floors.items) |*floor, index| {
            if (floor.object_id == object_id) {
                _ = self.floors.orderedRemove(index);
                self.floors_have_changed = true;
                return;
            }
        }
        for (self.billboard_objects.items) |billboard, index| {
            if (billboard.object_id == object_id) {
                _ = self.billboard_objects.orderedRemove(index);
                return;
            }
        }
    }

    pub fn tintObject(self: *LevelGeometry, object_id: u64, tint: rl.Color) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = tint;
            self.walls_have_changed = true;
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = tint;
            self.floors_have_changed = true;
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = tint;
        }
    }

    pub fn untintObject(self: *LevelGeometry, object_id: u64) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = Wall.getDefaultTint(wall.wall_type);
            self.walls_have_changed = true;
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = Floor.getDefaultTint(floor.floor_type);
            self.floors_have_changed = true;
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = BillboardObject.getDefaultTint(billboard.object_type);
        }
    }

    /// If the given ray hits the ground within a not too large distance, return the position on the
    /// ground.
    pub fn cast3DRayToGround(_: LevelGeometry, ray: rl.Ray) ?FlatVector {
        if (std.math.signbit(ray.position.y) == std.math.signbit(ray.direction.y)) {
            return null;
        }
        if (std.math.fabs(ray.direction.y) < util.Constants.epsilon) {
            return null;
        }
        const offset_from_start = FlatVector{
            .x = -ray.position.y / (ray.direction.y / ray.direction.x),
            .z = -ray.position.y / (ray.direction.y / ray.direction.z),
        };
        if (offset_from_start.length() > 500) {
            return null;
        }
        return FlatVector.fromVector3(ray.position).add(offset_from_start);
    }

    pub const RayCollision = struct {
        object_id: u64,
        distance: f32,
    };

    /// Find the id of the closest wall hit by the given ray, if available.
    pub fn cast3DRayToWalls(self: LevelGeometry, ray: rl.Ray, ignore_fences: bool) ?RayCollision {
        var mesh = std.mem.zeroes(rl.Mesh);
        var vertices = meshes.BottomlessCube.vertices; // Copy needed for Mesh.vertices.
        mesh.vertices = vertices[0..];
        mesh.triangleCount = meshes.BottomlessCube.vertices.len / 9;

        var result: ?RayCollision = null;
        for (self.walls.items) |wall| {
            if (ignore_fences and Wall.isFence(wall.wall_type)) {
                continue;
            }
            const hit = rl.GetRayCollisionMesh(ray, mesh, wall.model_matrix);
            result = getCloserRayHit(hit, wall.object_id, result);
        }
        return result;
    }

    /// Find the id of the closest object hit by the given ray, if available.
    pub fn cast3DRayToObjects(self: LevelGeometry, ray: rl.Ray) ?RayCollision {
        var result = self.cast3DRayToWalls(ray, false);
        for (self.billboard_objects.items) |billboard| {
            const hit = billboard.cast3DRay(ray);
            result = getCloserRayHit(hit, billboard.object_id, result);
        }

        // Walls and billboards are covering floors and are prioritized.
        if (result != null) {
            return result;
        }

        if (self.cast3DRayToGround(ray)) |position_on_ground| {
            for (self.floors.items) |_, index| {
                // The last floor in this array is always drawn at the top.
                const floor = self.floors.items[self.floors.items.len - index - 1];
                if (floor.boundaries.collidesWithPoint(position_on_ground)) {
                    return RayCollision{
                        .object_id = floor.object_id,
                        .distance = rm.Vector3Length(rm.Vector3Subtract(
                            ray.position,
                            position_on_ground.toVector3(),
                        )),
                    };
                }
            }
        }
        return null;
    }

    /// If a collision occurs, return a displacement vector for moving the given circle out of the
    /// level geometry. The returned displacement vector must be added to the given circles position
    /// to resolve the collision.
    pub fn collidesWithCircle(self: LevelGeometry, circle: collision.Circle) ?FlatVector {
        var found_collision = false;
        var displaced_circle = circle;

        // Move displaced_circle out of all walls.
        for (self.walls.items) |wall| {
            updateDisplacedCircle(wall, &displaced_circle, &found_collision);
        }

        return if (found_collision)
            displaced_circle.position.subtract(circle.position)
        else
            null;
    }

    /// Check if the given line (game-world coordinates) collides with the level geometry.
    pub fn collidesWithLine(self: LevelGeometry, line_start: FlatVector, line_end: FlatVector) bool {
        for (self.walls.items) |wall| {
            if (wall.boundaries.collidesWithLine(line_start, line_end)) {
                return true;
            }
        }
        return false;
    }

    fn findWall(self: *LevelGeometry, object_id: u64) ?*Wall {
        for (self.walls.items) |*wall| {
            if (wall.object_id == object_id) {
                return wall;
            }
        }
        return null;
    }

    fn findFloor(self: *LevelGeometry, object_id: u64) ?*Floor {
        for (self.floors.items) |*floor| {
            if (floor.object_id == object_id) {
                return floor;
            }
        }
        return null;
    }

    fn findBillboardObject(self: *LevelGeometry, object_id: u64) ?*BillboardObject {
        for (self.billboard_objects.items) |*billboard| {
            if (billboard.object_id == object_id) {
                return billboard;
            }
        }
        return null;
    }

    /// If the given wall collides with the circle, move the circle out of the wall and set
    /// found_collision to true. Without a collision this boolean will remain unchanged.
    fn updateDisplacedCircle(wall: Wall, circle: *collision.Circle, found_collision: *bool) void {
        if (circle.collidesWithRectangle(wall.boundaries)) |displacement_vector| {
            circle.position = circle.position.add(displacement_vector);
            found_collision.* = true;
        }
    }

    fn getCloserRayHit(
        hit: rl.RayCollision,
        object_id: u64,
        current_collision: ?RayCollision,
    ) ?RayCollision {
        const found_closer_object = if (!hit.hit)
            false
        else if (current_collision) |existing_result|
            hit.distance < existing_result.distance
        else
            true;
        if (found_closer_object) {
            return RayCollision{ .object_id = object_id, .distance = hit.distance };
        }
        return current_collision;
    }

    fn uploadWallsToRenderer(self: *LevelGeometry, allocator: std.mem.Allocator) !void {
        var data = try allocator.alloc(rendering.WallRenderer.WallData, self.walls.items.len);
        defer allocator.free(data);

        for (self.walls.items) |wall, index| {
            const wall_properties =
                Wall.getWallTypeProperties(wall.start_position, wall.end_position, wall.wall_type);
            const length = wall_properties.corrected_end_position
                .subtract(wall_properties.corrected_start_position).length();
            data[index] = .{
                .properties = makeRenderProperties(
                    wall.model_matrix,
                    wall.getTextureName(),
                    wall.tint,
                ),
                .texture_repeat_dimensions = .{
                    .x = length / wall_properties.texture_scale,
                    .y = wall_properties.height / wall_properties.texture_scale,
                    .z = wall_properties.thickness / wall_properties.texture_scale,
                },
            };
        }
        self.wall_renderer.uploadWalls(data);
    }

    fn uploadFloorsToRenderer(self: *LevelGeometry, allocator: std.mem.Allocator) !void {
        var data = try allocator.alloc(rendering.FloorRenderer.FloorData, self.floors.items.len);
        defer allocator.free(data);

        // Upload floors in reverse-order, so they won't be overpainted by floors below them.
        var index: usize = 0;
        while (index < self.floors.items.len) : (index += 1) {
            const floor = self.floors.items[self.floors.items.len - index - 1];
            const side_a_length = floor.side_a_end.subtract(floor.side_a_start).length();
            data[index] = .{
                .properties = makeRenderProperties(
                    floor.model_matrix,
                    floor.getTextureName(),
                    floor.tint,
                ),
                .affected_by_animation_cycle = if (floor.isAffectedByAnimationCycle()) 1 else 0,
                .texture_repeat_dimensions = .{
                    .x = floor.side_b_length / floor.getTextureScale(),
                    .y = side_a_length / floor.getTextureScale(),
                },
            };
        }
        self.floor_renderer.uploadFloors(data);
    }

    fn makeRenderProperties(
        model_matrix: rl.Matrix,
        texture_name: textures.Name,
        tint: rl.Color,
    ) rendering.LevelGeometryProperties {
        return .{
            .model_matrix = rm.MatrixToFloatV(model_matrix).v,
            .texture_layer_id = @intToFloat(f32, @enumToInt(texture_name)),
            .tint = .{
                .r = @intToFloat(f32, tint.r) / 255.0,
                .g = @intToFloat(f32, tint.g) / 255.0,
                .b = @intToFloat(f32, tint.b) / 255.0,
            },
        };
    }
};

const Floor = struct {
    object_id: u64,
    floor_type: LevelGeometry.FloorType,
    model_matrix: rl.Matrix,
    boundaries: collision.Rectangle,
    tint: rl.Color,

    /// Values used to generate this floor.
    side_a_start: FlatVector,
    side_a_end: FlatVector,
    side_b_length: f32,

    /// Side a and b can be chosen arbitrarily, but must be adjacent.
    fn create(
        object_id: u64,
        floor_type: LevelGeometry.FloorType,
        side_a_start: FlatVector,
        side_a_end: FlatVector,
        side_b_length: f32,
    ) Floor {
        const offset_a = side_a_end.subtract(side_a_start);
        const side_a_length = offset_a.length();
        const rotation = offset_a.computeRotationToOtherVector(.{ .x = 0, .z = 1 });
        const offset_b = offset_a.rotateRightBy90Degrees().negate().normalize().scale(side_b_length);
        const center = side_a_start.add(offset_a.scale(0.5)).add(offset_b.scale(0.5));
        return Floor{
            .object_id = object_id,
            .floor_type = floor_type,
            .model_matrix = rm.MatrixMultiply(
                rm.MatrixMultiply(rm.MatrixMultiply(
                    rm.MatrixRotateX(util.degreesToRadians(-90)),
                    rm.MatrixScale(side_b_length, 1, side_a_length),
                ), rm.MatrixRotateY(-rotation)),
                rm.MatrixTranslate(center.x, 0, center.z),
            ),
            .boundaries = collision.Rectangle.create(side_a_start, side_a_end, side_b_length),
            .tint = getDefaultTint(floor_type),
            .side_a_start = side_a_start,
            .side_a_end = side_a_end,
            .side_b_length = side_b_length,
        };
    }

    /// If the given ray hits this object, return the position on the floor.
    fn cast3DRay(self: Floor, ray: rl.Ray) ?FlatVector {
        if (self.cast3DRayToGround(ray)) |position| {
            return self.boundaries.collidesWithPoint(position);
        }
        return null;
    }

    fn getTextureScale(self: Floor) f32 {
        return switch (self.floor_type) {
            else => 5.0,
            .water => 3.0,
        };
    }

    fn getDefaultTint(floor_type: LevelGeometry.FloorType) rl.Color {
        return switch (floor_type) {
            else => rl.WHITE,
        };
    }

    fn getTextureName(self: Floor) textures.Name {
        return switch (self.floor_type) {
            .grass => .grass,
            .stone => .stone_floor,
            .water => textures.Name.water_frame_0, // Animation offsets are applied by the renderer.
        };
    }

    fn isAffectedByAnimationCycle(self: Floor) bool {
        return self.floor_type == .water;
    }
};

const Wall = struct {
    object_id: u64,
    wall_type: LevelGeometry.WallType,
    model_matrix: rl.Matrix,
    boundaries: collision.Rectangle,
    tint: rl.Color,

    /// Values used to generate this wall.
    start_position: FlatVector,
    end_position: FlatVector,

    fn create(
        object_id: u64,
        wall_type: LevelGeometry.WallType,
        start_position: FlatVector,
        end_position: FlatVector,
    ) Wall {
        const wall_type_properties = getWallTypeProperties(start_position, end_position, wall_type);
        const offset = wall_type_properties.corrected_end_position.subtract(
            wall_type_properties.corrected_start_position,
        );
        const length = offset.length();
        const x_axis = FlatVector{ .x = 1, .z = 0 };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);
        const height = wall_type_properties.height;
        const thickness = wall_type_properties.thickness;

        const scale_matrix = if (isFence(wall_type))
            rm.MatrixScale(length, height, 0) // Fences are flat, thickness is only for collision.
        else
            rm.MatrixScale(length, height, thickness);

        const side_a_up_offset =
            FlatVector.normalize(.{ .x = offset.z, .z = -offset.x }).scale(thickness / 2);
        const center = wall_type_properties.corrected_start_position.add(offset.scale(0.5));
        return Wall{
            .object_id = object_id,
            .model_matrix = rm.MatrixMultiply(
                rm.MatrixMultiply(scale_matrix, rm.MatrixRotateY(rotation_angle)),
                rm.MatrixTranslate(center.x, height / 2, center.z),
            ),
            .tint = Wall.getDefaultTint(wall_type),
            .boundaries = collision.Rectangle.create(
                wall_type_properties.corrected_start_position.add(side_a_up_offset),
                wall_type_properties.corrected_start_position.subtract(side_a_up_offset),
                length,
            ),
            .wall_type = wall_type,
            .start_position = start_position,
            .end_position = end_position,
        };
    }

    const WallTypeProperties = struct {
        corrected_start_position: FlatVector,
        corrected_end_position: FlatVector,
        height: f32,
        thickness: f32,
        texture_scale: f32,
    };

    fn getWallTypeProperties(
        start_position: FlatVector,
        end_position: FlatVector,
        wall_type: LevelGeometry.WallType,
    ) WallTypeProperties {
        const fence_thickness = 0.25; // Only needed for collision boundaries.
        return switch (wall_type) {
            else => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 10,
                    .thickness = 1,
                    .texture_scale = 5.0,
                };
            },
            .small_wall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 5,
                    .thickness = 0.25,
                    .texture_scale = 5.0,
                };
            },
            .castle_wall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 15,
                    .thickness = 2,
                    .texture_scale = 7.5,
                };
            },
            .castle_tower => {
                const half_side_length = 3;
                const rescaled_offset =
                    end_position.subtract(start_position).normalize().scale(half_side_length);
                return WallTypeProperties{
                    .corrected_start_position = start_position.subtract(rescaled_offset),
                    .corrected_end_position = start_position.add(rescaled_offset),
                    .height = 18,
                    .thickness = half_side_length * 2,
                    .texture_scale = 9,
                };
            },
            .metal_fence => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 3.5,
                    .thickness = fence_thickness,
                    .texture_scale = 3.5,
                };
            },
            .short_metal_fence => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 1,
                    .thickness = fence_thickness,
                    .texture_scale = 1.5,
                };
            },
            .tall_hedge => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 8,
                    .thickness = 3,
                    .texture_scale = 3.5,
                };
            },
            .giga_wall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 140,
                    .thickness = 6,
                    .texture_scale = 16.0,
                };
            },
        };
    }

    fn isFence(wall_type: LevelGeometry.WallType) bool {
        return switch (wall_type) {
            else => false,
            .metal_fence, .short_metal_fence => true,
        };
    }

    fn getDefaultTint(wall_type: LevelGeometry.WallType) rl.Color {
        return switch (wall_type) {
            .castle_tower => rl.Color{ .r = 248, .g = 248, .b = 248, .a = 255 },
            .giga_wall => rl.Color{ .r = 170, .g = 170, .b = 170, .a = 255 },
            else => rl.WHITE,
        };
    }

    fn getTextureName(self: Wall) textures.Name {
        return switch (self.wall_type) {
            .metal_fence, .short_metal_fence => .metal_fence,
            .tall_hedge => .hedge,
            else => .wall,
        };
    }
};

const BillboardObject = struct {
    object_id: u64,
    object_type: LevelGeometry.BillboardObjectType,
    boundaries: collision.Circle,
    tint: rl.Color,

    fn create(
        object_id: u64,
        object_type: LevelGeometry.BillboardObjectType,
        position: FlatVector,
    ) BillboardObject {
        return .{
            .object_id = object_id,
            .object_type = object_type,
            .boundaries = .{ .position = position, .radius = getDefaultSize(object_type) / 2 },
            .tint = getDefaultTint(object_type),
        };
    }

    fn cast3DRay(self: BillboardObject, ray: rl.Ray) rl.RayCollision {
        return rl.GetRayCollisionBox(ray, rl.BoundingBox{
            .min = .{
                .x = self.boundaries.position.x - self.boundaries.radius,
                .y = 0,
                .z = self.boundaries.position.z - self.boundaries.radius,
            },
            .max = .{
                .x = self.boundaries.position.x + self.boundaries.radius,
                .y = self.boundaries.radius * 2,
                .z = self.boundaries.position.z + self.boundaries.radius,
            },
        });
    }

    fn getDefaultTint(object_type: LevelGeometry.BillboardObjectType) rl.Color {
        return switch (object_type) {
            else => rl.WHITE,
        };
    }

    fn getDefaultSize(object_type: LevelGeometry.BillboardObjectType) f32 {
        return switch (object_type) {
            else => 1.0,
        };
    }

    fn getTexture(self: BillboardObject, texture_collection: textures.Collection) rl.Texture {
        return switch (self.object_type) {
            .small_bush => texture_collection.get(.small_bush),
        };
    }
};

const Json = struct {
    const SerializableData = struct {
        walls: []Json.Wall,
        floors: []Json.Floor,
        billboard_objects: []Json.BillboardObject,
    };

    const Wall = struct {
        wall_type: []const u8,
        start_position: FlatVector,
        end_position: FlatVector,
    };

    const Floor = struct {
        floor_type: []const u8,
        side_a_start: FlatVector,
        side_a_end: FlatVector,
        side_b_length: f32,
    };

    const BillboardObject = struct {
        object_type: []const u8,
        position: FlatVector,
    };
};
