//! Contains helpers for representing collision boundaries and resolving collisions.

const std = @import("std");
const math = std.math;
const rm = @import("raylib-math");
const util = @import("util.zig");

pub const Rectangle = struct {
    /// Game-world coordinates rotated around the worlds origin to axis-align this rectangle.
    bottom_left_corner: util.FlatVector,
    top_right_corner: util.FlatVector,
    /// Precomputed sine/cosine values for replicating this rectangles rotation around the game
    /// worlds origin.
    rotation: Rotation,
    /// Used for restoring the rectangles original position.
    inverse_rotation: Rotation,

    /// Contains the sine/cosine of an angle.
    const Rotation = struct {
        sine: f32,
        cosine: f32,

        fn create(angle: f32) Rotation {
            return Rotation{ .sine = math.sin(angle), .cosine = math.cos(angle) };
        }

        fn rotate(self: Rotation, vector: util.FlatVector) util.FlatVector {
            return util.FlatVector{
                .x = vector.x * self.cosine + vector.z * self.sine,
                .z = -vector.x * self.sine + vector.z * self.cosine,
            };
        }
    };

    /// Helper struct for precomputing this rectangles values.
    const Side = struct {
        lower_corner: util.FlatVector,
        upper_corner: util.FlatVector,
    };

    /// Takes game-world coordinates. Side a and b can be chosen arbitrarily, but must be adjacent.
    /// side_a_length is assumed to be positive and > than 0.
    pub fn create(
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
    ) Rectangle {
        std.debug.assert(side_b_length > util.Constants.epsilon);
        const side_a = if (side_a_start.z > side_a_end.z)
            Side{ .lower_corner = side_a_start, .upper_corner = side_a_end }
        else
            Side{ .lower_corner = side_a_end, .upper_corner = side_a_start };
        const side_a_length = side_a_start.subtract(side_a_end).length();
        const rotation_angle = side_a.upper_corner.subtract(side_a.lower_corner)
            .computeRotationToOtherVector(util.FlatVector{ .x = 0, .z = -1 });
        const rotation = Rotation.create(rotation_angle);
        const bottom_left_corner = rotation.rotate(side_a.lower_corner);
        return Rectangle{
            .bottom_left_corner = bottom_left_corner,
            .top_right_corner = util.FlatVector{
                .x = bottom_left_corner.x + side_b_length,
                .z = bottom_left_corner.z - side_a_length,
            },
            .rotation = rotation,
            .inverse_rotation = Rotation.create(-rotation_angle),
        };
    }
};

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
