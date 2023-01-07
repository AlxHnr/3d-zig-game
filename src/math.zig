//! Contains extra math functions which are not in std.math.

const std = @import("std");
const rl = @import("raylib");
const rm = @import("raylib-math");

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
        return FlatVector.fromVector3(rm.Vector3Normalize(self.toVector3()));
    }

    /// Interpolate between this vectors state and another vector based on the given interval from
    /// 0 and 1. The given interval will be clamped into this range.
    pub fn lerp(self: FlatVector, other: FlatVector, interval: f32) FlatVector {
        const i = std.math.clamp(interval, 0, 1);
        return .{ .x = rm.Lerp(self.x, other.x, i), .z = rm.Lerp(self.z, other.z, i) };
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
