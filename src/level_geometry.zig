const animation = @import("animation.zig");
const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const textures = @import("textures.zig");
const glad = @cImport(@cInclude("external/glad.h"));

pub const LevelGeometry = struct {
    object_id_counter: u64,

    walls: std.ArrayList(Wall),

    /// These vertices are needed for ray casting in edit mode.
    shared_wall_vertices: []f32,
    shared_fence_vertices: []f32,

    /// Floors are rendered in order, with the last floor at the top.
    floors: std.ArrayList(Floor),
    floor_animation_cycle: animation.FourStepCycle,

    billboard_objects: std.ArrayList(BillboardObject),

    /// Stores the given allocator internally for its entire lifetime.
    pub fn create(allocator: std.mem.Allocator) !LevelGeometry {
        const precomputed_wall_vertices = Wall.computeBottomlessCubeVertices();
        var shared_wall_vertices = try allocator.alloc(f32, precomputed_wall_vertices.len);
        errdefer allocator.free(shared_wall_vertices);
        std.mem.copy(f32, shared_wall_vertices, precomputed_wall_vertices[0..]);

        const precomputed_fence_vertices = Wall.computeDoubleSidedPlaneVertices();
        var shared_fence_vertices = try allocator.alloc(f32, precomputed_fence_vertices.len);
        std.mem.copy(f32, shared_fence_vertices, precomputed_fence_vertices[0..]);

        return LevelGeometry{
            .object_id_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .shared_wall_vertices = shared_wall_vertices,
            .shared_fence_vertices = shared_fence_vertices,
            .floors = std.ArrayList(Floor).init(allocator),
            .floor_animation_cycle = animation.FourStepCycle.create(),
            .billboard_objects = std.ArrayList(BillboardObject).init(allocator),
        };
    }

    /// Stores the given allocator internally for its entire lifetime.
    pub fn createFromJson(allocator: std.mem.Allocator, json: []const u8) !LevelGeometry {
        var geometry = try create(allocator);
        errdefer geometry.destroy(allocator);

        const options = .{ .allocator = allocator };
        const tree = try std.json
            .parse(Json.SerializableData, &std.json.TokenStream.init(json), options);
        defer std.json.parseFree(Json.SerializableData, tree, options);

        for (tree.walls) |wall| {
            const wall_type = std.meta.stringToEnum(WallType, wall.wall_type) orelse {
                return util.Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addWall(wall.start_position, wall.end_position, wall_type);
        }
        for (tree.floors) |floor| {
            const floor_type = std.meta.stringToEnum(FloorType, floor.floor_type) orelse {
                return util.Error.FailedToDeserializeLevelGeometry;
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
                return util.Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addBillboardObject(object_type, billboard.position);
        }

        return geometry;
    }

    pub fn destroy(self: *LevelGeometry, allocator: std.mem.Allocator) void {
        for (self.walls.items) |*wall| {
            wall.destroy();
        }
        self.walls.deinit();
        allocator.free(self.shared_wall_vertices);
        allocator.free(self.shared_fence_vertices);

        for (self.floors.items) |*floor| {
            floor.destroy();
        }
        self.floors.deinit();

        self.billboard_objects.deinit();
    }

    pub fn draw(
        self: LevelGeometry,
        camera: rl.Camera,
        shader: rl.Shader,
        texture_collection: textures.Collection,
    ) void {
        for (self.walls.items) |wall| {
            const texture = wall.getTexture(texture_collection);
            util.drawMesh(wall.mesh, wall.precomputed_matrix, texture, wall.tint, shader);
        }

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

        // Render last floor above all others.
        glad.glStencilFunc(glad.GL_NOTEQUAL, 1, 0xff);
        var counter: usize = 0;
        while (counter < self.floors.items.len) : (counter += 1) {
            const floor = self.floors.items[self.floors.items.len - counter - 1];
            const texture = floor.getTexture(self.floor_animation_cycle, texture_collection);
            util.drawMesh(floor.mesh, floor.precomputed_matrix, texture, floor.tint, shader);
        }
        glad.glStencilFunc(glad.GL_ALWAYS, 1, 0xff);
    }

    pub fn processElapsedTick(self: *LevelGeometry) void {
        self.floor_animation_cycle.processStep(0.02);
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
        start_position: util.FlatVector,
        end_position: util.FlatVector,
        wall_type: WallType,
    ) !u64 {
        const wall = try self.walls.addOne();
        wall.* = Wall.create(
            self.object_id_counter,
            start_position,
            end_position,
            wall_type,
            self.shared_wall_vertices,
            self.shared_fence_vertices,
        );
        self.object_id_counter = self.object_id_counter + 1;
        return wall.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn updateWall(
        self: *LevelGeometry,
        object_id: u64,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
    ) void {
        if (self.findWall(object_id)) |wall| {
            const tint = wall.tint;
            const wall_type = wall.wall_type;
            wall.destroy();
            wall.* = Wall.create(
                object_id,
                start_position,
                end_position,
                wall_type,
                self.shared_wall_vertices,
                self.shared_fence_vertices,
            );
            wall.tint = tint;
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
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
        floor_type: FloorType,
    ) !u64 {
        const floor = try self.floors.addOne();
        floor.* = Floor.create(
            self.object_id_counter,
            side_a_start,
            side_a_end,
            side_b_length,
            floor_type,
        );
        self.object_id_counter = self.object_id_counter + 1;
        return floor.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn updateFloor(
        self: *LevelGeometry,
        object_id: u64,
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
    ) void {
        if (self.findFloor(object_id)) |floor| {
            const tint = floor.tint;
            const floor_type = floor.floor_type;
            floor.* = Floor.create(
                object_id,
                side_a_start,
                side_a_end,
                side_b_length,
                floor_type,
            );
            floor.tint = tint;
        }
    }

    pub const BillboardObjectType = enum {
        small_bush,
    };

    /// Returns the object id of the created billboard object on success.
    pub fn addBillboardObject(
        self: *LevelGeometry,
        object_type: BillboardObjectType,
        position: util.FlatVector,
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
                wall.destroy();
                _ = self.walls.orderedRemove(index);
                return;
            }
        }
        for (self.floors.items) |*floor, index| {
            if (floor.object_id == object_id) {
                floor.destroy();
                _ = self.floors.orderedRemove(index);
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
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = tint;
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = tint;
        }
    }

    pub fn untintObject(self: *LevelGeometry, object_id: u64) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = Wall.getDefaultTint(wall.wall_type);
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = Floor.getDefaultTint(floor.floor_type);
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = BillboardObject.getDefaultTint(billboard.object_type);
        }
    }

    /// If the given ray hits the ground within a not too large distance, return the position on the
    /// ground.
    pub fn cast3DRayToGround(_: LevelGeometry, ray: rl.Ray) ?util.FlatVector {
        if (std.math.signbit(ray.position.y) == std.math.signbit(ray.direction.y)) {
            return null;
        }
        if (std.math.fabs(ray.direction.y) < util.Constants.epsilon) {
            return null;
        }
        const offset_from_start = util.FlatVector{
            .x = -ray.position.y / (ray.direction.y / ray.direction.x),
            .z = -ray.position.y / (ray.direction.y / ray.direction.z),
        };
        if (offset_from_start.length() > 500) {
            return null;
        }
        return util.FlatVector.fromVector3(ray.position).add(offset_from_start);
    }

    pub const RayCollision = struct {
        object_id: u64,
        distance: f32,
    };

    /// Find the id of the closest wall hit by the given ray, if available.
    pub fn cast3DRayToWalls(self: LevelGeometry, ray: rl.Ray, ignore_fences: bool) ?RayCollision {
        var result: ?RayCollision = null;
        for (self.walls.items) |wall| {
            if (ignore_fences and Wall.isFence(wall.wall_type)) {
                continue;
            }
            const hit = rl.GetRayCollisionMesh(ray, wall.mesh, wall.precomputed_matrix);
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
    pub fn collidesWithCircle(self: LevelGeometry, circle: collision.Circle) ?util.FlatVector {
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
    pub fn collidesWithLine(self: LevelGeometry, line_start: util.FlatVector, line_end: util.FlatVector) bool {
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
};

const Floor = struct {
    object_id: u64,
    floor_type: LevelGeometry.FloorType,
    mesh: rl.Mesh,
    precomputed_matrix: rl.Matrix,
    boundaries: collision.Rectangle,
    tint: rl.Color,

    /// Values used to generate this floor.
    side_a_start: util.FlatVector,
    side_a_end: util.FlatVector,
    side_b_length: f32,

    /// Side a and b can be chosen arbitrarily, but must be adjacent.
    fn create(
        object_id: u64,
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
        floor_type: LevelGeometry.FloorType,
    ) Floor {
        const offset_a = side_a_end.subtract(side_a_start);
        const side_a_length = offset_a.length();

        var floor_vertices = [18]f32{
            -0.5, 0, 0.5,
            0.5,  0, -0.5,
            -0.5, 0, -0.5,
            -0.5, 0, 0.5,
            0.5,  0, 0.5,
            0.5,  0, -0.5,
        };
        const texture_scale = getDefaultTextureScale(floor_type);
        const texture_corners = [4]rl.Vector2{
            .{ .x = 0, .y = 0 },
            .{ .x = side_b_length / texture_scale, .y = side_a_length / texture_scale },
            .{ .x = 0, .y = side_a_length / texture_scale },
            .{ .x = side_b_length / texture_scale, .y = 0 },
        };
        const texture_corner_indices = [6]u3{ 0, 1, 2, 0, 3, 1 };
        var texcoords_buffer: [12]f32 = undefined;
        var mesh = generateMesh(
            floor_vertices[0..],
            texture_corners[0..],
            texture_corner_indices[0..],
            &texcoords_buffer,
        );
        mesh.vertices = null; // Not needed for floors.

        const rotation = offset_a.computeRotationToOtherVector(util.FlatVector{ .x = 0, .z = 1 });
        const offset_b = offset_a.rotateRightBy90Degrees().negate().normalize().scale(side_b_length);
        const center = side_a_start.add(offset_a.scale(0.5)).add(offset_b.scale(0.5));
        return Floor{
            .object_id = object_id,
            .floor_type = floor_type,
            .mesh = mesh,
            .precomputed_matrix = rm.MatrixMultiply(rm.MatrixMultiply(
                rm.MatrixScale(side_b_length, 1, side_a_length),
                rm.MatrixRotateY(-rotation),
            ), rm.MatrixTranslate(center.x, 0, center.z)),
            .boundaries = collision.Rectangle.create(side_a_start, side_a_end, side_b_length),
            .tint = getDefaultTint(floor_type),
            .side_a_start = side_a_start,
            .side_a_end = side_a_end,
            .side_b_length = side_b_length,
        };
    }

    fn destroy(self: *Floor) void {
        rl.UnloadMesh(self.mesh);
    }

    /// If the given ray hits this object, return the position on the floor.
    fn cast3DRay(self: Floor, ray: rl.Ray) ?util.FlatVector {
        const ray_collision = rl.GetRayCollisionMesh(ray, self.mesh, self.precomputed_matrix);
        return if (ray_collision.hit)
            util.FlatVector.fromVector3(ray_collision.point)
        else
            null;
    }

    fn getDefaultTextureScale(floor_type: LevelGeometry.FloorType) f32 {
        return switch (floor_type) {
            else => 5.0,
            .water => 3.0,
        };
    }

    fn getDefaultTint(floor_type: LevelGeometry.FloorType) rl.Color {
        return switch (floor_type) {
            else => rl.WHITE,
        };
    }

    fn getTexture(
        self: Floor,
        floor_animation_cycle: animation.FourStepCycle,
        texture_collection: textures.Collection,
    ) rl.Texture {
        return switch (self.floor_type) {
            .grass => texture_collection.get(textures.Name.grass),
            .stone => texture_collection.get(textures.Name.stone_floor),
            .water => switch (floor_animation_cycle.getFrame()) {
                else => texture_collection.get(textures.Name.water_frame_0),
                1 => texture_collection.get(textures.Name.water_frame_1),
                2 => texture_collection.get(textures.Name.water_frame_2),
            },
        };
    }
};

const Wall = struct {
    object_id: u64,
    mesh: rl.Mesh,
    precomputed_matrix: rl.Matrix,
    tint: rl.Color,
    boundaries: collision.Rectangle,
    wall_type: LevelGeometry.WallType,

    /// Values used to generate this wall.
    start_position: util.FlatVector,
    end_position: util.FlatVector,

    /// Keeps a reference to the given vertices for its entire lifetime.
    fn create(
        object_id: u64,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
        wall_type: LevelGeometry.WallType,
        shared_wall_vertices: []f32,
        shared_fence_vertices: []f32,
    ) Wall {
        const wall_type_properties = getWallTypeProperties(start_position, end_position, wall_type);
        const offset = wall_type_properties.corrected_end_position.subtract(
            wall_type_properties.corrected_start_position,
        );
        const width = offset.length();
        const x_axis = util.FlatVector{ .x = 1, .z = 0 };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);

        const height = wall_type_properties.height;
        const texture_scale = wall_type_properties.texture_scale;

        // When generating a fence, the thickness is only relevant for collision boundaries.
        const thickness = wall_type_properties.thickness;

        const mesh = if (isFence(wall_type))
            generateDoubleSidedPlane(width, height, texture_scale, shared_fence_vertices)
        else
            generateBottomlessCube(width, height, thickness, texture_scale, shared_wall_vertices);
        const scale_matrix = if (isFence(wall_type))
            rm.MatrixScale(width, height, 1)
        else
            rm.MatrixScale(width, height, thickness);

        const side_a_up_offset = util.FlatVector
            .normalize(util.FlatVector{ .x = offset.z, .z = -offset.x })
            .scale(thickness / 2);
        return Wall{
            .object_id = object_id,
            .mesh = mesh,
            .precomputed_matrix = rm.MatrixMultiply(
                rm.MatrixMultiply(scale_matrix, rm.MatrixRotateY(rotation_angle)),
                rm.MatrixTranslate(
                    wall_type_properties.corrected_start_position.x,
                    0,
                    wall_type_properties.corrected_start_position.z,
                ),
            ),
            .tint = Wall.getDefaultTint(wall_type),
            .boundaries = collision.Rectangle.create(
                wall_type_properties.corrected_start_position.add(side_a_up_offset),
                wall_type_properties.corrected_start_position.subtract(side_a_up_offset),
                width,
            ),
            .wall_type = wall_type,
            .start_position = start_position,
            .end_position = end_position,
        };
    }

    fn destroy(self: *Wall) void {
        self.mesh.vertices = null; // Prevent raylib from freeing our shared mesh.
        rl.UnloadMesh(self.mesh);
    }

    /// Will keep a reference to the given vertices for the rest of its lifetime.
    fn generateBottomlessCube(
        width: f32,
        height: f32,
        thickness: f32,
        texture_scale: f32,
        shared_vertices: []f32,
    ) rl.Mesh {
        const texture_corners = [8]rl.Vector2{
            rl.Vector2{ .x = 0, .y = 0 },
            rl.Vector2{ .x = width / texture_scale, .y = 0 },
            rl.Vector2{ .x = width / texture_scale, .y = height / texture_scale },
            rl.Vector2{ .x = 0, .y = height / texture_scale },
            rl.Vector2{ .x = thickness / texture_scale, .y = 0 },
            rl.Vector2{ .x = thickness / texture_scale, .y = height / texture_scale },
            rl.Vector2{ .x = width / texture_scale, .y = thickness / texture_scale },
            rl.Vector2{ .x = 0, .y = thickness / texture_scale },
        };
        const texture_corner_indices = [30]u3{
            0, 3, 1, 3, 2, 1, // Front side.
            4, 0, 3, 4, 3, 5, // Left side.
            7, 1, 0, 7, 6, 1, // Top side.
            1, 0, 2, 2, 0, 3, // Back side.
            0, 3, 4, 4, 3, 5, // Right side.
        };
        var texcoords_buffer: [computeBottomlessCubeVertices().len / 3 * 2]f32 = undefined;
        return generateMesh(
            shared_vertices,
            texture_corners[0..],
            texture_corner_indices[0..],
            &texcoords_buffer,
        );
    }

    // Return the mesh of a wall. It has fixed dimensions of 1 and must be scaled by individual
    // transformation matrices to the desired size. This mesh has no bottom.
    fn computeBottomlessCubeVertices() [90]f32 {
        const corners = [8]rl.Vector3{
            rl.Vector3{ .x = 0, .y = 1, .z = 0.5 },
            rl.Vector3{ .x = 0, .y = 0, .z = 0.5 },
            rl.Vector3{ .x = 1, .y = 1, .z = 0.5 },
            rl.Vector3{ .x = 1, .y = 0, .z = 0.5 },
            rl.Vector3{ .x = 0, .y = 1, .z = -0.5 },
            rl.Vector3{ .x = 0, .y = 0, .z = -0.5 },
            rl.Vector3{ .x = 1, .y = 1, .z = -0.5 },
            rl.Vector3{ .x = 1, .y = 0, .z = -0.5 },
        };
        const corner_indices = [30]u3{
            0, 1, 2, 1, 3, 2, // Front side.
            0, 4, 5, 0, 5, 1, // Left side.
            0, 6, 4, 0, 2, 6, // Top side.
            4, 6, 5, 5, 6, 7, // Back side.
            2, 3, 6, 6, 3, 7, // Right side.
        };
        var vertices: [90]f32 = undefined;
        populateVertices(&vertices, corners[0..], corner_indices[0..]);
        return vertices;
    }

    /// Will keep a reference to the given vertices for the rest of its lifetime.
    fn generateDoubleSidedPlane(
        width: f32,
        height: f32,
        texture_scale: f32,
        shared_vertices: []f32,
    ) rl.Mesh {
        const texture_corners = [4]rl.Vector2{
            rl.Vector2{ .x = 0, .y = 0 },
            rl.Vector2{ .x = width / texture_scale, .y = 0 },
            rl.Vector2{ .x = width / texture_scale, .y = height / texture_scale },
            rl.Vector2{ .x = 0, .y = height / texture_scale },
        };
        const texture_corner_indices = [12]u3{
            0, 3, 1, 3, 2, 1, // Front side.
            1, 0, 2, 2, 0, 3, // Back side.
        };
        var texcoords_buffer: [computeDoubleSidedPlaneVertices().len / 3 * 2]f32 = undefined;
        return generateMesh(
            shared_vertices,
            texture_corners[0..],
            texture_corner_indices[0..],
            &texcoords_buffer,
        );
    }

    // Return the mesh of a fence. It has fixed dimensions of 1 and must be scaled by individual
    // transformation matrices to the desired size.
    fn computeDoubleSidedPlaneVertices() [36]f32 {
        const corners = [4]rl.Vector3{
            rl.Vector3{ .x = 0, .y = 1, .z = 0 },
            rl.Vector3{ .x = 0, .y = 0, .z = 0 },
            rl.Vector3{ .x = 1, .y = 1, .z = 0 },
            rl.Vector3{ .x = 1, .y = 0, .z = 0 },
        };
        const corner_indices = [12]u3{
            0, 1, 2, 1, 3, 2, // Front side.
            0, 2, 1, 1, 2, 3, // Back side.
        };
        var vertices: [36]f32 = undefined;
        populateVertices(&vertices, corners[0..], corner_indices[0..]);
        return vertices;
    }

    fn populateVertices(vertices: []f32, corners: []const rl.Vector3, corner_indices: []const u3) void {
        var index: usize = 0;
        while (index < vertices.len) : (index += 3) {
            vertices[index] = corners[corner_indices[index / 3]].x;
            vertices[index + 1] = corners[corner_indices[index / 3]].y;
            vertices[index + 2] = corners[corner_indices[index / 3]].z;
        }
    }

    const WallTypeProperties = struct {
        corrected_start_position: util.FlatVector,
        corrected_end_position: util.FlatVector,
        height: f32,
        thickness: f32,
        texture_scale: f32,
    };

    fn getWallTypeProperties(
        start_position: util.FlatVector,
        end_position: util.FlatVector,
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

    fn getTexture(self: Wall, texture_collection: textures.Collection) rl.Texture {
        return switch (self.wall_type) {
            .metal_fence, .short_metal_fence => texture_collection.get(textures.Name.metal_fence),
            .tall_hedge => texture_collection.get(textures.Name.hedge),
            else => texture_collection.get(textures.Name.wall),
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
        position: util.FlatVector,
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
            .small_bush => texture_collection.get(textures.Name.small_bush),
        };
    }
};

/// The returned mesh will keep a reference to the given shared_vertices.
fn generateMesh(
    shared_vertices: []f32,
    texture_corners: []const rl.Vector2,
    texture_corner_indices: []const u3,
    texcoords_buffer: []f32,
) rl.Mesh {
    const texcoords_count = shared_vertices.len / 3 * 2;
    std.debug.assert(texcoords_buffer.len >= texcoords_count);

    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertices = shared_vertices.ptr;
    mesh.vertexCount = @intCast(c_int, shared_vertices.len / 3);
    mesh.triangleCount = @intCast(c_int, shared_vertices.len / 9);

    mesh.texcoords = texcoords_buffer.ptr;
    var index: usize = 0;
    while (index < texcoords_count) : (index += 2) {
        texcoords_buffer[index] = texture_corners[texture_corner_indices[index / 2]].x;
        texcoords_buffer[index + 1] = texture_corners[texture_corner_indices[index / 2]].y;
    }

    rl.UploadMesh(&mesh, false);
    mesh.texcoords = null; // Was copied to GPU.
    return mesh;
}

const Json = struct {
    const SerializableData = struct {
        walls: []Json.Wall,
        floors: []Json.Floor,
        billboard_objects: []Json.BillboardObject,
    };

    const Wall = struct {
        wall_type: []const u8,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
    };

    const Floor = struct {
        floor_type: []const u8,
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
    };

    const BillboardObject = struct {
        object_type: []const u8,
        position: util.FlatVector,
    };
};
