const animation = @import("animation.zig");
const collision = @import("collision.zig");
const std = @import("std");
const util = @import("util.zig");
const textures = @import("textures.zig");
const gl = @import("gl");
const Error = @import("error.zig").Error;
const rendering = @import("rendering.zig");
const meshes = @import("meshes.zig");
const math = @import("math.zig");
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;

pub const LevelGeometry = struct {
    /// Gives every object owned by this struct a unique id.
    object_id_counter: u64,

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
    billboard_renderer: rendering.BillboardRenderer,
    billboards_have_changed: bool,

    /// Stores the given allocator internally for its entire lifetime.
    pub fn create(allocator: std.mem.Allocator) !LevelGeometry {
        var wall_renderer = try rendering.WallRenderer.create();
        errdefer wall_renderer.destroy();
        var floor_renderer = try rendering.FloorRenderer.create();
        errdefer floor_renderer.destroy();
        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        return LevelGeometry{
            .object_id_counter = 0,
            .walls = std.ArrayList(Wall).init(allocator),
            .wall_renderer = wall_renderer,
            .walls_have_changed = false,
            .floors = std.ArrayList(Floor).init(allocator),
            .floor_animation_state = animation.FourStepCycle.create(),
            .floor_renderer = floor_renderer,
            .floors_have_changed = false,
            .billboard_objects = std.ArrayList(BillboardObject).init(allocator),
            .billboard_renderer = billboard_renderer,
            .billboards_have_changed = false,
        };
    }

    pub fn destroy(self: *LevelGeometry) void {
        self.billboard_renderer.destroy();
        self.billboard_objects.deinit();

        self.floor_renderer.destroy();
        self.floors.deinit();

        self.wall_renderer.destroy();
        self.walls.deinit();
    }

    /// Stores the given allocator internally for its entire lifetime.
    pub fn createFromJson(allocator: std.mem.Allocator, json: []const u8) !LevelGeometry {
        var geometry = try create(allocator);
        errdefer geometry.destroy();

        var token_stream = std.json.TokenStream.init(json);
        const options = .{ .allocator = allocator };
        const tree = try std.json.parse(Json.SerializableData, &token_stream, options);
        defer std.json.parseFree(Json.SerializableData, tree, options);

        for (tree.walls) |wall| {
            const wall_type = std.meta.stringToEnum(WallType, wall.t) orelse {
                return Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addWall(wall.start, wall.end, wall_type);
        }
        for (tree.floors) |floor| {
            const floor_type = std.meta.stringToEnum(FloorType, floor.t) orelse {
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
            const object_type = std.meta.stringToEnum(BillboardObjectType, billboard.t) orelse {
                return Error.FailedToDeserializeLevelGeometry;
            };
            _ = try geometry.addBillboardObject(object_type, billboard.pos);
        }

        return geometry;
    }

    pub fn prepareRender(
        self: *LevelGeometry,
        allocator: std.mem.Allocator,
        sprite_sheet_texture: textures.SpriteSheetTexture,
    ) !void {
        if (self.walls_have_changed) {
            try self.uploadWallsToRenderer(allocator);
            self.walls_have_changed = false;
        }
        if (self.floors_have_changed) {
            try self.uploadFloorsToRenderer(allocator);
            self.floors_have_changed = false;
        }
        if (self.billboards_have_changed) {
            try self.uploadBillboardsToRenderer(allocator, sprite_sheet_texture);
            self.billboards_have_changed = false;
        }
    }

    pub fn render(
        self: LevelGeometry,
        vp_matrix: math.Matrix,
        camera_direction_to_target: math.Vector3d,
        tileable_textures: textures.TileableArrayTexture,
        sprite_sheet_texture: textures.SpriteSheetTexture,
    ) void {
        // Prevent floors from overpainting each other.
        gl.stencilFunc(gl.NOTEQUAL, 1, 0xff);
        self.floor_renderer.render(vp_matrix, tileable_textures.id, self.floor_animation_state);
        gl.stencilFunc(gl.ALWAYS, 1, 0xff);

        // Fences must be rendered after the floor to allow blending transparent, mipmapped texels.
        self.wall_renderer.render(vp_matrix, tileable_textures.id);
        self.billboard_renderer.render(
            vp_matrix,
            camera_direction_to_target,
            sprite_sheet_texture.id,
        );
    }

    pub fn processElapsedTick(self: *LevelGeometry) void {
        self.floor_animation_state.processElapsedTick(0.02);
    }

    pub fn writeAsJson(self: LevelGeometry, allocator: std.mem.Allocator, outstream: anytype) !void {
        var walls = try allocator.alloc(Json.Wall, self.walls.items.len);
        defer allocator.free(walls);
        for (self.walls.items) |wall, index| {
            walls[index] = .{
                .t = @tagName(wall.wall_type),
                .start = wall.start_position,
                .end = wall.end_position,
            };
        }

        var floors = try allocator.alloc(Json.Floor, self.floors.items.len);
        defer allocator.free(floors);
        for (self.floors.items) |floor, index| {
            floors[index] = .{
                .t = @tagName(floor.floor_type),
                .side_a_start = floor.side_a_start,
                .side_a_end = floor.side_a_end,
                .side_b_length = floor.side_b_length,
            };
        }

        var billboards = try allocator.alloc(Json.BillboardObject, self.billboard_objects.items.len);
        defer allocator.free(billboards);
        for (self.billboard_objects.items) |billboard, index| {
            billboards[index] = .{
                .t = @tagName(billboard.object_type),
                .pos = billboard.boundaries.position,
            };
        }

        const data = Json.SerializableData{
            .walls = walls,
            .floors = floors,
            .billboard_objects = billboards,
        };
        try std.json.stringify(data, .{
            .whitespace = .{ .indent = .{ .Space = 0 }, .separator = false },
        }, outstream);
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
        start_position: math.FlatVector,
        end_position: math.FlatVector,
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
        start_position: math.FlatVector,
        end_position: math.FlatVector,
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
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
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
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
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
        position: math.FlatVector,
    ) !u64 {
        const billboard = try self.billboard_objects.addOne();
        billboard.* = BillboardObject.create(self.object_id_counter, object_type, position);
        self.object_id_counter = self.object_id_counter + 1;
        self.billboards_have_changed = true;
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
                self.billboards_have_changed = true;
                return;
            }
        }
    }

    pub fn tintObject(self: *LevelGeometry, object_id: u64, tint: util.Color) void {
        if (self.findWall(object_id)) |wall| {
            wall.tint = tint;
            self.walls_have_changed = true;
        } else if (self.findFloor(object_id)) |floor| {
            floor.tint = tint;
            self.floors_have_changed = true;
        } else if (self.findBillboardObject(object_id)) |billboard| {
            billboard.tint = tint;
            self.billboards_have_changed = true;
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
            self.billboards_have_changed = true;
        }
    }

    pub const RayCollision = struct {
        object_id: u64,
        impact_point: collision.Ray3d.ImpactPoint,
    };

    /// Find the id of the closest wall hit by the given ray, if available.
    pub fn cast3DRayToWalls(
        self: LevelGeometry,
        ray: collision.Ray3d,
        ignore_fences: bool,
    ) ?RayCollision {
        var result: ?RayCollision = null;
        for (self.walls.items) |wall| {
            if (ignore_fences and Wall.isFence(wall.wall_type)) {
                continue;
            }
            const impact_point = wall.collidesWithRay(ray);
            result = getCloserRayCollision(impact_point, wall.object_id, result);
        }
        return result;
    }

    /// Find the id of the closest object hit by the given ray, if available.
    pub fn cast3DRayToObjects(self: LevelGeometry, ray: collision.Ray3d) ?RayCollision {
        var result = self.cast3DRayToWalls(ray, false);
        for (self.billboard_objects.items) |billboard| {
            result = getCloserRayCollision(billboard.cast3DRay(ray), billboard.object_id, result);
        }

        // Walls and billboards are covering floors and are prioritized.
        if (result != null) {
            return result;
        }

        if (ray.collidesWithGround()) |impact_point| {
            for (self.floors.items) |_, index| {
                // The last floor in this array is always drawn at the top.
                const floor = self.floors.items[self.floors.items.len - index - 1];
                if (floor.boundaries.collidesWithPoint(impact_point.position.toFlatVector())) {
                    return RayCollision{
                        .object_id = floor.object_id,
                        .impact_point = impact_point,
                    };
                }
            }
        }
        return null;
    }

    /// If a collision occurs, return a displacement vector for moving the given circle out of the
    /// level geometry. The returned displacement vector must be added to the given circles position
    /// to resolve the collision.
    pub fn collidesWithCircle(self: LevelGeometry, circle: collision.Circle) ?math.FlatVector {
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

    /// Check if two points are separated by a solid wall. Fences are not solid.
    pub fn isSolidWallBetweenPoints(self: LevelGeometry, points: [2]math.FlatVector) bool {
        for (self.walls.items) |wall| {
            if (!Wall.isFence(wall.wall_type) and
                wall.boundaries.collidesWithLine(points[0], points[1]))
            {
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

    fn getCloserRayCollision(
        impact_point: ?collision.Ray3d.ImpactPoint,
        object_id: u64,
        current_collision: ?RayCollision,
    ) ?RayCollision {
        if (impact_point) |point| {
            if (current_collision) |current| {
                if (point.distance_from_start_position <
                    current.impact_point.distance_from_start_position)
                {
                    return RayCollision{ .object_id = object_id, .impact_point = point };
                }
            } else {
                return RayCollision{ .object_id = object_id, .impact_point = point };
            }
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
                .properties = makeRenderingAttributes(
                    wall.model_matrix,
                    wall.getTextureLayerId(),
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
                .properties = makeRenderingAttributes(
                    floor.model_matrix,
                    floor.getTextureLayerId(),
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

    fn uploadBillboardsToRenderer(
        self: *LevelGeometry,
        allocator: std.mem.Allocator,
        sprite_sheet_texture: textures.SpriteSheetTexture,
    ) !void {
        var data = try allocator.alloc(
            rendering.BillboardRenderer.BillboardData,
            self.billboard_objects.items.len,
        );
        defer allocator.free(data);

        for (self.billboard_objects.items) |billboard, index| {
            data[index] = billboard.getBillboardData(sprite_sheet_texture);
        }
        self.billboard_renderer.uploadBillboards(data);
    }

    fn makeRenderingAttributes(
        model_matrix: math.Matrix,
        layer_id: textures.TileableArrayTexture.LayerId,
        tint: util.Color,
    ) rendering.LevelGeometryAttributes {
        return .{
            .model_matrix = model_matrix.toFloatArray(),
            .texture_layer_id = @intToFloat(f32, @enumToInt(layer_id)),
            .tint = .{ .r = tint.r, .g = tint.g, .b = tint.b },
        };
    }
};

const Floor = struct {
    object_id: u64,
    floor_type: LevelGeometry.FloorType,
    model_matrix: math.Matrix,
    boundaries: collision.Rectangle,
    tint: util.Color,

    /// Values used to generate this floor.
    side_a_start: math.FlatVector,
    side_a_end: math.FlatVector,
    side_b_length: f32,

    /// Side a and b can be chosen arbitrarily, but must be adjacent.
    fn create(
        object_id: u64,
        floor_type: LevelGeometry.FloorType,
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
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
            .model_matrix = math.Matrix.identity
                .rotate(math.Vector3d.x_axis, math.degreesToRadians(-90))
                .scale(.{ .x = side_b_length, .y = 1, .z = side_a_length })
                .rotate(math.Vector3d.y_axis, -rotation)
                .translate(center.toVector3d()),
            .boundaries = collision.Rectangle.create(side_a_start, side_a_end, side_b_length),
            .tint = getDefaultTint(floor_type),
            .side_a_start = side_a_start,
            .side_a_end = side_a_end,
            .side_b_length = side_b_length,
        };
    }

    fn getTextureScale(self: Floor) f32 {
        return switch (self.floor_type) {
            else => 5.0,
            .grass => 2.0,
            .water => 3.0,
        };
    }

    fn getDefaultTint(floor_type: LevelGeometry.FloorType) util.Color {
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
    wall_type: LevelGeometry.WallType,
    model_matrix: math.Matrix,
    boundaries: collision.Rectangle,
    tint: util.Color,

    /// Values used to generate this wall.
    start_position: math.FlatVector,
    end_position: math.FlatVector,

    fn create(
        object_id: u64,
        wall_type: LevelGeometry.WallType,
        start_position: math.FlatVector,
        end_position: math.FlatVector,
    ) Wall {
        const wall_type_properties = getWallTypeProperties(start_position, end_position, wall_type);
        const offset = wall_type_properties.corrected_end_position.subtract(
            wall_type_properties.corrected_start_position,
        );
        const length = offset.length();
        const x_axis = math.FlatVector{ .x = 1, .z = 0 };
        const rotation_angle = x_axis.computeRotationToOtherVector(offset);
        const height = wall_type_properties.height;
        const thickness = wall_type_properties.thickness;

        // Fences are flat, thickness is only for collision.
        const render_thickness = if (isFence(wall_type)) 0 else thickness;

        const side_a_up_offset =
            math.FlatVector.normalize(.{ .x = offset.z, .z = -offset.x }).scale(thickness / 2);
        const center = wall_type_properties.corrected_start_position.add(offset.scale(0.5));
        return Wall{
            .object_id = object_id,
            .model_matrix = math.Matrix.identity
                .scale(.{ .x = length, .y = height, .z = render_thickness })
                .rotate(math.Vector3d.y_axis, rotation_angle)
                .translate(center.toVector3d().add(math.Vector3d.y_axis.scale(height / 2))),
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

    fn collidesWithRay(
        self: Wall,
        ray: collision.Ray3d,
    ) ?collision.Ray3d.ImpactPoint {
        const bottom_corners_2d = self.boundaries.getCornersInGameCoordinates();
        const bottom_corners = [_]math.Vector3d{
            bottom_corners_2d[0].toVector3d(),
            bottom_corners_2d[1].toVector3d(),
            bottom_corners_2d[2].toVector3d(),
            bottom_corners_2d[3].toVector3d(),
        };
        const vertical_offset = math.Vector3d.y_axis.scale(getWallTypeHeight(self.wall_type));
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
        if (ray.collidesWithQuad(quad)) |current_impact_point| {
            if (closest_impact_point.*) |previous_impact_point| {
                if (current_impact_point.distance_from_start_position <
                    previous_impact_point.distance_from_start_position)
                {
                    closest_impact_point.* = current_impact_point;
                }
            } else {
                closest_impact_point.* = current_impact_point;
            }
        }
    }

    const WallTypeProperties = struct {
        corrected_start_position: math.FlatVector,
        corrected_end_position: math.FlatVector,
        height: f32,
        thickness: f32,
        texture_scale: f32,
    };

    fn getWallTypeProperties(
        start_position: math.FlatVector,
        end_position: math.FlatVector,
        wall_type: LevelGeometry.WallType,
    ) WallTypeProperties {
        const fence_thickness = 0.25; // Only needed for collision boundaries, fences are flat.
        var properties = WallTypeProperties{
            .corrected_start_position = start_position,
            .corrected_end_position = end_position,
            .height = getWallTypeHeight(wall_type),
            .thickness = fence_thickness,
            .texture_scale = 1.0,
        };
        switch (wall_type) {
            .small_wall => {
                properties.texture_scale = 5.0;
            },
            .medium_wall => {
                properties.thickness = 1;
                properties.texture_scale = 5.0;
            },
            .castle_wall => {
                properties.thickness = 2;
                properties.texture_scale = 7.5;
            },
            .castle_tower => {
                // Towers are centered around their start position.
                const half_side_length = 3;
                const rescaled_offset =
                    end_position.subtract(start_position).normalize().scale(half_side_length);
                properties.corrected_start_position = start_position.subtract(rescaled_offset);
                properties.corrected_end_position = start_position.add(rescaled_offset);
                properties.thickness = half_side_length * 2;
                properties.texture_scale = 9;
            },
            .metal_fence => {
                properties.texture_scale = 3.5;
            },
            .short_metal_fence => {
                properties.texture_scale = 1.5;
            },
            .tall_hedge => {
                properties.thickness = 3;
                properties.texture_scale = 3.5;
            },
            .giga_wall => {
                properties.thickness = 6;
                properties.texture_scale = 16.0;
            },
        }
        return properties;
    }

    fn getWallTypeHeight(wall_type: LevelGeometry.WallType) f32 {
        return switch (wall_type) {
            .small_wall => 5.0,
            .medium_wall => 10.0,
            .castle_wall => 15.0,
            .castle_tower => 18.0,
            .metal_fence => 3.5,
            .short_metal_fence => 1.0,
            .tall_hedge => 8.0,
            .giga_wall => 140.0,
        };
    }

    fn isFence(wall_type: LevelGeometry.WallType) bool {
        return switch (wall_type) {
            else => false,
            .metal_fence, .short_metal_fence => true,
        };
    }

    fn getDefaultTint(wall_type: LevelGeometry.WallType) util.Color {
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
};

const BillboardObject = struct {
    object_id: u64,
    object_type: LevelGeometry.BillboardObjectType,
    boundaries: collision.Circle,
    tint: util.Color,

    fn create(
        object_id: u64,
        object_type: LevelGeometry.BillboardObjectType,
        position: math.FlatVector,
    ) BillboardObject {
        const width: f32 = switch (object_type) {
            else => 1.0,
        };
        return .{
            .object_id = object_id,
            .object_type = object_type,
            .boundaries = .{ .position = position, .radius = width / 2 },
            .tint = getDefaultTint(object_type),
        };
    }

    fn cast3DRay(self: BillboardObject, ray: collision.Ray3d) ?collision.Ray3d.ImpactPoint {
        const offset_to_top = math.Vector3d.y_axis.scale(self.boundaries.radius * 2);
        const offset_to_right = ray.direction.toFlatVector().normalize().rotateRightBy90Degrees()
            .scale(self.boundaries.radius).toVector3d();
        return ray.collidesWithQuad(.{
            self.boundaries.position.toVector3d().subtract(offset_to_right),
            self.boundaries.position.toVector3d().add(offset_to_right),
            self.boundaries.position.toVector3d().add(offset_to_right).add(offset_to_top),
            self.boundaries.position.toVector3d().subtract(offset_to_right).add(offset_to_top),
        });
    }

    fn getBillboardData(
        self: BillboardObject,
        sprite_sheet_texture: textures.SpriteSheetTexture,
    ) rendering.BillboardRenderer.BillboardData {
        const sprite_id: textures.SpriteSheetTexture.SpriteId = switch (self.object_type) {
            .small_bush => .small_bush,
        };
        const source = sprite_sheet_texture.texcoords.get(sprite_id);
        const half_height = self.boundaries.radius * sprite_sheet_texture.aspect_ratios.get(sprite_id);
        return .{
            .position = .{
                .x = self.boundaries.position.x,
                .y = half_height,
                .z = self.boundaries.position.z,
            },
            .size = .{
                .w = self.boundaries.radius * 2,
                .h = half_height * 2,
            },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
            .tint = .{ .r = self.tint.r, .g = self.tint.g, .b = self.tint.b },
        };
    }

    fn getDefaultTint(object_type: LevelGeometry.BillboardObjectType) util.Color {
        return switch (object_type) {
            else => util.Color.white,
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
        /// Type enum as string.
        t: []const u8,
        start: math.FlatVector,
        end: math.FlatVector,
    };

    const Floor = struct {
        /// Type enum as string.
        t: []const u8,
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
        side_b_length: f32,
    };

    const BillboardObject = struct {
        /// Type enum as string.
        t: []const u8,
        pos: math.FlatVector,
    };
};
