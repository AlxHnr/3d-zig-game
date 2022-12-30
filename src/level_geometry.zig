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
    tick_counter: u64,

    walls: std.ArrayList(Wall),
    shared_wall_vertices: []f32,
    shared_fence_vertices: []f32,

    /// Floors are rendered in order, with the last floor at the top.
    floors: std.ArrayList(Floor),

    /// Used for invalidating prerendered floor textures.
    floor_change_counter: u64,
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
            .tick_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .shared_wall_vertices = shared_wall_vertices,
            .shared_fence_vertices = shared_fence_vertices,
            .floors = std.ArrayList(Floor).init(allocator),
            .floor_change_counter = 0,
            .floor_animation_cycle = animation.FourStepCycle.create(),
            .billboard_objects = std.ArrayList(BillboardObject).init(allocator),
        };
    }

    pub fn destroy(self: *LevelGeometry, allocator: std.mem.Allocator) void {
        for (self.walls.items) |*wall| {
            wall.destroy();
        }
        self.walls.deinit();
        allocator.free(self.shared_wall_vertices);
        allocator.free(self.shared_fence_vertices);
        self.floors.deinit();
        self.billboard_objects.deinit();
    }

    pub fn draw(
        self: LevelGeometry,
        camera: rl.Camera,
        prerendered_ground: PrerenderedGround,
        texture_collection: textures.Collection,
    ) void {
        for (self.walls.items) |wall| {
            const material = Wall.getRaylibAsset(wall.wall_type, texture_collection).material;
            drawTintedMesh(wall.mesh, material, wall.tint, wall.precomputed_matrix);
        }

        prerendered_ground.near_ground.draw();
        for (self.billboard_objects.items) |billboard| {
            rl.DrawBillboard(
                camera,
                billboard.getRaylibAsset(texture_collection).texture,
                rl.Vector3{
                    .x = billboard.boundaries.position.x,
                    .y = billboard.boundaries.radius,
                    .z = billboard.boundaries.position.z,
                },
                billboard.boundaries.radius * 2,
                billboard.tint,
            );
        }

        glad.glStencilFunc(glad.GL_NOTEQUAL, 1, 0xff);
        prerendered_ground.distant_ground.draw();
        glad.glStencilFunc(glad.GL_ALWAYS, 1, 0xff);
    }

    pub fn processElapsedTick(self: *LevelGeometry) void {
        // Value was picked to roughly sync up with the render interval in prerenderGround().
        const step_interval = 0.0166666;
        self.floor_animation_cycle.processStep(step_interval);
        self.tick_counter = self.tick_counter + 1;
    }

    /// Returned object must be released by the caller after use.
    pub fn createPrerenderedGround(_: LevelGeometry) PrerenderedGround {
        return .{
            .near_ground = PrerenderedGroundPlane.create(1024, 48, false),
            .distant_ground = PrerenderedGroundPlane.create(2048, 512, true),
            .state_of_change_counter_at_render = 0,
            .tick_counter_at_render = 0,
        };
    }

    pub fn prerenderGround(
        self: LevelGeometry,
        prerendered_ground: *PrerenderedGround,
        new_center_position: util.FlatVector,
        texture_collection: textures.Collection,
    ) void {
        const rerender_everything =
            prerendered_ground.state_of_change_counter_at_render != self.floor_change_counter;
        prerendered_ground.state_of_change_counter_at_render = self.floor_change_counter;

        if (rerender_everything or
            self.tick_counter - prerendered_ground.tick_counter_at_render >= 15)
        {
            prerendered_ground.near_ground.prerender(
                self.floors.items,
                self.floor_animation_cycle,
                new_center_position,
                texture_collection,
            );
            prerendered_ground.tick_counter_at_render = self.tick_counter;
        }

        const rerender_distant_floor = new_center_position
            .subtract(prerendered_ground.distant_ground.position).length() > 100;
        if (rerender_everything or rerender_distant_floor) {
            prerendered_ground.distant_ground.prerender(
                self.floors.items,
                self.floor_animation_cycle,
                new_center_position,
                texture_collection,
            );
        }
    }

    pub const PrerenderedGround = struct {
        near_ground: PrerenderedGroundPlane,
        distant_ground: PrerenderedGroundPlane,
        state_of_change_counter_at_render: u64,

        /// Rerendering the ground depends on the game state and thus on the ticks elapsed.
        tick_counter_at_render: u64,

        pub fn destroy(self: *PrerenderedGround) void {
            self.near_ground.destroy();
            self.distant_ground.destroy();
        }
    };

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
        self.floor_change_counter = self.floor_change_counter + 1;
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
            self.floor_change_counter = self.floor_change_counter + 1;
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
        for (self.floors.items) |floor, index| {
            if (floor.object_id == object_id) {
                _ = self.floors.orderedRemove(index);
                self.floor_change_counter = self.floor_change_counter + 1;
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
            self.floor_change_counter = self.floor_change_counter + 1;
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = tint;
        }
    }

    pub fn untintObject(self: *LevelGeometry, object_id: u64) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = Wall.getDefaultTint(wall.wall_type);
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = Floor.getDefaultTint(floor.floor_type);
            self.floor_change_counter = self.floor_change_counter + 1;
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

    fn drawTintedMesh(mesh: rl.Mesh, material: rl.Material, tint: rl.Color, matrix: rl.Matrix) void {
        const current_tint = material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color;
        material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color = tint;
        rl.DrawMesh(mesh, material, matrix);
        material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color = current_tint;
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
    boundaries: collision.Rectangle,
    side_a_start: util.FlatVector,
    side_a_length: f32,
    side_b_length: f32,
    rotation: f32,
    tint: rl.Color,

    /// Side a and b can be chosen arbitrarily, but must be adjacent.
    fn create(
        object_id: u64,
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
        floor_type: LevelGeometry.FloorType,
    ) Floor {
        const offset_a = side_a_end.subtract(side_a_start);
        return Floor{
            .object_id = object_id,
            .floor_type = floor_type,
            .boundaries = collision.Rectangle.create(side_a_start, side_a_end, side_b_length),
            .side_a_start = side_a_end,
            .side_a_length = offset_a.length(),
            .side_b_length = side_b_length,
            .rotation = offset_a.computeRotationToOtherVector(util.FlatVector{ .x = 0, .z = 1 }),
            .tint = getDefaultTint(floor_type),
        };
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

    fn getRaylibAsset(
        floor_type: LevelGeometry.FloorType,
        floor_animation_cycle: animation.FourStepCycle,
        texture_collection: textures.Collection,
    ) textures.RaylibAsset {
        return switch (floor_type) {
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
                    .height = 1.5,
                    .thickness = fence_thickness,
                    .texture_scale = 3.5,
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

    fn getRaylibAsset(
        wall_type: LevelGeometry.WallType,
        texture_collection: textures.Collection,
    ) textures.RaylibAsset {
        return switch (wall_type) {
            .metal_fence, .short_metal_fence => texture_collection.get(textures.Name.metal_fence),
            .tall_hedge => texture_collection.get(textures.Name.hedge),
            else => texture_collection.get(textures.Name.wall),
        };
    }
};

/// A piece of ground which floats trough the game world.
const PrerenderedGroundPlane = struct {
    render_texture: rl.RenderTexture,

    /// Wrapper around render texture.
    render_texture_material: rl.Material,

    genereate_mipmaps: bool,

    /// Helpers for rendering the ground.
    plane_mesh: rl.Mesh,
    mesh_matrix: rl.Matrix,

    /// Dimensions of this object in the game-world.
    position: util.FlatVector,
    width_and_height: f32,

    /// Creates a floating ground object at 0,0 in game-world coordinates. Takes the dimensions of
    /// the ground area to consider while prerendering.
    fn create(
        texture_size: u16,
        width_and_height: f32,
        genereate_mipmaps: bool,
    ) PrerenderedGroundPlane {
        return .{
            .render_texture = rl.LoadRenderTexture(texture_size, texture_size),
            .render_texture_material = rl.LoadMaterialDefault(),
            .genereate_mipmaps = genereate_mipmaps,
            .plane_mesh = rl.GenMeshPlane(width_and_height, width_and_height, 1, 1),
            .mesh_matrix = rm.MatrixIdentity(),
            .position = .{ .x = 0, .z = 0 },
            .width_and_height = width_and_height,
        };
    }

    fn destroy(self: *PrerenderedGroundPlane) void {
        rl.UnloadMesh(self.plane_mesh);
        rl.UnloadMaterial(self.render_texture_material);
        rl.UnloadRenderTexture(self.render_texture);
    }

    fn prerender(
        self: *PrerenderedGroundPlane,
        floors: []Floor,
        floor_animation_cycle: animation.FourStepCycle,
        new_center_position: util.FlatVector,
        texture_collection: textures.Collection,
    ) void {
        self.position = new_center_position;

        const translation = self.position.add(.{
            .x = -self.width_and_height / 2,
            .z = self.width_and_height / 2,
        });
        const gameworld_to_texture_ratio = util.FlatVector{
            .x = @intToFloat(f32, self.render_texture.texture.width) / self.width_and_height,
            .z = @intToFloat(f32, self.render_texture.texture.height) / self.width_and_height,
        };

        rl.BeginTextureMode(self.render_texture);
        rl.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        for (floors) |floor| {
            const texture = Floor.getRaylibAsset(
                floor.floor_type,
                floor_animation_cycle,
                texture_collection,
            ).texture;
            const texture_scale = Floor.getDefaultTextureScale(floor.floor_type);
            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, texture.width) * floor.side_b_length / texture_scale,
                .height = @intToFloat(f32, texture.height) * floor.side_a_length / texture_scale,
            };
            const translated_side_a_start = floor.side_a_start.subtract(translation);
            const dest_rect = rl.Rectangle{
                .x = translated_side_a_start.x * gameworld_to_texture_ratio.x,
                .y = translated_side_a_start.z * -gameworld_to_texture_ratio.z,
                .width = floor.side_b_length * gameworld_to_texture_ratio.x,
                .height = floor.side_a_length * gameworld_to_texture_ratio.z,
            };
            const origin = rl.Vector2{ .x = 0, .y = 0 };
            const angle = -util.radiansToDegrees(floor.rotation);
            rl.DrawTexturePro(texture, source_rect, dest_rect, origin, angle, floor.tint);

            self.mesh_matrix = rm.MatrixTranslate(self.position.x, 0, self.position.z);
        }

        rl.EndTextureMode();

        if (self.genereate_mipmaps) {
            rl.GenTextureMipmaps(&self.render_texture.texture);
            rl.SetTextureFilter(
                self.render_texture.texture,
                @enumToInt(rl.TextureFilter.TEXTURE_FILTER_TRILINEAR),
            );
        }
    }

    fn draw(self: PrerenderedGroundPlane) void {
        const key = @enumToInt(rl.MATERIAL_MAP_DIFFUSE);
        const material_default_texture = self.render_texture_material.maps[key].texture;
        self.render_texture_material.maps[key].texture = self.render_texture.texture;
        rl.DrawMesh(self.plane_mesh, self.render_texture_material, self.mesh_matrix);
        self.render_texture_material.maps[key].texture = material_default_texture;
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

    fn getRaylibAsset(self: BillboardObject, texture_collection: textures.Collection) textures.RaylibAsset {
        return switch (self.object_type) {
            .small_bush => texture_collection.get(textures.Name.small_bush),
        };
    }
};
