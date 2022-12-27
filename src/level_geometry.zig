const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const textures = @import("textures.zig");

pub const LevelGeometry = struct {
    ground: Floor,
    level_boundaries: [4]Wall,

    object_id_counter: u64,
    walls: std.ArrayList(Wall),
    shared_wall_vertices: []f32,

    /// Stores the given allocator internally for its entire lifetime.
    pub fn create(allocator: std.mem.Allocator, max_width_and_heigth: f32) !LevelGeometry {
        var ground = try Floor.create(allocator, max_width_and_heigth);
        errdefer ground.destroy(allocator);

        const precomputed_wall_vertices = Wall.computeVertices();
        var shared_wall_vertices = try allocator.alloc(f32, precomputed_wall_vertices.len);
        std.mem.copy(f32, shared_wall_vertices, precomputed_wall_vertices[0..]);

        const half_size = max_width_and_heigth / 2;
        const level_corners = [4]util.FlatVector{
            util.FlatVector{ .x = -half_size, .z = half_size },
            util.FlatVector{ .x = half_size, .z = half_size },
            util.FlatVector{ .x = half_size, .z = -half_size },
            util.FlatVector{ .x = -half_size, .z = -half_size },
        };
        const wall_type = WallType.SmallWall;
        const level_boundaries = [4]Wall{
            // Object id is not relevant here.
            Wall.create(0, level_corners[0], level_corners[1], wall_type, shared_wall_vertices),
            Wall.create(0, level_corners[1], level_corners[2], wall_type, shared_wall_vertices),
            Wall.create(0, level_corners[2], level_corners[3], wall_type, shared_wall_vertices),
            Wall.create(0, level_corners[3], level_corners[0], wall_type, shared_wall_vertices),
        };

        return LevelGeometry{
            .ground = ground,
            .level_boundaries = level_boundaries,
            .object_id_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .shared_wall_vertices = shared_wall_vertices,
        };
    }

    pub fn destroy(self: *LevelGeometry, allocator: std.mem.Allocator) void {
        self.ground.destroy(allocator);
        for (self.level_boundaries) |*level_boundary| {
            level_boundary.destroy();
        }
        for (self.walls.items) |*wall| {
            wall.destroy();
        }
        self.walls.deinit();
        allocator.free(self.shared_wall_vertices);
    }

    pub fn draw(self: LevelGeometry, texture_collection: textures.Collection) void {
        for (self.walls.items) |wall| {
            const material = Wall.getRaylibAsset(wall.wall_type, texture_collection).material;
            const current_tint = material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color;

            material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color = wall.tint;
            rl.DrawMesh(wall.mesh, material, wall.precomputed_matrix);
            material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color = current_tint;
        }

        self.ground.draw(texture_collection.get(textures.Name.floor).material);
    }

    pub const WallType = enum {
        SmallWall,
        MediumWall,
        CastleWall,
        CastleTower,
        GigaWall,
        TallHedge,
    };

    /// Returns the id of the created wall on success.
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
        );
        self.object_id_counter = self.object_id_counter + 1;
        return wall.object_id;
    }

    /// If the given object id does not exist, this function will do nothing.
    pub fn removeWall(self: *LevelGeometry, object_id: u64) void {
        for (self.walls.items) |*wall, index| {
            if (wall.object_id == object_id) {
                wall.destroy();
                _ = self.walls.orderedRemove(index);
                return;
            }
        }
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
            );
            wall.tint = tint;
        }
    }

    pub fn tintWall(self: *LevelGeometry, object_id: u64, tint: rl.Color) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = tint;
        }
    }

    pub fn untintWall(self: *LevelGeometry, object_id: u64) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = Wall.getDefaultTint(wall.wall_type);
        }
    }

    /// If the given ray hits the level grid, return the position on the ground.
    pub fn cast3DRayToGround(self: LevelGeometry, ray: rl.Ray) ?util.FlatVector {
        return self.ground.cast3DRay(ray);
    }

    pub const RayCollision = struct {
        object_id: u64,
        distance: f32,
    };

    /// Find the id of the closest wall hit by the given ray, if available.
    pub fn cast3DRayToWalls(self: LevelGeometry, ray: rl.Ray) ?RayCollision {
        var result: ?RayCollision = null;
        for (self.walls.items) |wall| {
            const ray_collision = rl.GetRayCollisionMesh(ray, wall.mesh, wall.precomputed_matrix);
            const found_closer_wall = if (!ray_collision.hit)
                false
            else if (result) |existing_result|
                ray_collision.distance < existing_result.distance
            else
                true;
            if (found_closer_wall) {
                result = RayCollision{ .object_id = wall.object_id, .distance = ray_collision.distance };
            }
        }
        return result;
    }

    /// If a collision occurs, return a displacement vector for moving the given circle out of the
    /// level geometry. The returned displacement vector must be added to the given circles position
    /// to resolve the collision.
    pub fn collidesWithCircle(self: LevelGeometry, circle: collision.Circle) ?util.FlatVector {
        var found_collision = false;
        var displaced_circle = circle;

        // Move displaced_circle out of all walls.
        for (self.level_boundaries) |level_boundary| {
            updateDisplacedCircle(level_boundary, &displaced_circle, &found_collision);
        }
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
        for (self.level_boundaries) |level_boundary| {
            if (level_boundary.boundaries.collidesWithLine(line_start, line_end)) {
                return true;
            }
        }
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

    /// If the given wall collides with the circle, move the circle out of the wall and set
    /// found_collision to true. Without a collision this boolean will remain unchanged.
    fn updateDisplacedCircle(wall: Wall, circle: *collision.Circle, found_collision: *bool) void {
        if (circle.collidesWithRectangle(wall.boundaries)) |displacement_vector| {
            circle.position = circle.position.add(displacement_vector);
            found_collision.* = true;
        }
    }
};

