const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");

pub const Tint = enum { Default, Green, Red };

const Floor = struct {
    vertices: []f32,
    mesh: rl.Mesh,
    material: rl.Material,

    /// Will own the given texture.
    fn create(
        allocator: std.mem.Allocator,
        side_length: f32,
        texture: rl.Texture,
        texture_scale: f32,
    ) !Floor {
        var material = rl.LoadMaterialDefault();
        rl.SetMaterialTexture(&material, @enumToInt(rl.MATERIAL_MAP_DIFFUSE), texture);
        errdefer rl.UnloadMaterial(material);

        var vertices = try allocator.alloc(f32, 6 * 3);
        std.mem.copy(f32, vertices, &[6 * 3]f32{
            -side_length / 2, 0, side_length / 2,
            side_length / 2,  0, -side_length / 2,
            -side_length / 2, 0, -side_length / 2,
            -side_length / 2, 0, side_length / 2,
            side_length / 2,  0, side_length / 2,
            side_length / 2,  0, -side_length / 2,
        });
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

        return Floor{ .vertices = vertices, .mesh = mesh, .material = material };
    }

    fn destroy(self: *Floor, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        self.mesh.vertices = null; // Prevent raylib from freeing our own vertices.
        rl.UnloadMesh(self.mesh);
        rl.UnloadMaterial(self.material);
    }

    fn draw(self: Floor) void {
        rl.DrawMesh(self.mesh, self.material, rm.MatrixIdentity());
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
    id: u64,
    mesh: rl.Mesh,
    precomputed_matrix: rl.Matrix,
    tint: Tint,
    boundaries: collision.Rectangle,

    const height: f32 = 5;
    const thickness: f32 = 1;

    /// Keeps a reference to the given wall vertices for its entire lifetime.
    fn create(
        id: u64,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
        shared_wall_vertices: []f32,
        texture_scale: f32,
    ) Wall {
        const offset = end_position.subtract(start_position);
        const width = offset.length();
        const x_axis = util.FlatVector{ .x = 1, .z = 0 };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);

        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertices = shared_wall_vertices.ptr;
        mesh.vertexCount = @intCast(c_int, shared_wall_vertices.len / 3);
        mesh.triangleCount = @intCast(c_int, shared_wall_vertices.len / 9);

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
            .id = id,
            .mesh = mesh,
            .precomputed_matrix = rm.MatrixMultiply(rm.MatrixMultiply(
                rm.MatrixScale(width, 1, 1),
                rm.MatrixRotateY(rotation_angle),
            ), rm.MatrixTranslate(start_position.x, 0, start_position.z)),
            .tint = Tint.Default,
            .boundaries = collision.Rectangle.create(
                start_position.add(side_a_up_offset),
                start_position.subtract(side_a_up_offset),
                width,
            ),
        };
    }

    fn destroy(self: *Wall) void {
        self.mesh.vertices = null; // Prevent raylib from freeing our shared mesh.
        rl.UnloadMesh(self.mesh);
    }

    // Return the mesh of a wall. It has a fixed width of 1 and must be scaled by individual
    // transformation matrices to the desired length. This mesh has no bottom.
    fn computeVertices() [90]f32 {
        const corners = [8]rl.Vector3{
            rl.Vector3{ .x = 0, .y = Wall.height, .z = Wall.thickness / 2 },
            rl.Vector3{ .x = 0, .y = 0, .z = Wall.thickness / 2 },
            rl.Vector3{ .x = 1, .y = Wall.height, .z = Wall.thickness / 2 },
            rl.Vector3{ .x = 1, .y = 0, .z = Wall.thickness / 2 },
            rl.Vector3{ .x = 0, .y = Wall.height, .z = -Wall.thickness / 2 },
            rl.Vector3{ .x = 0, .y = 0, .z = -Wall.thickness / 2 },
            rl.Vector3{ .x = 1, .y = Wall.height, .z = -Wall.thickness / 2 },
            rl.Vector3{ .x = 1, .y = 0, .z = -Wall.thickness / 2 },
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
};

pub const Collection = struct {
    floor: Floor,
    wall_id_counter: u64,
    walls: std.ArrayList(Wall),
    wall_material: rl.Material,
    shared_wall_vertices: []f32,
    texture_scale: f32,

    /// Stores the given allocator internally for its entire lifetime. Will own the given textures.
    pub fn create(
        allocator: std.mem.Allocator,
        wall_texture: rl.Texture,
        floor_texture: rl.Texture,
        texture_scale: f32,
    ) !Collection {
        var wall_material = rl.LoadMaterialDefault();
        rl.SetMaterialTexture(&wall_material, @enumToInt(rl.MATERIAL_MAP_DIFFUSE), wall_texture);
        errdefer rl.UnloadMaterial(wall_material);

        var floor = try Floor.create(allocator, 100, floor_texture, texture_scale);
        errdefer floor.destroy(allocator);

        const precomputed_wall_vertices = Wall.computeVertices();
        var shared_wall_vertices = try allocator.alloc(f32, precomputed_wall_vertices.len);
        std.mem.copy(f32, shared_wall_vertices, precomputed_wall_vertices[0..]);

        return Collection{
            .floor = floor,
            .wall_id_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .wall_material = wall_material,
            .shared_wall_vertices = shared_wall_vertices,
            .texture_scale = texture_scale,
        };
    }

    pub fn destroy(self: *Collection, allocator: std.mem.Allocator) void {
        self.floor.destroy(allocator);
        for (self.walls.items) |*wall| {
            wall.destroy();
        }
        self.walls.deinit();
        rl.UnloadMaterial(self.wall_material);
        allocator.free(self.shared_wall_vertices);
    }

    pub fn draw(self: Collection) void {
        self.floor.draw();

        const key = @enumToInt(rl.MATERIAL_MAP_DIFFUSE);
        for (self.walls.items) |wall| {
            switch (wall.tint) {
                Tint.Default => self.wall_material.maps[key].color = rl.WHITE,
                Tint.Green => self.wall_material.maps[key].color = rl.GREEN,
                Tint.Red => self.wall_material.maps[key].color = rl.RED,
            }
            rl.DrawMesh(wall.mesh, self.wall_material, wall.precomputed_matrix);
        }
    }

    /// Returns the id of the created wall on success.
    pub fn addWall(
        self: *Collection,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
    ) !u64 {
        const wall = try self.walls.addOne();
        wall.* = Wall.create(
            self.wall_id_counter,
            start_position,
            end_position,
            self.shared_wall_vertices,
            self.texture_scale,
        );
        self.wall_id_counter = self.wall_id_counter + 1;
        return wall.id;
    }

    /// If the given wall id does not exist, this function will do nothing.
    pub fn removeWall(self: *Collection, wall_id: u64) void {
        for (self.walls.items) |*wall, index| {
            if (wall.id == wall_id) {
                wall.destroy();
                _ = self.walls.orderedRemove(index);
                return;
            }
        }
    }

    /// If the given wall id does not exist, this function will do nothing.
    pub fn updateWall(
        self: *Collection,
        wall_id: u64,
        start_position: util.FlatVector,
        end_position: util.FlatVector,
    ) void {
        if (self.findWall(wall_id)) |wall| {
            const tint = wall.tint;
            wall.destroy();
            wall.* = Wall.create(
                wall_id,
                start_position,
                end_position,
                self.shared_wall_vertices,
                self.texture_scale,
            );
            wall.tint = tint;
        }
    }

    pub fn tintWall(self: *Collection, wall_id: u64, tint: Tint) void {
        if (self.findWall(wall_id)) |wall| {
            wall.tint = tint;
        }
    }

    pub fn findWall(self: *Collection, wall_id: u64) ?*Wall {
        for (self.walls.items) |*wall| {
            if (wall.id == wall_id) {
                return wall;
            }
        }
        return null;
    }

    /// If the given ray hits the level grid, return the position on the floor.
    pub fn cast3DRayToGround(self: Collection, ray: rl.Ray) ?util.FlatVector {
        return self.floor.cast3DRay(ray);
    }

    const RayWallCollision = struct {
        wall_id: u64,
        distance: f32,
    };

    /// Find the id of the closest wall hit by the given ray, if available.
    pub fn cast3DRayToWalls(self: Collection, ray: rl.Ray) ?RayWallCollision {
        var result: ?RayWallCollision = null;
        for (self.walls.items) |wall| {
            const ray_collision = rl.GetRayCollisionMesh(ray, wall.mesh, wall.precomputed_matrix);
            const found_closer_wall = if (!ray_collision.hit)
                false
            else if (result) |existing_result|
                ray_collision.distance < existing_result.distance
            else
                true;
            if (found_closer_wall) {
                result = RayWallCollision{ .wall_id = wall.id, .distance = ray_collision.distance };
            }
        }
        return result;
    }

    /// If a collision occurs, return a displacement vector for moving the given circle out of the
    /// level geometry. The returned displacement vector must be added to the given circles position
    /// to resolve the collision.
    pub fn collidesWithCircle(self: Collection, circle: collision.Circle) ?util.FlatVector {
        var found_collision = false;
        var displaced_circle = circle;

        // Move displaced_circle out of all walls.
        for (self.walls.items) |wall| {
            if (displaced_circle.collidesWithRectangle(wall.boundaries)) |displacement_vector| {
                found_collision = true;
                displaced_circle.position = displaced_circle.position.add(displacement_vector);
            }
        }

        return if (found_collision)
            displaced_circle.position.subtract(circle.position)
        else
            null;
    }
};
