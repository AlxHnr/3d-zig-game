//! Contains various helpers that belong nowhere else.

const math = @import("std").math;
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
};
