//! Contains various helpers that belong nowhere else.

const std = @import("std");
const math = @import("math.zig");

/// Size in pixels.
pub const ScreenDimensions = struct {
    width: u16,
    height: u16,
};

/// Contains rgb values from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,

    /// Used as a neutral tint during color multiplication.
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };

    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255,
            .g = @as(f32, @floatFromInt(g)) / 255,
            .b = @as(f32, @floatFromInt(b)) / 255,
        };
    }

    pub fn lerp(self: Color, other: Color, t: f32) Color {
        return .{
            .r = math.lerp(self.r, other.r, t),
            .g = math.lerp(self.g, other.g, t),
            .b = math.lerp(self.b, other.b, t),
        };
    }
};

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
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @enumFromInt(if (@intFromEnum(value) == 0)
        @typeInfo(@TypeOf(value)).Enum.fields.len - 1
    else
        @intFromEnum(value) - 1);
}

pub fn getNextEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @enumFromInt(
        @mod(@as(usize, @intFromEnum(value)) + 1, @typeInfo(@TypeOf(value)).Enum.fields.len),
    );
}
