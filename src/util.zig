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

    pub fn isEqual(a: Color, b: Color) bool {
        return math.isEqual(a.r, b.r) and
            math.isEqual(a.g, b.g) and
            math.isEqual(a.b, b.b);
    }
};

/// Lap timer for measuring elapsed ticks.
pub const TickTimer = struct {
    timer: std.time.Timer,
    tick_duration: u64,
    leftover_time_from_last_tick: u64,

    /// Create a new tick timer for measuring the specified tick rate. The given value is assumed to
    /// be non-zero. Fails when no clock is available.
    pub fn start(ticks_per_second: u32) std.time.Timer.Error!TickTimer {
        std.debug.assert(ticks_per_second > 0);
        return TickTimer{
            .timer = try std.time.Timer.start(),
            .tick_duration = std.time.ns_per_s / ticks_per_second,
            .leftover_time_from_last_tick = 0,
        };
    }

    /// Return the amount of elapsed ticks since the last call of this function or since start().
    pub fn lap(self: *TickTimer) LapResult {
        const elapsed_time = self.timer.lap() + self.leftover_time_from_last_tick;
        self.leftover_time_from_last_tick = elapsed_time % self.tick_duration;
        return LapResult{
            .elapsed_ticks = elapsed_time / self.tick_duration,
            .next_tick_progress = @floatCast(
                @as(
                    f64,
                    @floatFromInt(self.leftover_time_from_last_tick),
                ) / @as(f64, @floatFromInt(self.tick_duration)),
            ),
        };
    }

    pub const LapResult = struct {
        elapsed_ticks: u64,
        /// Value between 0 and 1 denoting how much percent of the next tick has already passed.
        /// This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

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
