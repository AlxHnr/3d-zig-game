//! Contains helpers for representing collision boundaries and resolving collisions.

const std = @import("std");
const math = @import("math.zig");

pub const Rectangle = struct {
    /// Game-world coordinates rotated around the worlds origin to axis-align this rectangle.
    first_corner: math.FlatVector,
    third_corner: math.FlatVector,
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
            return Rotation{ .sine = std.math.sin(angle), .cosine = std.math.cos(angle) };
        }

        fn rotate(self: Rotation, vector: math.FlatVector) math.FlatVector {
            return .{
                .x = vector.x * self.cosine + vector.z * self.sine,
                .z = -vector.x * self.sine + vector.z * self.cosine,
            };
        }
    };

    /// Takes game-world coordinates. Side a and b can be chosen arbitrarily, but must be adjacent.
    pub fn create(
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
        side_b_length: f32,
    ) Rectangle {
        const side_a_length = side_a_start.subtract(side_a_end).length();
        const rotation_angle = side_a_start.subtract(side_a_end)
            .computeRotationToOtherVector(.{ .x = 0, .z = -1 });
        const rotation = Rotation.create(rotation_angle);
        const first_corner = rotation.rotate(side_a_end);
        return Rectangle{
            .first_corner = first_corner,
            .third_corner = .{
                .x = first_corner.x + side_b_length,
                .z = first_corner.z - side_a_length,
            },
            .rotation = rotation,
            .inverse_rotation = Rotation.create(-rotation_angle),
        };
    }

    /// Check if this rectangle collides with the given line (game-world coordinates).
    pub fn collidesWithLine(
        self: Rectangle,
        line_start: math.FlatVector,
        line_end: math.FlatVector,
    ) bool {
        const start = self.rotation.rotate(line_start);
        const end = self.rotation.rotate(line_end);
        const second_corner = math.FlatVector{ .x = self.third_corner.x, .z = self.first_corner.z };
        const fourth_corner = math.FlatVector{ .x = self.first_corner.x, .z = self.third_corner.z };
        return self.collidesWithRotatedPoint(start) or
            self.collidesWithRotatedPoint(end) or
            lineCollidesWithLine(start, end, self.first_corner, fourth_corner) != null or
            lineCollidesWithLine(start, end, self.first_corner, second_corner) != null or
            lineCollidesWithLine(start, end, fourth_corner, self.third_corner) != null or
            lineCollidesWithLine(start, end, self.third_corner, second_corner) != null;
    }

    pub fn collidesWithPoint(self: Rectangle, point: math.FlatVector) bool {
        return self.collidesWithRotatedPoint(self.rotation.rotate(point));
    }

    pub fn getCornersInGameCoordinates(self: Rectangle) [4]math.FlatVector {
        const second_corner = .{ .x = self.third_corner.x, .z = self.first_corner.z };
        const fourth_corner = .{ .x = self.first_corner.x, .z = self.third_corner.z };
        return [_]math.FlatVector{
            self.inverse_rotation.rotate(self.first_corner),
            self.inverse_rotation.rotate(second_corner),
            self.inverse_rotation.rotate(self.third_corner),
            self.inverse_rotation.rotate(fourth_corner),
        };
    }

    fn collidesWithRotatedPoint(self: Rectangle, rotated_point: math.FlatVector) bool {
        return rotated_point.x > self.first_corner.x and
            rotated_point.x < self.third_corner.x and
            rotated_point.z < self.first_corner.z and
            rotated_point.z > self.third_corner.z;
    }
};

