const rl = @import("raylib");
const util = @import("util.zig");
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const bufPrintZ = @import("std").fmt.bufPrintZ;

pub const State = struct {
    mode: Mode,
    object_type_to_insert: ObjectTypeToInsert,
    currently_edited_object: ?CurrentlyEditedObject,

    pub fn create() State {
        return State{
            .mode = Mode.insert_objects,
            .object_type_to_insert = .{
                .used_field = @intToEnum(ObjectTypeToInsert.UsedField, 0),
                .wall = @intToEnum(LevelGeometry.WallType, 0),
                .floor = @intToEnum(LevelGeometry.FloorType, 0),
            },
            .currently_edited_object = null,
        };
    }

    pub fn startActionAtTarget(self: *State, level_geometry: *LevelGeometry, mouse_ray: rl.Ray) !void {
        self.resetCurrentlyEditedObject(level_geometry);
        switch (self.mode) {
            .insert_objects => {
                if (level_geometry.cast3DRayToGround(mouse_ray)) |ground_position| {
                    try self.startPlacingObject(level_geometry, ground_position);
                }
            },
            .delete_objects => {
                if (level_geometry.cast3DRayToWalls(mouse_ray)) |ray_collision| {
                    level_geometry.removeObject(ray_collision.object_id);
                }
            },
        }
    }

    pub fn updateCurrentActionTarget(
        self: *State,
        level_geometry: *LevelGeometry,
        mouse_ray: rl.Ray,
    ) void {
        switch (self.mode) {
            .insert_objects => {
                if (level_geometry.cast3DRayToGround(mouse_ray)) |ground_position| {
                    self.updateCurrentlyInsertedObject(level_geometry, ground_position);
                }
            },
            .delete_objects => {
                self.resetCurrentlyEditedObject(level_geometry);
                if (level_geometry.cast3DRayToWalls(mouse_ray)) |ray_collision| {
                    level_geometry.tintObject(ray_collision.object_id, rl.RED);
                    self.currently_edited_object = CurrentlyEditedObject{
                        .object_id = ray_collision.object_id,
                        .start_position = undefined,
                    };
                }
            },
        }
    }

    pub fn completeCurrentAction(self: *State, level_geometry: *LevelGeometry) void {
        if (self.mode != .insert_objects) {
            return;
        }
        self.resetCurrentlyEditedObject(level_geometry);
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
        }
    }

    // Cycles between subtypes of objects to insert, e.g. small wall, large wall.
    pub fn cycleInsertedObjectSubtypeBackwards(self: *State) void {
        const object_type = &self.object_type_to_insert;
        switch (object_type.used_field) {
            .wall => object_type.wall = util.getPreviousEnumWrapAround(object_type.wall),
            .floor => object_type.floor = util.getPreviousEnumWrapAround(object_type.floor),
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
                };
                return bufPrintZ(string_buffer, "inserting {s} of type {s}", .{
                    @tagName(self.object_type_to_insert.used_field),
                    enum_string,
                });
            },
            .delete_objects => return bufPrintZ(string_buffer, "delete mode", .{}),
        }
    }

    const Mode = enum { insert_objects, delete_objects };
    const ObjectTypeToInsert = struct {
        /// Only one field is being used, but the other needs to preserve its state.
        used_field: UsedField,
        wall: LevelGeometry.WallType,
        floor: LevelGeometry.FloorType,

        const UsedField = enum { wall, floor };
    };

    const CurrentlyEditedObject = struct {
        object_id: u64,
        start_position: util.FlatVector,
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
        position: util.FlatVector,
    ) !void {
        const object_type = &self.object_type_to_insert;
        const object_id = switch (object_type.used_field) {
            .wall => try level_geometry.addWall(position, position, object_type.wall),
            .floor => @as(u64, 0),
        };
        level_geometry.tintObject(object_id, rl.GREEN);
        self.currently_edited_object =
            CurrentlyEditedObject{ .object_id = object_id, .start_position = position };
    }

    fn updateCurrentlyInsertedObject(
        self: *State,
        level_geometry: *LevelGeometry,
        position: util.FlatVector,
    ) void {
        if (self.currently_edited_object) |object| {
            switch (self.object_type_to_insert.used_field) {
                .wall => {
                    level_geometry.updateWall(object.object_id, object.start_position, position);
                },
                .floor => {},
            }
        }
    }
};