const Floor = struct {
    vertices: []f32,
    mesh: rl.Mesh,

    fn create(allocator: std.mem.Allocator, side_length: f32) !Floor {
        var vertices = try allocator.alloc(f32, 6 * 3);
        std.mem.copy(f32, vertices, &[6 * 3]f32{
            -side_length / 2, 0, side_length / 2,
            side_length / 2,  0, -side_length / 2,
            -side_length / 2, 0, -side_length / 2,
            -side_length / 2, 0, side_length / 2,
            side_length / 2,  0, side_length / 2,
            side_length / 2,  0, -side_length / 2,
        });

        const texture_scale = 5.0;
        var texcoords = [6 * 2]f32{
            0,                           0,
            side_length / texture_scale, side_length / texture_scale,
            0,                           side_length / texture_scale,
            0,                           0,
            side_length / texture_scale, 0,
            side_length / texture_scale, side_length / texture_scale,
        };

        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertices = vertices.ptr;
        mesh.vertexCount = @intCast(c_int, vertices.len / 3);
        mesh.triangleCount = @intCast(c_int, vertices.len / 9);
        mesh.texcoords = &texcoords;

        rl.UploadMesh(&mesh, false);
        mesh.texcoords = null; // Was copied to GPU.

        return Floor{ .vertices = vertices, .mesh = mesh };
    }

    fn destroy(self: *Floor, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        self.mesh.vertices = null; // Prevent raylib from freeing our own vertices.
        rl.UnloadMesh(self.mesh);
    }

    fn draw(self: Floor, material: rl.Material) void {
        rl.DrawMesh(self.mesh, material, rm.MatrixIdentity());
    }

    /// If the given ray hits this object, return the position on the floor.
    fn cast3DRay(self: Floor, ray: rl.Ray) ?util.FlatVector {
        const ray_collision = rl.GetRayCollisionMesh(ray, self.mesh, rm.MatrixIdentity());
        return if (ray_collision.hit)
            util.FlatVector.fromVector3(ray_collision.point)
        else
            null;
    }
};

