const Map = @import("map/map.zig").Map;
const MapGeometry = @import("map/geometry.zig").Geometry;
const collision = @import("collision.zig");
const math = @import("math.zig");
const std = @import("std");
const util = @import("util.zig");

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
        object_id_generator: *util.ObjectIdGenerator,
        map: *Map,
        mouse_ray: collision.Ray3d,
    ) !void {
        switch (self.mode) {
            .insert_objects => {
                if (self.currently_edited_object != null) {
                    self.resetCurrentlyEditedObject(map);
                } else if (cast3DRayToGround(mouse_ray)) |ground_position| {
                    try self.startPlacingObject(object_id_generator, map, ground_position);
                }
            },
            .delete_objects => {
                self.resetCurrentlyEditedObject(map);
                if (cast3DRayToObjects(mouse_ray, map.*)) |ray_collision| {
                    map.geometry.removeObject(ray_collision.object_id);
                }
            },
        }
    }

    pub fn updateCurrentActionTarget(
        self: *State,
        map: *Map,
        mouse_ray: collision.Ray3d,
        camera_direction: math.FlatVector,
    ) !void {
        switch (self.mode) {
            .insert_objects => {
                if (cast3DRayToGround(mouse_ray)) |ground_position| {
                    try self.updateCurrentlyInsertedObject(map, ground_position, camera_direction);
                }
            },
            .delete_objects => {
                self.resetCurrentlyEditedObject(map);
                if (cast3DRayToObjects(mouse_ray, map.*)) |ray_collision| {
                    map.geometry.tintObject(ray_collision.object_id, .{ .r = 1, .g = 0, .b = 0 });
                    self.currently_edited_object = CurrentlyEditedObject{
                        .object_id = ray_collision.object_id,
                        .start_position = undefined,
                    };
                }
            },
        }
    }

    // Cycles between the states various edit modes, e.g. insert, delete.
    pub fn cycleMode(self: *State, map: *Map) void {
        self.resetCurrentlyEditedObject(map);
        self.mode = util.getNextEnumWrapAround(self.mode);
    }

    // Cycles between the types of objects to insert, e.g. walls, floors.
    pub fn cycleInsertedObjectType(self: *State, map: *Map) void {
        self.resetCurrentlyEditedObject(map);
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

    /// Returns two slices slice describing:
    ///   1. Current edit mode state
    ///   2. Currently selected object (can be an empty string)
    /// Fails if the given buffer is too small.
    pub fn describe(self: State, string_buffer: []u8) ![2][]const u8 {
        switch (self.mode) {
            .insert_objects => {
                const enum_string = switch (self.object_type_to_insert.used_field) {
                    .wall => @tagName(self.object_type_to_insert.wall),
                    .floor => @tagName(self.object_type_to_insert.floor),
                    .billboard => @tagName(self.object_type_to_insert.billboard),
                };

                return .{
                    "Insert Mode",
                    try std.fmt.bufPrint(string_buffer, "{s}: {s}", .{
                        @tagName(self.object_type_to_insert.used_field),
                        enum_string,
                    }),
                };
            },
            .delete_objects => return .{ "Delete Mode", "" },
        }
    }

    const Mode = enum { insert_objects, delete_objects };
    const ObjectTypeToInsert = struct {
        /// Only one field is being used, but the other needs to preserve its state.
        used_field: UsedField,
        wall: MapGeometry.WallType,
        floor: MapGeometry.FloorType,
        billboard: MapGeometry.BillboardObjectType,

        const UsedField = enum { wall, floor, billboard };
    };

    const CurrentlyEditedObject = struct {
        object_id: u64,
        start_position: math.FlatVector,
    };

    fn resetCurrentlyEditedObject(self: *State, map: *Map) void {
        if (self.currently_edited_object) |object| {
            map.geometry.untintObject(object.object_id);
        }
        self.currently_edited_object = null;
    }

    fn startPlacingObject(
        self: *State,
        object_id_generator: *util.ObjectIdGenerator,
        map: *Map,
        position: math.FlatVector,
    ) !void {
        const object_type = &self.object_type_to_insert;
        const object_id = try switch (object_type.used_field) {
            .wall => map.geometry.addWall(
                object_id_generator,
                position,
                position,
                object_type.wall,
            ),
            .floor => map.geometry.addFloor(
                object_id_generator,
                position,
                position,
                0,
                object_type.floor,
            ),
            .billboard => map.geometry.addBillboardObject(
                object_id_generator,
                object_type.billboard,
                position,
            ),
        };
        if (object_type.used_field != .billboard) {
            map.geometry.tintObject(object_id, .{ .r = 0, .g = 1, .b = 0 });
            self.currently_edited_object =
                CurrentlyEditedObject{ .object_id = object_id, .start_position = position };
        }
    }

    fn updateCurrentlyInsertedObject(
        self: *State,
        map: *Map,
        object_end_position: math.FlatVector,
        camera_direction: math.FlatVector,
    ) !void {
        if (self.currently_edited_object) |object| {
            switch (self.object_type_to_insert.used_field) {
                .wall => {
                    try map.geometry
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

                    map.geometry.updateFloor(
                        object.object_id,
                        side_a_start,
                        side_a_end,
                        side_b_length,
                    );
                },
                .billboard => {},
            }
        }
    }
};

/// Reasonable distance to prevent placing/modifying objects too far away from the camera.
const max_raycast_distance = 500;

fn cast3DRayToGround(ray: collision.Ray3d) ?math.FlatVector {
    if (ray.collidesWithGround()) |impact_point| {
        if (impact_point.distance_from_start_position < max_raycast_distance) {
            return impact_point.position.toFlatVector();
        }
    }
    return null;
}

fn cast3DRayToObjects(ray: collision.Ray3d, map: Map) ?MapGeometry.RayCollision {
    if (map.geometry.cast3DRayToObjects(ray)) |ray_collision| {
        if (ray_collision.impact_point.distance_from_start_position < max_raycast_distance) {
            return ray_collision;
        }
    }
    return null;
}
