//! Contains the fundamentals of tick-based time and simulation handling.
const std = @import("std");

/// This constant specifies a base value to which everything in the game relates to. To slow down or
/// speed up the game at runtime, use `TickTimer.start()`. Increasing the tickrate will also
/// change applied frictions (wall, crowd) and increase the velocity limit. Huge tickrates can break
/// movement by causing substeps to be shorter than `math.epsilon`.
pub const tickrate = 30;

/// Lap timer for measuring elapsed ticks.
pub const TickTimer = struct {
    timer: std.time.Timer,
    tick_duration: u64,
    leftover_time_from_last_tick: u64,

    /// Create a new tick timer for measuring the specified tick rate. The given value is assumed to
    /// be non-zero. Fails when no clock is available.
    pub fn start(ticks_per_second: u32) std.time.Timer.Error!TickTimer {
        std.debug.assert(ticks_per_second > 0);
        return .{
            .timer = try std.time.Timer.start(),
            .tick_duration = std.time.ns_per_s / ticks_per_second,
            .leftover_time_from_last_tick = 0,
        };
    }

    /// Return the amount of elapsed ticks since the last call of this function or since start().
    pub fn lap(self: *TickTimer) LapResult {
        const elapsed_time = self.timer.lap() + self.leftover_time_from_last_tick;
        self.leftover_time_from_last_tick = elapsed_time % self.tick_duration;
        return .{
            .elapsed_ticks = elapsed_time / self.tick_duration,
            .time_until_next_tick = self.tick_duration - self.leftover_time_from_last_tick,
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
        time_until_next_tick: u64,
        /// Value between 0 and 1 denoting how much percent of the next tick has already passed.
        /// This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

pub fn millisecondsToTicks(comptime T: type, milliseconds: T) T {
    return milliseconds / @as(T, std.time.ms_per_s) * @as(T, tickrate);
}

pub fn secondsToTicks(comptime T: type, seconds: T) T {
    return millisecondsToTicks(T, seconds * @as(T, std.time.ms_per_s));
}

pub fn kphToGameUnitsPerTick(kilometers_per_hour: f32) f32 {
    const meters_per_kilometer = 1000;
    return kilometers_per_hour * meters_per_kilometer /
        std.time.s_per_hour / tickrate;
}
