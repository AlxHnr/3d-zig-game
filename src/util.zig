//! Contains various helpers that belong nowhere else.

const std = @import("std");
const math = std.math;
const rl = @import("raylib");
const rm = @import("raylib-math");

pub const Constants = struct {
    pub const up = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
    /// Smallest viable number for game-world calculations.
    pub const epsilon = 0.00001;
};

/// Vector on a flat plane with no height information.
pub const FlatVector = struct {
    x: f32,
    z: f32,

    pub fn toVector3(self: FlatVector) rl.Vector3 {
        return rl.Vector3{ .x = self.x, .y = 0, .z = self.z };
    }

    pub fn fromVector3(vector: rl.Vector3) FlatVector {
        return FlatVector{ .x = vector.x, .z = vector.z };
    }

    pub fn normalize(self: FlatVector) FlatVector {
        return FlatVector.fromVector3(rm.Vector3Normalize(self.toVector3()));
    }

    /// Interpolate between this vectors state and another vector based on the given interval from
    /// 0 and 1. The given interval will be clamped into this range.
    pub fn lerp(self: FlatVector, other: FlatVector, interval: f32) FlatVector {
        const i = math.clamp(interval, 0, 1);
        return FlatVector{ .x = rm.Lerp(self.x, other.x, i), .z = rm.Lerp(self.z, other.z, i) };
    }

    pub fn add(self: FlatVector, other: FlatVector) FlatVector {
        return FlatVector{ .x = self.x + other.x, .z = self.z + other.z };
    }

    pub fn subtract(self: FlatVector, other: FlatVector) FlatVector {
        return FlatVector{ .x = self.x - other.x, .z = self.z - other.z };
    }

    pub fn scale(self: FlatVector, factor: f32) FlatVector {
        return FlatVector{ .x = self.x * factor, .z = self.z * factor };
    }

    pub fn length(self: FlatVector) f32 {
        return rm.Vector3Length(self.toVector3());
    }

    pub fn lengthSquared(self: FlatVector) f32 {
        return self.x * self.x + self.z * self.z;
    }

    pub fn dotProduct(self: FlatVector, other: FlatVector) f32 {
        return rm.Vector2DotProduct(
            rl.Vector2{ .x = self.x, .y = self.z },
            rl.Vector2{ .x = other.x, .y = other.z },
        );
    }

    /// Get the angle needed to rotate this vector to have the same direction as another vector. The
    /// given vectors don't need to be normalized.
    pub fn computeRotationToOtherVector(self: FlatVector, other: FlatVector) f32 {
        const other_normalized = other.normalize();
        const angle = math.acos(math.clamp(self.normalize().dotProduct(other_normalized), -1, 1));
        return if (other_normalized.dotProduct(FlatVector{ .x = self.z, .z = -self.x }) < 0)
            -angle
        else
            angle;
    }

    pub fn negate(self: FlatVector) FlatVector {
        return FlatVector{ .x = -self.x, .z = -self.z };
    }

    pub fn rotate(self: FlatVector, angle: f32) FlatVector {
        const sin = math.sin(angle);
        const cos = math.cos(angle);
        return FlatVector{ .x = self.x * cos + self.z * sin, .z = -self.x * sin + self.z * cos };
    }

    pub fn rotateRightBy90Degrees(self: FlatVector) FlatVector {
        return FlatVector{ .x = -self.z, .z = self.x };
    }
};

// TODO: Use std.math.degreesToRadians() after upgrade to zig 0.10.0.
pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * math.pi / 180;
}
pub fn radiansToDegrees(radians: f32) f32 {
    return radians * 180 / math.pi;
}

pub fn isEqualFloat(a: f32, b: f32) bool {
    return math.fabs(a - b) < Constants.epsilon;
}

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

pub fn makeMaterial(texture: rl.Texture) rl.Material {
    var material = rl.LoadMaterialDefault();
    rl.SetMaterialTexture(&material, @enumToInt(rl.MATERIAL_MAP_DIFFUSE), texture);
    return material;
}

pub const RaylibError = error{
    FailedToLoadTextureFile,
    FailedToCompileAndLinkShader,
};
