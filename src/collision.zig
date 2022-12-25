//! Contains helpers for representing collision boundaries and resolving collisions.

const std = @import("std");
const math = std.math;
const rm = @import("raylib-math");
const util = @import("util.zig");

pub const Rectangle = struct {
    /// Game-world coordinates rotated around the worlds origin to axis-align this rectangle.
    first_corner: util.FlatVector,
    third_corner: util.FlatVector,
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

    /// Takes game-world coordinates. Side a and b can be chosen arbitrarily, but must be adjacent.
    pub fn create(
        side_a_start: util.FlatVector,
        side_a_end: util.FlatVector,
        side_b_length: f32,
    ) Rectangle {
        const side_a_length = side_a_start.subtract(side_a_end).length();
        const rotation_angle = side_a_start.subtract(side_a_end)
            .computeRotationToOtherVector(util.FlatVector{ .x = 0, .z = -1 });
        const rotation = Rotation.create(rotation_angle);
        const first_corner = rotation.rotate(side_a_end);
        return Rectangle{
            .first_corner = first_corner,
            .third_corner = util.FlatVector{
                .x = first_corner.x + side_b_length,
                .z = first_corner.z - side_a_length,
            },
            .rotation = rotation,
            .inverse_rotation = Rotation.create(-rotation_angle),
        };
    }

    /// Check if this rectangle collides with the given line (game-world coordinates).
    pub fn collidesWithLine(self: Rectangle, line_start: util.FlatVector, line_end: util.FlatVector) bool {
        const start = self.rotation.rotate(line_start);
        const end = self.rotation.rotate(line_end);
        const second_corner = util.FlatVector{ .x = self.third_corner.x, .z = self.first_corner.z };
        const fourth_corner = util.FlatVector{ .x = self.first_corner.x, .z = self.third_corner.z };
        return self.collidesWithRotatedPoint(start) or
            self.collidesWithRotatedPoint(end) or
            lineCollidesWithLine(start, end, self.first_corner, fourth_corner) or
            lineCollidesWithLine(start, end, self.first_corner, second_corner) or
            lineCollidesWithLine(start, end, fourth_corner, self.third_corner) or
            lineCollidesWithLine(start, end, self.third_corner, second_corner);
    }

    fn collidesWithRotatedPoint(self: Rectangle, rotated_point: util.FlatVector) bool {
        return rotated_point.x > self.first_corner.x and
            rotated_point.x < self.third_corner.x and
            rotated_point.z < self.first_corner.z and
            rotated_point.z > self.third_corner.z;
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
    pub fn collidesWithCircle(self: Circle, other: Circle) ?util.FlatVector {
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

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithRectangle(self: Circle, rectangle: Rectangle) ?util.FlatVector {
        const rotated_self_position = rectangle.rotation.rotate(self.position);
        const reference_point = util.FlatVector{
            .x = if (rotated_self_position.x < rectangle.first_corner.x)
                rectangle.first_corner.x
            else if (rotated_self_position.x > rectangle.third_corner.x)
                rectangle.third_corner.x
            else
                rotated_self_position.x,
            .z = if (rotated_self_position.z > rectangle.first_corner.z)
                rectangle.first_corner.z
            else if (rotated_self_position.z < rectangle.third_corner.z)
                rectangle.third_corner.z
            else
                rotated_self_position.z,
        };
        const offset = rotated_self_position.subtract(reference_point);
        if (offset.lengthSquared() > self.radius * self.radius) {
            return null;
        }

        const displacement_x = getSmallestValueBasedOnAbsolute(
            rectangle.first_corner.x - rotated_self_position.x - self.radius,
            rectangle.third_corner.x - rotated_self_position.x + self.radius,
        );
        const displacement_z = getSmallestValueBasedOnAbsolute(
            rectangle.first_corner.z - rotated_self_position.z + self.radius,
            rectangle.third_corner.z - rotated_self_position.z - self.radius,
        );
        const displacement_vector = if (math.fabs(displacement_x) < math.fabs(displacement_z))
            util.FlatVector{ .x = displacement_x, .z = 0 }
        else
            util.FlatVector{ .x = 0, .z = displacement_z };

        return rectangle.inverse_rotation.rotate(displacement_vector);
    }

    fn getSmallestValueBasedOnAbsolute(a: f32, b: f32) f32 {
        return if (math.fabs(a) < math.fabs(b))
            a
        else
            b;
    }
};

pub fn lineCollidesWithLine(
    first_line_start: util.FlatVector,
    first_line_end: util.FlatVector,
    second_line_start: util.FlatVector,
    second_line_end: util.FlatVector,
) bool {
    const first_line_lengths = util.FlatVector{
        .x = first_line_end.x - first_line_start.x,
        .z = first_line_end.z - first_line_start.z,
    };
    const second_line_lengths = util.FlatVector{
        .x = second_line_end.x - second_line_start.x,
        .z = second_line_end.z - second_line_start.z,
    };
    const divisor =
        second_line_lengths.z * first_line_lengths.x -
        second_line_lengths.x * first_line_lengths.z;
    if (math.fabs(divisor) < util.Constants.epsilon) {
        return false;
    }

    const line_start_offsets = util.FlatVector{
        .x = first_line_start.x - second_line_start.x,
        .z = first_line_start.z - second_line_start.z,
    };
    const x =
        (second_line_lengths.x * line_start_offsets.z -
        second_line_lengths.z * line_start_offsets.x) / divisor;
    const y =
        (first_line_lengths.x * line_start_offsets.z -
        first_line_lengths.z * line_start_offsets.x) / divisor;

    return x > 0 and x < 1 and y > 0 and y < 1;
}