pub const Circle = struct {
    /// Contains game-world coordinates.
    position: math.FlatVector,
    radius: f32,

    pub fn lerp(self: Circle, other: Circle, t: f32) Circle {
        return Circle{
            .position = self.position.lerp(other.position, t),
            .radius = math.lerp(self.radius, other.radius, t),
        };
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithPoint(self: Circle, point: math.FlatVector) ?math.FlatVector {
        const center_to_point_offset = self.position.subtract(point);
        if (self.radius * self.radius - center_to_point_offset.lengthSquared() < math.epsilon) {
            return null;
        }

        return center_to_point_offset.normalize().scale(
            self.radius - center_to_point_offset.length(),
        );
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithCircle(self: Circle, other: Circle) ?math.FlatVector {
        const combined_circle = Circle{
            .position = self.position,
            .radius = self.radius + other.radius,
        };
        return combined_circle.collidesWithPoint(other.position);
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithLine(
        self: Circle,
        line_start: math.FlatVector,
        line_end: math.FlatVector,
    ) ?math.FlatVector {
        const start_displacement_vector = self.collidesWithPoint(line_start);
        const end_displacement_vector = self.collidesWithPoint(line_end);

        // Line endpoints are outside the circle.
        if (start_displacement_vector == null and end_displacement_vector == null) {
            const line_offset = line_end.subtract(line_start);
            const circle_to_line_offset = self.position.subtract(line_start);
            const t = circle_to_line_offset.dotProduct(line_offset) / line_offset.lengthSquared();
            if (t < 0 or t > 1) {
                return null;
            }
            const closest_point_on_line = line_start.add(line_offset.scale(t));
            return self.collidesWithPoint(closest_point_on_line);
        }

        // Line endpoints are inside the circle.
        if (end_displacement_vector == null) {
            return start_displacement_vector;
        }
        if (start_displacement_vector == null) {
            return end_displacement_vector;
        }
        if (start_displacement_vector.?.lengthSquared() < end_displacement_vector.?.lengthSquared()) {
            return start_displacement_vector;
        }
        return end_displacement_vector;
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithRectangle(self: Circle, rectangle: Rectangle) ?math.FlatVector {
        const rotated_self_position = rectangle.rotation.rotate(self.position);
        const reference_point = math.FlatVector{
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
        const displacement_vector =
            if (std.math.fabs(displacement_x) < std.math.fabs(displacement_z))
            math.FlatVector{ .x = displacement_x, .z = 0 }
        else
            math.FlatVector{ .x = 0, .z = displacement_z };

        return rectangle.inverse_rotation.rotate(displacement_vector);
    }

    fn getSmallestValueBasedOnAbsolute(a: f32, b: f32) f32 {
        return if (std.math.fabs(a) < std.math.fabs(b))
            a
        else
            b;
    }
};

/// Returns the intersection point.
pub fn lineCollidesWithLine(
    first_line_start: math.FlatVector,
    first_line_end: math.FlatVector,
    second_line_start: math.FlatVector,
    second_line_end: math.FlatVector,
) ?math.FlatVector {
    const first_line_lengths = math.FlatVector{
        .x = first_line_end.x - first_line_start.x,
        .z = first_line_end.z - first_line_start.z,
    };
    const second_line_lengths = math.FlatVector{
        .x = second_line_end.x - second_line_start.x,
        .z = second_line_end.z - second_line_start.z,
    };
    const divisor =
        second_line_lengths.z * first_line_lengths.x -
        second_line_lengths.x * first_line_lengths.z;
    if (std.math.fabs(divisor) < math.epsilon) {
        return null;
    }

    const line_start_offsets = math.FlatVector{
        .x = first_line_start.x - second_line_start.x,
        .z = first_line_start.z - second_line_start.z,
    };
    const t1 =
        (second_line_lengths.x * line_start_offsets.z -
        second_line_lengths.z * line_start_offsets.x) / divisor;
    const t2 =
        (first_line_lengths.x * line_start_offsets.z -
        first_line_lengths.z * line_start_offsets.x) / divisor;

    if (t1 > 0 and t1 < 1 and t2 > 0 and t2 < 1) {
        return first_line_start.lerp(first_line_end, t1);
    }
    return null;
}

pub fn lineCollidesWithPoint(
    line_start: math.FlatVector,
    line_end: math.FlatVector,
    point: math.FlatVector,
) bool {
    const line_offset = line_end.subtract(line_start);
    const point_to_line_start = point.subtract(line_start);
    const t = point_to_line_start.dotProduct(line_offset) / line_offset.lengthSquared();
    if (t < 0 or t > 1) {
        return false;
    }
    const closest_point_on_line = line_start.add(line_offset.scale(t));
    return closest_point_on_line.subtract(point).lengthSquared() < math.epsilon;
}

pub const Ray3d = struct {
    start_position: math.Vector3d,
    /// Must be normalized.
    direction: math.Vector3d,

    pub const ImpactPoint = struct {
        position: math.Vector3d,
        distance_from_start_position: f32,
    };

    /// If the given ray hits the ground, return informations about the impact point.
    pub fn collidesWithGround(self: Ray3d) ?ImpactPoint {
        if (std.math.signbit(self.start_position.y) == std.math.signbit(self.direction.y)) {
            return null;
        }
        if (std.math.fabs(self.direction.y) < math.epsilon) {
            return null;
        }
        const offset_to_ground = math.Vector3d{
            .x = -self.start_position.y / (self.direction.y / self.direction.x),
            .y = 0,
            .z = -self.start_position.y / (self.direction.y / self.direction.z),
        };
        return ImpactPoint{
            .position = self.start_position.add(offset_to_ground),
            .distance_from_start_position = offset_to_ground.subtract(self.start_position).length(),
        };
    }

    /// If the given triangle is not wired counter-clockwise, it will be ignored.
    pub fn collidesWithTriangle(self: Ray3d, triangle: [3]math.Vector3d) ?ImpactPoint {
        // Möller-Trumbore intersection algorithm.
        const edges = [2]math.Vector3d{
            triangle[1].subtract(triangle[0]),
            triangle[2].subtract(triangle[0]),
        };
        const p = self.direction.crossProduct(edges[1]);
        const determinant = edges[0].dotProduct(p);
        if (std.math.fabs(determinant) < math.epsilon) {
            return null;
        }
        const inverted_determinant = 1 / determinant;
        const triangle0_offset = self.start_position.subtract(triangle[0]);
        const u_parameter = inverted_determinant * triangle0_offset.dotProduct(p);
        if (u_parameter < 0 or u_parameter > 1) {
            return null;
        }
        const q_vector = triangle0_offset.crossProduct(edges[0]);
        const v_parameter = inverted_determinant * self.direction.dotProduct(q_vector);
        if (v_parameter < 0 or v_parameter + u_parameter > 1) {
            return null;
        }
        const distance_from_start_position = inverted_determinant * edges[1].dotProduct(q_vector);
        if (distance_from_start_position < math.epsilon) {
            return null;
        }
        return ImpactPoint{
            .position = self.start_position.add(self.direction.scale(distance_from_start_position)),
            .distance_from_start_position = distance_from_start_position,
        };
    }

    /// If the given quad is not wired counter-clockwise, it will be ignored.
    pub fn collidesWithQuad(self: Ray3d, quad: [4]math.Vector3d) ?ImpactPoint {
        return self.collidesWithTriangle(.{ quad[0], quad[1], quad[2] }) orelse
            self.collidesWithTriangle(.{ quad[0], quad[2], quad[3] });
    }
};
