//! Contains helpers for representing collision boundaries and resolving collisions.

const math = @import("std").math;
const rm = @import("raylib-math");
const util = @import("util.zig");

pub const Circle = struct {
    /// Contains game-world coordinates.
    position: util.FlatVector,
    radius: f32,

    /// Interpolate between this circles state and another circle based on the given interval from
    /// 0 and 1. The given interval will be clamped into this range.
    pub fn lerp(self: Circle, other: Circle, interval: f32) Circle {
        const i = math.clamp(interval, 0, 1);
        return Circle{
            .position = self.position.lerp(other.position, i),
            .radius = rm.Lerp(self.radius, other.radius, i),
        };
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collision(self: Circle, other: Circle) ?util.FlatVector {
        const offset_to_other = self.position.subtract(other.position).toVector3();
        const max_distance = self.radius + other.radius;
        const max_distance_squared = max_distance * max_distance;
        if (max_distance_squared - rm.Vector3LengthSqr(offset_to_other) < util.Constants.epsilon) {
            return null;
        }

        return util.FlatVector.fromVector3(rm.Vector3Scale(
            rm.Vector3Normalize(offset_to_other),
            max_distance - rm.Vector3Length(offset_to_other),
        ));
    }
};
