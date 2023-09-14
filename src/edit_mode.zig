const util = @import("util.zig");
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const std = @import("std");
const math = @import("math.zig");
const collision = @import("collision.zig");

pub const State = struct {
    mode: Mode,
    object_type_to_insert: ObjectTypeToInsert,
    currently_edited_object: ?CurrentlyEditedObject,

    pub fn create() State {
        return State{
            .mode = Mode.insert_objects,
            .object_type_to_insert = .{
                .used_field = @enumFromInt(0),
                .wall = @enumFromInt(0),
                .floor = @enumFromInt(0),
                .billboard = @enumFromInt(0),
            },
            .currently_edited_object = null,
        };
    }

    pub fn handleActionAtTarget(
        self: *State,
        level_geometry: *LevelGeometry,
        mouse_ray: collision.Ray3d,
    ) !void {
        switch (self.mode) {
            .insert_objects => {
                if (self.currently_edited_object != null) {
                    self.resetCurrentlyEditedObject(level_geometry);
                } else if (cast3DRayToGround(mouse_ray)) |ground_position| {
                    try self.startPlacingObject(level_geometry, ground_position);
                }
            },
            .delete_objects => {
                self.resetCurrentlyEditedObject(level_geometry);
                if (cast3DRayToObjects(mouse_ray, level_geometry.*)) |ray_collision| {
                    level_geometry.removeObject(ray_collision.object_id);
                }
            },
        }
    }

    pub fn updateCurrentActionTarget(
        self: *State,
        level_geometry: *LevelGeometry,
        mouse_ray: collision.Ray3d,
        camera_direction: math.FlatVector,
    ) void {
        switch (self.mode) {
            .insert_objects => {
                if (cast3DRayToGround(mouse_ray)) |ground_position| {
                    self.updateCurrentlyInsertedObject(level_geometry, ground_position, camera_direction);
                }
            },
            .delete_objects => {
                self.resetCurrentlyEditedObject(level_geometry);
                if (cast3DRayToObjects(mouse_ray, level_geometry.*)) |ray_collision| {
                    level_geometry.tintObject(ray_collision.object_id, .{ .r = 1, .g = 0, .b = 0 });
                    self.currently_edited_object = CurrentlyEditedObject{
                        .object_id = ray_collision.object_id,
                        .start_position = undefined,
                    };
                }
            },
        }
    }

    // Cycles between the states various edit modes, e.g. insert, delete.
    pub fn cycleMode(self: *State, level_geometry: *LevelGeometry) void {
        self.resetCurrentlyEditedObject(level_geometry);
        self.mode = util.getNextEnumWrapAround(self.mode);
    }

    // Cycles between the types of objects to insert, e.g. walls, floors.
    pub fn cycleInsertedObjectType(self: *State, level_geometry: *LevelGeometry) void {
        self.resetCurrentlyEditedObject(level_geometry);
        self.object_type_to_insert.used_field =
            util.getNextEnumWrapAround(self.object_type_to_insert.used_field);
    }

    // Cycles between subtypes of objects to insert, e.g. small wall, large wall.
    pub fn cycleInsertedObjectSubtypeForwards(self: *State) void {
        const object_type = &self.object_type_to_insert;
        switch (object_type.used_field) {
            .wall => object_type.wall = util.getNextEnumWrapAround(object_type.wall),
            .floor => object_type.floor = util.getNextEnumWrapAround(object_type.floor),
            .billboard => object_type.billboard = util.getNextEnumWrapAround(object_type.billboard),
        }
    }

    // Cycles between subtypes of objects to insert, e.g. small wall, large wall.
    pub fn cycleInsertedObjectSubtypeBackwards(self: *State) void {
        const object_type = &self.object_type_to_insert;
        switch (object_type.used_field) {
            .wall => object_type.wall = util.getPreviousEnumWrapAround(object_type.wall),
            .floor => object_type.floor = util.getPreviousEnumWrapAround(object_type.floor),
            .billboard => object_type.billboard = util
                .getPreviousEnumWrapAround(object_type.billboard),
        }
    }

    /// Returns a slice describing the current edit mode state. Fails if the given buffer is too
    /// small.
    pub fn describe(self: State, string_buffer: []u8) ![:0]u8 {
        switch (self.mode) {
            .insert_objects => {
                const enum_string = switch (self.object_type_to_insert.used_field) {
                    .wall => @tagName(self.object_type_to_insert.wall),
                    .floor => @tagName(self.object_type_to_insert.floor),
                    .billboard => @tagName(self.object_type_to_insert.billboard),
                };

                return std.fmt.bufPrintZ(string_buffer, "inserting {s} of type {s}", .{
                    @tagName(self.object_type_to_insert.used_field),
                    enum_string,
                });
            },
            .delete_objects => return std.fmt.bufPrintZ(string_buffer, "delete mode", .{}),
        }
    }

    const Mode = enum { insert_objects, delete_objects };
    const ObjectTypeToInsert = struct {
        /// Only one field is being used, but the other needs to preserve its state.
        used_field: UsedField,
        wall: LevelGeometry.WallType,
        floor: LevelGeometry.FloorType,
        billboard: LevelGeometry.BillboardObjectType,

        const UsedField = enum { wall, floor, billboard };
    };

    const CurrentlyEditedObject = struct {
        object_id: u64,
        start_position: math.FlatVector,
    };

    fn resetCurrentlyEditedObject(self: *State, level_geometry: *LevelGeometry) void {
        if (self.currently_edited_object) |object| {
            level_geometry.untintObject(object.object_id);
        }
        self.currently_edited_object = null;
    }

    fn startPlacingObject(
        self: *State,
        level_geometry: *LevelGeometry,
        position: math.FlatVector,
    ) !void {
        const object_type = &self.object_type_to_insert;
        const object_id = try switch (object_type.used_field) {
            .wall => level_geometry.addWall(position, position, object_type.wall),
            .floor => level_geometry.addFloor(position, position, 0, object_type.floor),
            .billboard => level_geometry.addBillboardObject(object_type.billboard, position),
        };
        if (object_type.used_field != .billboard) {
            level_geometry.tintObject(object_id, .{ .r = 0, .g = 1, .b = 0 });
            self.currently_edited_object =
                CurrentlyEditedObject{ .object_id = object_id, .start_position = position };
        }
    }

    fn updateCurrentlyInsertedObject(
        self: *State,
        level_geometry: *LevelGeometry,
        object_end_position: math.FlatVector,
        camera_direction: math.FlatVector,
    ) void {
        if (self.currently_edited_object) |object| {
            switch (self.object_type_to_insert.used_field) {
                .wall => {
                    level_geometry
                        .updateWall(object.object_id, object.start_position, object_end_position);
                },
                .floor => {
                    const offset = object_end_position.subtract(object.start_position);
                    const camera_right_axis = camera_direction.rotateRightBy90Degrees();
                    const side_a_length = offset.projectOnto(camera_direction).length();
                    const side_a_offset = camera_direction.normalize().scale(side_a_length);
                    const side_b_length = offset.projectOnto(camera_right_axis).length();

                    var side_a_start = object.start_position;
                    var side_a_end = side_a_start.add(side_a_offset);
                    if (camera_direction.dotProduct(offset) < 0) {
                        side_a_start = object.start_position.subtract(side_a_offset);
                        side_a_end = object.start_position;
                    }
                    if (camera_right_axis.dotProduct(offset) > 0) {
                        std.mem.swap(math.FlatVector, &side_a_start, &side_a_end);
                    }

                    level_geometry.updateFloor(object.object_id, side_a_start, side_a_end, side_b_length);
                },
                .billboard => {},
            }
        }
    }
};

/// Reasonable distance to prevent placing/modifying objects too far away from the camera.
const max_raycast_distance = 1500;

fn cast3DRayToGround(ray: collision.Ray3d) ?math.FlatVector {
    if (ray.collidesWithGround()) |impact_point| {
        if (impact_point.distance_from_start_position < max_raycast_distance) {
            return impact_point.position.toFlatVector();
        }
    }
    return null;
}

fn cast3DRayToObjects(
    ray: collision.Ray3d,
    level_geometry: LevelGeometry,
) ?LevelGeometry.RayCollision {
    if (level_geometry.cast3DRayToObjects(ray)) |ray_collision| {
        if (ray_collision.impact_point.distance_from_start_position < max_raycast_distance) {
            return ray_collision;
        }
    }
    return null;
}
