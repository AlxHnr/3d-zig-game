//! Contains various helpers that belong nowhere else.

const std = @import("std");
const math = @import("math.zig");

/// Generates unique ids for distinguishing all objects in the game.
pub const ObjectIdGenerator = struct {
    id_counter: u64,

    pub fn create() ObjectIdGenerator {
        return .{ .id_counter = 0 };
    }

    pub fn makeNewId(self: *ObjectIdGenerator) u64 {
        self.id_counter += 1;
        return self.id_counter;
    }
};

pub fn getPreviousEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .@"enum" => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @enumFromInt(if (@intFromEnum(value) == 0)
        @typeInfo(@TypeOf(value)).@"enum".fields.len - 1
    else
        @intFromEnum(value) - 1);
}

pub fn getNextEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .@"enum" => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @enumFromInt(
        @mod(@as(usize, @intFromEnum(value)) + 1, @typeInfo(@TypeOf(value)).@"enum".fields.len),
    );
}
