//! Contains extra math functions which are not in std.math.

const std = @import("std");
const rl = @import("raylib");

/// Smallest viable number for game-world calculations.
pub const epsilon = 0.00001;

/// Vector on a flat plane with no height information.
pub const FlatVector = struct {
    x: f32,
    z: f32,

    pub fn toVector3(self: FlatVector) rl.Vector3 {
        return rl.Vector3{ .x = self.x, .y = 0, .z = self.z };
    }

    pub fn fromVector3(vector: rl.Vector3) FlatVector {
        return .{ .x = vector.x, .z = vector.z };
    }

    pub fn normalize(self: FlatVector) FlatVector {
        const own_length = self.length();
        return if (own_length < epsilon)
            self
        else .{ .x = self.x / own_length, .z = self.z / own_length };
    }

    pub fn lerp(self: FlatVector, other: FlatVector, t: f32) FlatVector {
        return .{ .x = _lerp(self.x, other.x, t), .z = _lerp(self.z, other.z, t) };
    }

    pub fn add(self: FlatVector, other: FlatVector) FlatVector {
        return .{ .x = self.x + other.x, .z = self.z + other.z };
    }

    pub fn subtract(self: FlatVector, other: FlatVector) FlatVector {
        return .{ .x = self.x - other.x, .z = self.z - other.z };
    }

    pub fn scale(self: FlatVector, factor: f32) FlatVector {
        return .{ .x = self.x * factor, .z = self.z * factor };
    }

    pub fn length(self: FlatVector) f32 {
        return std.math.sqrt(self.lengthSquared());
    }

    pub fn lengthSquared(self: FlatVector) f32 {
        return self.x * self.x + self.z * self.z;
    }

    pub fn dotProduct(self: FlatVector, other: FlatVector) f32 {
        return self.x * other.x + self.z * other.z;
    }

    /// Get the angle needed to rotate this vector to have the same direction as another vector. The
    /// given vectors don't need to be normalized.
    pub fn computeRotationToOtherVector(self: FlatVector, other: FlatVector) f32 {
        const other_normalized = other.normalize();
        const angle = std.math.acos(std.math.clamp(self.normalize().dotProduct(
            other_normalized,
        ), -1, 1));
        return if (other_normalized.dotProduct(.{ .x = self.z, .z = -self.x }) < 0)
            -angle
        else
            angle;
    }

    pub fn negate(self: FlatVector) FlatVector {
        return .{ .x = -self.x, .z = -self.z };
    }

    pub fn rotate(self: FlatVector, angle: f32) FlatVector {
        const sin = std.math.sin(angle);
        const cos = std.math.cos(angle);
        return .{ .x = self.x * cos + self.z * sin, .z = -self.x * sin + self.z * cos };
    }

    pub fn rotateRightBy90Degrees(self: FlatVector) FlatVector {
        return .{ .x = -self.z, .z = self.x };
    }

    pub fn projectOnto(self: FlatVector, other: FlatVector) FlatVector {
        return other.scale(self.dotProduct(other) / other.dotProduct(other));
    }
};

/// Linearly interpolate between a and b. T is a value between 0 and 1. Will be clamped into this
/// range.
pub const lerp = _lerp;
fn _lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * std.math.clamp(t, 0, 1);
}