const Wall = struct {
    object_id: u64,
    mesh: rl.Mesh,
    precomputed_matrix: rl.Matrix,
    tint: rl.Color,
    boundaries: collision.Rectangle,
    wall_type: LevelGeometry.WallType,

    /// Keeps a reference to the given wall vertices for its entire lifetime.
    fn create(
        object_id: u64,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
        wall_type: LevelGeometry.WallType,
        shared_wall_vertices: []f32,
    ) Wall {
        const wall_type_properties = getWallTypeProperties(start_position, end_position, wall_type);
        const offset = wall_type_properties.corrected_end_position.subtract(
            wall_type_properties.corrected_start_position,
        );
        const width = offset.length();
        const x_axis = util.FlatVector{ .x = 1, .z = 0 };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);

        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertices = shared_wall_vertices.ptr;
        mesh.vertexCount = @intCast(c_int, shared_wall_vertices.len / 3);
        mesh.triangleCount = @intCast(c_int, shared_wall_vertices.len / 9);

        const height = wall_type_properties.height;
        const thickness = wall_type_properties.thickness;
        const texture_scale = wall_type_properties.texture_scale;
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
        var texcoords: [computeVertices().len / 3 * 2]f32 = undefined;
        mesh.texcoords = &texcoords;
        var index: usize = 0;
        while (index < texcoords.len) : (index += 2) {
            texcoords[index] = texture_corners[texture_corner_indices[index / 2]].x;
            texcoords[index + 1] = texture_corners[texture_corner_indices[index / 2]].y;
        }

        rl.UploadMesh(&mesh, false);
        mesh.texcoords = null; // Was copied to GPU.

        const side_a_up_offset = util.FlatVector
            .normalize(util.FlatVector{ .x = offset.z, .z = -offset.x })
            .scale(thickness / 2);

        return Wall{
            .object_id = object_id,
            .mesh = mesh,
            .precomputed_matrix = rm.MatrixMultiply(rm.MatrixMultiply(
                rm.MatrixScale(width, height, thickness),
                rm.MatrixRotateY(rotation_angle),
            ), rm.MatrixTranslate(
                wall_type_properties.corrected_start_position.x,
                0,
                wall_type_properties.corrected_start_position.z,
            )),
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

    // Return the mesh of a wall. It has fixed dimensions of 1 and must be scaled by individual
    // transformation matrices to the desired size. This mesh has no bottom.
    fn computeVertices() [90]f32 {
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
        var index: usize = 0;
        while (index < vertices.len) : (index += 3) {
            vertices[index] = corners[corner_indices[index / 3]].x;
            vertices[index + 1] = corners[corner_indices[index / 3]].y;
            vertices[index + 2] = corners[corner_indices[index / 3]].z;
        }
        return vertices;
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
        return switch (wall_type) {
            LevelGeometry.WallType.SmallWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 5,
                    .thickness = 0.25,
                    .texture_scale = 5.0,
                };
            },
            LevelGeometry.WallType.CastleWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 15,
                    .thickness = 2,
                    .texture_scale = 7.5,
                };
            },
            LevelGeometry.WallType.CastleTower => {
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
            LevelGeometry.WallType.GigaWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 140,
                    .thickness = 6,
                    .texture_scale = 16.0,
                };
            },
            LevelGeometry.WallType.TallHedge => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 8,
                    .thickness = 3,
                    .texture_scale = 3.5,
                };
            },
            else => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 10,
                    .thickness = 1,
                    .texture_scale = 5.0,
                };
            },
        };
    }

    fn getDefaultTint(wall_type: LevelGeometry.WallType) rl.Color {
        return switch (wall_type) {
            LevelGeometry.WallType.CastleTower => rl.Color{ .r = 248, .g = 248, .b = 248, .a = 255 },
            LevelGeometry.WallType.GigaWall => rl.Color{ .r = 170, .g = 170, .b = 170, .a = 255 },
            else => rl.WHITE,
        };
    }

    fn getRaylibAsset(
        wall_type: LevelGeometry.WallType,
        texture_collection: textures.Collection,
    ) textures.RaylibAsset {
        return switch (wall_type) {
            LevelGeometry.WallType.TallHedge => texture_collection.get(textures.Name.hedge),
            else => texture_collection.get(textures.Name.wall),
        };
    }
};
