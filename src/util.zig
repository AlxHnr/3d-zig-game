//! Contains various helpers that belong nowhere else.

const std = @import("std");
const rl = @import("raylib");
const rlgl = @cImport(@cInclude("rlgl.h"));
const math = @import("math.zig");

/// Contains rgb values from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,

    /// Used as a neutral tint during color multiplication.
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };

    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @intToFloat(f32, r) / 255,
            .g = @intToFloat(f32, g) / 255,
            .b = @intToFloat(f32, b) / 255,
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
            .next_tick_progress = @floatCast(f32, @intToFloat(
                f64,
                self.leftover_time_from_last_tick,
            ) / @intToFloat(f64, self.tick_duration)),
        };
    }

    pub const LapResult = struct {
        elapsed_ticks: u64,
        /// Value between 0 and 1 denoting how much percent of the next tick has already passed.
        /// This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

pub fn getPreviousEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @intToEnum(@TypeOf(value), if (@enumToInt(value) == 0)
        @typeInfo(@TypeOf(value)).Enum.fields.len - 1
    else
        @enumToInt(value) - 1);
}

pub fn getNextEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @intToEnum(
        @TypeOf(value),
        @mod(@intCast(usize, @enumToInt(value)) + 1, @typeInfo(@TypeOf(value)).Enum.fields.len),
    );
}
