const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const textures = @import("textures.zig");

pub const LevelGeometry = struct {
    object_id_counter: u64,

    walls: std.ArrayList(Wall),
    shared_wall_vertices: []f32,

    /// Floors are rendered in order, with the last floor at the top.
    floors: std.ArrayList(Floor),
    prerendered_ground: PrerenderedGround,

    /// Stores the given allocator internally for its entire lifetime.
    pub fn create(allocator: std.mem.Allocator, max_width_and_heigth: f32) !LevelGeometry {
        const precomputed_wall_vertices = Wall.computeVertices();
        var shared_wall_vertices = try allocator.alloc(f32, precomputed_wall_vertices.len);
        errdefer allocator.free(shared_wall_vertices);
        std.mem.copy(f32, shared_wall_vertices, precomputed_wall_vertices[0..]);

        return LevelGeometry{
            .object_id_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .shared_wall_vertices = shared_wall_vertices,
            .floors = std.ArrayList(Floor).init(allocator),
            .prerendered_ground = PrerenderedGround.create(max_width_and_heigth),
        };
    }

    pub fn destroy(self: *LevelGeometry, allocator: std.mem.Allocator) void {
        for (self.walls.items) |*wall| {
            wall.destroy();
        }
        self.walls.deinit();
        allocator.free(self.shared_wall_vertices);

        self.floors.deinit();
        self.prerendered_ground.destroy();
    }

    pub fn prerenderGround(self: *LevelGeometry, texture_collection: textures.Collection) void {
        self.prerendered_ground.prerender(self.floors.items, texture_collection);
    }

    pub fn draw(self: LevelGeometry, texture_collection: textures.Collection) void {
        for (self.walls.items) |wall| {
            const material = Wall.getRaylibAsset(wall.wall_type, texture_collection).material;
            drawTintedMesh(wall.mesh, material, wall.tint, wall.precomputed_matrix);
        }

        self.prerendered_ground.draw();
    }

    pub const WallType = enum {
        SmallWall,
        MediumWall,
        CastleWall,
        CastleTower,
        GigaWall,
        TallHedge,
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
            );
            wall.tint = tint;
        }
    }

    pub const FloorType = enum {
        grass,
        stone,
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
                _ = self.floors.orderedRemove(index);
                return;
            }
        }
    }

    pub fn tintObject(self: *LevelGeometry, object_id: u64, tint: rl.Color) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = tint;
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = tint;
        }
    }

    pub fn untintObject(self: *LevelGeometry, object_id: u64) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = Wall.getDefaultTint(wall.wall_type);
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = Floor.getDefaultTint(floor.floor_type);
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
    pub fn cast3DRayToWalls(self: LevelGeometry, ray: rl.Ray) ?RayCollision {
        var result: ?RayCollision = null;
        for (self.walls.items) |wall| {
            result = getCloserRayHit(ray, wall.mesh, wall.precomputed_matrix, wall.object_id, result);
        }
        return result;
    }

    /// Find the id of the closest object hit by the given ray, if available.
    pub fn cast3DRayToObjects(self: LevelGeometry, ray: rl.Ray) ?RayCollision {
        // Walls are covering floors and are prioritized.
        if (self.cast3DRayToWalls(ray)) |ray_collision| {
            return ray_collision;
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
        ray: rl.Ray,
        mesh: rl.Mesh,
        precomputed_matrix: rl.Matrix,
        object_id: u64,
        current_collision: ?RayCollision,
    ) ?RayCollision {
        const hit = rl.GetRayCollisionMesh(ray, mesh, precomputed_matrix);
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
        };
    }

    fn getDefaultTint(floor_type: LevelGeometry.FloorType) rl.Color {
        return switch (floor_type) {
            else => rl.WHITE,
        };
    }

    fn getRaylibAsset(
        floor_type: LevelGeometry.FloorType,
        texture_collection: textures.Collection,
    ) textures.RaylibAsset {
        return switch (floor_type) {
            .grass => texture_collection.get(textures.Name.grass),
            .stone => texture_collection.get(textures.Name.stone_floor),
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
            .SmallWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 5,
                    .thickness = 0.25,
                    .texture_scale = 5.0,
                };
            },
            .CastleWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 15,
                    .thickness = 2,
                    .texture_scale = 7.5,
                };
            },
            .CastleTower => {
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
            .GigaWall => {
                return WallTypeProperties{
                    .corrected_start_position = start_position,
                    .corrected_end_position = end_position,
                    .height = 140,
                    .thickness = 6,
                    .texture_scale = 16.0,
                };
            },
            .TallHedge => {
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
            .CastleTower => rl.Color{ .r = 248, .g = 248, .b = 248, .a = 255 },
            .GigaWall => rl.Color{ .r = 170, .g = 170, .b = 170, .a = 255 },
            else => rl.WHITE,
        };
    }

    fn getRaylibAsset(
        wall_type: LevelGeometry.WallType,
        texture_collection: textures.Collection,
    ) textures.RaylibAsset {
        return switch (wall_type) {
            .TallHedge => texture_collection.get(textures.Name.hedge),
            else => texture_collection.get(textures.Name.wall),
        };
    }
};

/// A piece of ground which floats trough the game world.
const PrerenderedGround = struct {
    render_texture: rl.RenderTexture,

    /// Wrapper around render texture.
    render_texture_material: rl.Material,

    /// Helpers for moving the ground into 3d space.
    plane_mesh: rl.Mesh,
    mesh_matrix: rl.Matrix,

    /// Center of this object in the game-world.
    position_in_game: util.FlatVector,
    width_and_height: f32,

    /// Creates a floating ground object at 0,0 in game-world coordinates. Takes the dimensions of
    /// the ground area to consider while prerendering.
    fn create(width_and_height: f32) PrerenderedGround {
        return .{
            .render_texture = rl.LoadRenderTexture(1024, 1024),
            .render_texture_material = rl.LoadMaterialDefault(),
            .plane_mesh = rl.GenMeshPlane(width_and_height, width_and_height, 1, 1),
            .mesh_matrix = rm.MatrixIdentity(),
            .position_in_game = .{ .x = 0, .z = 0 },
            .width_and_height = width_and_height,
        };
    }

    fn destroy(self: *PrerenderedGround) void {
        rl.UnloadMesh(self.plane_mesh);
        rl.UnloadMaterial(self.render_texture_material);
        rl.UnloadRenderTexture(self.render_texture);
    }

    fn prerender(
        self: *PrerenderedGround,
        floors: []Floor,
        texture_collection: textures.Collection,
    ) void {
        rl.BeginTextureMode(self.render_texture);
        rl.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

        const translation = self.position_in_game.add(.{
            .x = -self.width_and_height / 2,
            .z = self.width_and_height / 2,
        });
        const gameworld_to_texture_ratio = util.FlatVector{
            .x = @intToFloat(f32, self.render_texture.texture.width) / self.width_and_height,
            .z = @intToFloat(f32, self.render_texture.texture.height) / self.width_and_height,
        };

        for (floors) |floor| {
            const texture = Floor.getRaylibAsset(floor.floor_type, texture_collection).texture;
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
        }

        rl.EndTextureMode();
    }

    fn draw(self: PrerenderedGround) void {
        const key = @enumToInt(rl.MATERIAL_MAP_DIFFUSE);
        const material_default_texture = self.render_texture_material.maps[key].texture;
        self.render_texture_material.maps[key].texture = self.render_texture.texture;
        rl.DrawMesh(self.plane_mesh, self.render_texture_material, self.mesh_matrix);
        self.render_texture_material.maps[key].texture = material_default_texture;
    }
};
