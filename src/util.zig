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

    pub fn length(self: FlatVector) f32 {
        return rm.Vector3Length(self.toVector3());
    }

    pub fn lengthSquared(self: FlatVector) f32 {
        return self.x * self.x + self.z * self.z;
    }

    /// Get the angle needed to rotate this vector to have the same direction as another vector. The
    /// given vectors don't need to be normalized.
    pub fn computeRotationToOtherVector(self: FlatVector, other: FlatVector) f32 {
        const self_v2 = rm.Vector2Normalize(rl.Vector2{ .x = self.x, .y = self.z });
        const other_v2 = rm.Vector2Normalize(rl.Vector2{ .x = other.x, .y = other.z });
        const angle = math.acos(math.clamp(rm.Vector2DotProduct(self_v2, other_v2), -1, 1));
        return if (rm.Vector2DotProduct(other_v2, rl.Vector2{ .x = self.z, .y = -self.x }) < 0)
            -angle
        else
            angle;
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
