//! Contains the fundamentals of tick-based time and simulation handling.
const fp64 = math.Fix64.fp;
const math = @import("math.zig");
const std = @import("std");

/// This constant specifies a base value to which everything in the game relates to. To slow down or
/// speed up the game at runtime, use `TickTimer.start()`. Increasing the tickrate will also
/// change applied frictions (wall, crowd) and increase the velocity limit. Huge tickrates can break
/// movement by causing substeps to be shorter than `math.epsilon`.
pub const tickrate = 30;

// The following constants must be manually recomputed every time the tickrate changes. This does
// not happen at comptime, because Fixedpoint() is lacking certain mathematical functions at the
// time of writing. Since the tickrate pretty much never changes, these values have been computed
// once and got hard-coded here. The command to compute these values can be found below. It contains
// magic values which have been determined by trial and error to accommodate a wide range of
// tickrates.
//
// python3 -c 'TICKS=30; from math import *; p=print; p(max(0, 0.9 - pow(e, -0.03 * (TICKS - 5)))); p(max(5.5, 10 * (1.05 - pow(e, 0.15 - TICKS / 19))));'
pub const game_unit_stop_factor = 0.4276334472589853;
pub const enemy_peer_overlap_radius_factor = 8.104390409999155;

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

pub fn secondsToTicks(seconds: anytype) math.Fix64 {
    return fp64(seconds).mul(fp64(tickrate));
}

pub fn kphToGameUnitsPerTick(kilometers_per_hour: anytype) math.Fix32 {
    const meters_per_kilometer = fp64(1000);
    return fp64(kilometers_per_hour).mul(meters_per_kilometer)
        .div(fp64(std.time.s_per_hour)).div(fp64(tickrate)).convertTo(math.Fix32);
}
