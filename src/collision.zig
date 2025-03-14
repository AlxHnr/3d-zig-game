//! Contains helpers for representing collision boundaries and resolving collisions.

const Fixedpoint = @import("fixedpoint.zig").Fixedpoint;
const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
const math = @import("math.zig");
const std = @import("std");

pub const AxisAlignedBoundingBox = struct {
    min: math.FlatVector,
    max: math.FlatVector,

    pub fn collidesWithPoint(self: AxisAlignedBoundingBox, point: math.FlatVector) bool {
        return point.x.gte(self.min.x) and
            point.z.gte(self.min.z) and
            point.x.lte(self.max.x) and
            point.z.lte(self.max.z);
    }

    pub fn sizeIsZero(self: AxisAlignedBoundingBox) bool {
        return self.min.equal(self.max);
    }
};

pub const Rectangle = struct {
    corners: [4]math.FlatVector,
    rotation_angle_to_align_with_axis: math.Fix32,

    /// Takes game-world coordinates. Side a and b can be chosen arbitrarily, but must be adjacent.
    pub fn create(
        side_a_start: math.FlatVector,
        side_a_end: math.FlatVector,
        side_b_length: math.Fix32,
    ) Rectangle {
        const side_a_offset = side_a_start.subtract(side_a_end);
        const side_b_offset = side_a_offset
            .rotateRightBy90Degrees().normalize().multiplyScalar(side_b_length);
        return .{
            .corners = .{
                side_a_start,
                side_a_end,
                side_a_end.add(side_b_offset),
                side_a_start.add(side_b_offset),
            },
            .rotation_angle_to_align_with_axis = side_a_offset
                .computeRotationToOtherVector(.{ .x = fp(0), .z = fp(-1) }),
        };
    }

    pub fn collidesWithLine(
        self: Rectangle,
        line_start: math.FlatVector,
        line_end: math.FlatVector,
    ) bool {
        const rotation = math.FlatVector.Rotation.create(self.rotation_angle_to_align_with_axis);
        const aabb = self.getRotatedAABB(rotation);
        return aabb.collidesWithPoint(rotation.rotate(line_start)) or
            aabb.collidesWithPoint(rotation.rotate(line_end)) or
            lineCollidesWithLine(line_start, line_end, self.corners[0], self.corners[1]) != null or
            lineCollidesWithLine(line_start, line_end, self.corners[1], self.corners[2]) != null or
            lineCollidesWithLine(line_start, line_end, self.corners[2], self.corners[3]) != null or
            lineCollidesWithLine(line_start, line_end, self.corners[3], self.corners[0]) != null;
    }

    pub fn collidesWithPoint(self: Rectangle, point: math.FlatVector) bool {
        const rotation = math.FlatVector.Rotation.create(self.rotation_angle_to_align_with_axis);
        return self.getRotatedAABB(rotation).collidesWithPoint(rotation.rotate(point));
    }

    pub const ClippedRay = struct {
        ray_end: math.FlatVector,
        distance_from_start_squared: math.Fix64,

        pub fn create(ray_start: math.FlatVector, ray_end: math.FlatVector) ClippedRay {
            return .{
                .ray_end = ray_end,
                .distance_from_start_position = ray_end.subtract(ray_start).lengthSquared(),
            };
        }

        /// Return the ray closest to its start.
        pub fn min(self: ClippedRay, other: ClippedRay) ClippedRay {
            return if (self.distance_from_start_squared.lt(other.distance_from_start_squared))
                self
            else
                other;
        }
    };

    pub fn clipRay(
        self: Rectangle,
        ray_start: math.FlatVector,
        ray_end: math.FlatVector,
    ) ClippedRay {
        const intersections = .{
            lineCollidesWithLine(ray_start, ray_end, self.corners[0], self.corners[1]) orelse ray_end,
            lineCollidesWithLine(ray_start, ray_end, self.corners[1], self.corners[2]) orelse ray_end,
            lineCollidesWithLine(ray_start, ray_end, self.corners[2], self.corners[3]) orelse ray_end,
            lineCollidesWithLine(ray_start, ray_end, self.corners[3], self.corners[0]) orelse ray_end,
        };
        return ClippedRay.create(ray_start, intersections[0])
            .min(ClippedRay.create(ray_start, intersections[1]))
            .min(ClippedRay.create(ray_start, intersections[2]))
            .min(ClippedRay.create(ray_start, intersections[3]));
    }

    fn getRotatedAABB(self: Rectangle, rotation: math.FlatVector.Rotation) AxisAlignedBoundingBox {
        const first_corner = rotation.rotate(self.corners[0]);
        const third_corner = rotation.rotate(self.corners[2]);
        return .{
            .min = .{
                .x = first_corner.x.min(third_corner.x),
                .z = first_corner.z.min(third_corner.z),
            },
            .max = .{
                .x = first_corner.x.max(third_corner.x),
                .z = first_corner.z.max(third_corner.z),
            },
        };
    }
};

pub const Circle = struct {
    position: math.FlatVector,
    radius: math.Fix32,

    pub fn lerp(self: Circle, other: Circle, t: math.Fix32) Circle {
        return .{
            .position = self.position.lerp(other.position, t),
            .radius = self.radius.lerp(other.radius, t),
        };
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithPoint(self: Circle, point: math.FlatVector) ?math.FlatVector {
        const center_to_point_offset = self.position.subtract(point);
        if (self.getRadiusSquared().sub(center_to_point_offset.lengthSquared()).lte(fp64(0))) {
            return null;
        }

        return center_to_point_offset.normalizeApproximate().multiplyScalar(
            self.radius.sub(center_to_point_offset.lengthApproximate().convertTo(math.Fix32)),
        );
    }

    pub fn collidesWithCircle(self: Circle, other: Circle) bool {
        const combined_radius = self.radius.add(other.radius).convertTo(math.Fix64);
        const center_to_center_distance = other.position.subtract(self.position).lengthSquared();
        return center_to_center_distance.lte(combined_radius.mul(combined_radius));
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithCircleDisplacementVector(self: Circle, other: Circle) ?math.FlatVector {
        const combined_circle = Circle{
            .position = self.position,
            .radius = self.radius.add(other.radius),
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
        const line_offset = line_end.subtract(line_start);
        const line_length_squared = line_offset.lengthSquared();
        if (line_length_squared.eql(fp64(0))) {
            return self.collidesWithPoint(line_start);
        }

        const circle_to_line_offset = self.position.subtract(line_start);
        const t = circle_to_line_offset.dotProduct(line_offset).div(line_length_squared);
        if (t.gte(fp64(0)) and t.lte(fp64(1))) {
            // Circle's center can be projected onto line.
            const closest_point_on_line =
                line_start.add(line_offset.multiplyScalar(t.convertTo(math.Fix32)));
            return self.collidesWithPoint(closest_point_on_line);
        }

        const start_displacement_vector = self.collidesWithPoint(line_start);
        const end_displacement_vector = self.collidesWithPoint(line_end);
        if (start_displacement_vector == null) {
            return end_displacement_vector;
        }
        if (end_displacement_vector == null) {
            return start_displacement_vector;
        }
        if (start_displacement_vector.?.lengthSquared()
            .gt(end_displacement_vector.?.lengthSquared()))
        {
            return start_displacement_vector;
        }
        return end_displacement_vector;
    }

    /// If a collision occurs, return a displacement vector for moving self out of other. The
    /// returned displacement vector must be added to self.position to resolve the collision.
    pub fn collidesWithRectangle(self: Circle, rectangle: Rectangle) ?math.FlatVector {
        const rotation =
            math.FlatVector.Rotation.create(rectangle.rotation_angle_to_align_with_axis);
        const aabb = rectangle.getRotatedAABB(rotation);
        const rotated_self_position = rotation.rotate(self.position);
        const reference_point = math.FlatVector{
            .x = rotated_self_position.x.clamp(aabb.min.x, aabb.max.x),
            .z = rotated_self_position.z.clamp(aabb.min.z, aabb.max.z),
        };
        const offset = rotated_self_position.subtract(reference_point);
        if (offset.lengthSquared().gt(self.getRadiusSquared())) {
            return null;
        }

        const displacement_x = getSmallestValueBasedOnAbsolute(
            aabb.min.x.sub(rotated_self_position.x).sub(self.radius),
            aabb.max.x.sub(rotated_self_position.x).add(self.radius),
        );
        const displacement_z = getSmallestValueBasedOnAbsolute(
            aabb.min.z.sub(rotated_self_position.z).sub(self.radius),
            aabb.max.z.sub(rotated_self_position.z).add(self.radius),
        );
        const displacement_vector =
            if (displacement_x.abs().lt(displacement_z.abs()))
            math.FlatVector{ .x = displacement_x, .z = fp(0) }
        else
            math.FlatVector{ .x = fp(0), .z = displacement_z };

        const result =
            displacement_vector.rotate(rectangle.rotation_angle_to_align_with_axis.neg());
        return if (result.equal(math.FlatVector.zero)) null else result;
    }

    pub fn getOuterBoundingBoxInGameCoordinates(self: Circle) AxisAlignedBoundingBox {
        return .{
            .min = .{
                .x = self.position.x.sub(self.radius),
                .z = self.position.z.sub(self.radius),
            },
            .max = .{
                .x = self.position.x.add(self.radius),
                .z = self.position.z.add(self.radius),
            },
        };
    }

    fn getRadiusSquared(self: Circle) math.Fix64 {
        const radius64 = self.radius.convertTo(math.Fix64);
        return radius64.mul(radius64);
    }

    fn getSmallestValueBasedOnAbsolute(a: math.Fix32, b: math.Fix32) math.Fix32 {
        return if (a.abs().lt(b.abs()))
            a
        else
            b;
    }
};

pub const Capsule = struct {
    start: math.FlatVector,
    end: math.FlatVector,
    radius: math.Fix32,

    /// Contains the points on each capsules line segment that are closest to each other.
    pub const PointsOnCapsuleLines = struct { self: math.FlatVector, other: math.FlatVector };

    pub fn collidesWithCapsule(self: Capsule, other: Capsule) ?PointsOnCapsuleLines {
        const distance_self_start_other_start = other.start.subtract(self.start).lengthSquared();
        const distance_self_start_other_end = other.end.subtract(self.start).lengthSquared();
        const distance_self_end_other_start = other.start.subtract(self.end).lengthSquared();
        const distance_self_end_other_end = other.end.subtract(self.end).lengthSquared();
        const distance_self_start_other =
            distance_self_start_other_start.min(distance_self_start_other_end);
        const distance_self_end_other =
            distance_self_end_other_start.min(distance_self_end_other_end);
        const closest_self_to_other = if (distance_self_start_other.lt(distance_self_end_other))
            self.start
        else
            self.end;
        const closest_point_on_other =
            getClosestPointOnLineClamped(closest_self_to_other, other.start, other.end);
        const closest_point_on_self =
            getClosestPointOnLineClamped(closest_point_on_other, self.start, self.end);
        const circles_collide = Circle.collidesWithCircle(
            .{ .position = closest_point_on_self, .radius = self.radius },
            .{ .position = closest_point_on_other, .radius = other.radius },
        );
        if (circles_collide) {
            return .{ .self = closest_point_on_self, .other = closest_point_on_other };
        }
        if (lineCollidesWithLine(self.start, self.end, other.start, other.end)) |intersection| {
            return .{ .self = intersection, .other = intersection };
        }
        return null;
    }

    /// Returns the point on the capsules line segment closest to the circle.
    pub fn CollidesWithCircle(self: Capsule, other: Circle) ?math.FlatVector {
        const closest_point = getClosestPointOnLineClamped(other.position, self.start, self.end);
        const circles_collide = other.collidesWithCircle(
            .{ .position = closest_point, .radius = self.radius },
        );
        return if (circles_collide) closest_point else null;
    }

    fn getClosestPointOnLineClamped(
        point: math.FlatVector,
        line_start: math.FlatVector,
        line_end: math.FlatVector,
    ) math.FlatVector {
        const line_offset = line_end.subtract(line_start);
        const line_length_squared = line_offset.lengthSquared();
        if (line_length_squared.eql(fp64(0))) {
            return line_start;
        }

        const point_to_line_start = point.subtract(line_start);
        const t = point_to_line_start
            .dotProduct(line_offset)
            .div(line_length_squared)
            .clamp(fp64(0), fp64(1))
            .convertTo(math.Fix32);
        return line_start.add(line_offset.multiplyScalar(t));
    }
};

/// Returns the intersection point.
pub fn lineCollidesWithLine(
    first_line_start: math.FlatVector,
    first_line_end: math.FlatVector,
    second_line_start: math.FlatVector,
    second_line_end: math.FlatVector,
) ?math.FlatVector {
    const first_line_lengths32 = first_line_end.subtract(first_line_start);
    const first_line_lengths = .{
        .x = first_line_lengths32.x.convertTo(math.Fix64),
        .z = first_line_lengths32.z.convertTo(math.Fix64),
    };
    const second_line_lengths32 = second_line_end.subtract(second_line_start);
    const second_line_lengths = .{
        .x = second_line_lengths32.x.convertTo(math.Fix64),
        .z = second_line_lengths32.z.convertTo(math.Fix64),
    };
    const divisor =
        second_line_lengths.z.mul(first_line_lengths.x)
        .sub(second_line_lengths.x.mul(first_line_lengths.z));
    if (divisor.eql(fp64(0))) {
        return null;
    }

    const line_start_offsets32 = first_line_start.subtract(second_line_start);
    const line_start_offsets = .{
        .x = line_start_offsets32.x.convertTo(math.Fix64),
        .z = line_start_offsets32.z.convertTo(math.Fix64),
    };
    const t1 =
        second_line_lengths.x.mul(line_start_offsets.z)
        .sub(second_line_lengths.z.mul(line_start_offsets.x)).div(divisor);
    const t2 =
        first_line_lengths.x.mul(line_start_offsets.z)
        .sub(first_line_lengths.z.mul(line_start_offsets.x)).div(divisor);

    if (t1.gte(fp64(0)) and t1.lte(fp64(1)) and t2.gte(fp64(0)) and t2.lte(fp64(1))) {
        return first_line_start.lerp(first_line_end, t1.convertTo(math.Fix32));
    }
    return null;
}

pub fn lineCollidesWithPoint(
    line_start: math.FlatVector,
    line_end: math.FlatVector,
    point: math.FlatVector,
) bool {
    const line_offset = line_end.subtract(line_start);
    const line_length_squared = line_offset.lengthSquared();
    if (line_length_squared.eql(fp64(0))) {
        return point.equal(line_start);
    }

    const point_to_line_start = point.subtract(line_start);
    const t = point_to_line_start.dotProduct(line_offset).div(line_length_squared);
    if (t.lt(fp64(0)) or t.gt(fp64(1))) {
        return false;
    }
    const closest_point_on_line =
        line_start.add(line_offset.multiplyScalar(t.convertTo(math.Fix32)));
    return closest_point_on_line.equal(point);
}

pub const Ray3d = struct {
    start_position: math.Vector3d,
    /// Must be normalized.
    direction: math.Vector3d,

    pub const ImpactPoint = struct {
        position: math.Vector3d,
        distance_from_start_position: math.Fix64,
    };

    /// If the given ray hits the ground, return informations about the impact point.
    pub fn collidesWithGround(self: Ray3d) ?ImpactPoint {
        if (self.start_position.y.lt(fp(0)) == self.direction.y.lt(fp(0))) {
            return null;
        }
        if (self.direction.y.eql(fp(0))) {
            return null;
        }
        const start_y64 = self.start_position.y.convertTo(math.Fix64);
        const direction64 = self.direction.convertTo(math.Vector3dLarge);
        const offset_to_ground = math.Vector3dLarge{
            .x = if (direction64.x.eql(fp64(0)))
                fp64(0)
            else
                start_y64.neg().div(direction64.y.div(direction64.x)),
            .y = fp64(0),
            .z = if (direction64.z.eql(fp64(0)))
                fp64(0)
            else
                start_y64.neg().div(direction64.y.div(direction64.z)),
        };
        const impact_position =
            self.start_position.convertTo(math.Vector3dLarge).add(offset_to_ground);
        if (impact_position.x.abs().gt(math.Fix32.Limits.max.convertTo(math.Fix64)) or
            impact_position.z.abs().gt(math.Fix32.Limits.max.convertTo(math.Fix64)))
        {
            return null;
        }
        return .{
            .position = impact_position.convertTo(math.Vector3d),
            .distance_from_start_position = offset_to_ground.length(),
        };
    }

    /// If the given triangle is not wired counter-clockwise, it will be ignored.
    pub fn collidesWithTriangle(self: Ray3d, triangle: [3]math.Vector3d) ?ImpactPoint {
        // Möller-Trumbore intersection algorithm.
        const Fix64Precise = Fixedpoint(40, 24);
        const Vector3dPrecise = math.Vector3dCustom(Fix64Precise, Fix64Precise);
        const fp64p = Fix64Precise.fp;

        const start_position = self.start_position.convertTo(Vector3dPrecise);
        const direction = self.direction.convertTo(Vector3dPrecise);
        const edges = .{
            triangle[1].subtract(triangle[0]).convertTo(Vector3dPrecise),
            triangle[2].subtract(triangle[0]).convertTo(Vector3dPrecise),
        };
        const p = direction.crossProduct(edges[1]);
        const determinant = edges[0].dotProduct(p);
        if (determinant.eql(fp64p(0))) {
            return null;
        }
        const inverted_determinant = fp64p(1).div(determinant);
        const triangle0_offset = start_position.subtract(triangle[0].convertTo(Vector3dPrecise));
        const u_parameter = inverted_determinant.mul(triangle0_offset.dotProduct(p));
        if (u_parameter.lt(fp64p(0)) or u_parameter.gt(fp64p(1))) {
            return null;
        }
        const q_vector = triangle0_offset.crossProduct(edges[0]);
        const v_parameter = inverted_determinant.mul(direction.dotProduct(q_vector));
        if (v_parameter.lt(fp64p(0)) or v_parameter.add(u_parameter).gt(fp64p(1))) {
            return null;
        }
        const distance_from_start_position =
            inverted_determinant.mul(edges[1].dotProduct(q_vector));
        if (distance_from_start_position.lte(fp64p(0))) {
            return null;
        }
        const impact_position =
            start_position.add(direction.multiplyScalar(distance_from_start_position));
        return .{
            .position = impact_position.convertTo(math.Vector3d),
            .distance_from_start_position = distance_from_start_position.convertTo(math.Fix64),
        };
    }

    /// If the given quad is not wired counter-clockwise, it will be ignored.
    pub fn collidesWithQuad(self: Ray3d, quad: [4]math.Vector3d) ?ImpactPoint {
        return self.collidesWithTriangle(.{ quad[0], quad[1], quad[2] }) orelse
            self.collidesWithTriangle(.{ quad[0], quad[2], quad[3] });
    }
};
