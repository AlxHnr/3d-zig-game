const Map = @import("map/map.zig").Map;
const collision = @import("collision.zig");
const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
const math = @import("math.zig");
const std = @import("std");

pub const MovingCircle = struct {
    position: math.FlatVector,
    position_at_previous_tick: math.FlatVector,
    velocity: math.FlatVector,
    radius: math.Fix32,

    pub fn create(position: math.FlatVector, radius: math.Fix32) MovingCircle {
        return .{
            .position = position,
            .position_at_previous_tick = position,
            .velocity = math.FlatVector.zero,
            .radius = radius,
        };
    }

    pub fn processElapsedTick(self: *MovingCircle, map: Map) void {
        self.position_at_previous_tick = self.position;
        if (self.velocity.equal(math.FlatVector.zero)) {
            return;
        }
        const direction = self.velocity.normalizeApproximate();

        var remaining_velocity = self.velocity.lengthApproximate().convertTo(math.Fix32);
        var boundaries = collision.Circle{ .position = self.position, .radius = self.radius };
        while (remaining_velocity.gt(fp(0))) {
            const substep_length = remaining_velocity.min(self.radius);
            remaining_velocity = remaining_velocity.sub(substep_length);

            boundaries.position = boundaries.position.add(direction.multiplyScalar(substep_length));
            boundaries = map.geometry.moveOutOfWalls(boundaries);
        }
        self.position = boundaries.position;
    }

    pub const PositionsDuringContact = collision.Capsule.PointsOnCapsuleLines;

    /// Check if the given objects have collided during `processElapsedTick()`.
    pub fn hasCollidedWith(self: MovingCircle, other: MovingCircle) ?PositionsDuringContact {
        return self.getCapsule().collidesWithCapsule(other.getCapsule());
    }

    /// Check if this object has collided with the given circle during `processElapsedTick()`.
    /// Returns the position of `self` during the substep at which the collision occurred.
    pub fn hasCollidedWithCircle(self: MovingCircle, other: collision.Circle) ?math.FlatVector {
        return self.getCapsule().CollidesWithCircle(other);
    }

    fn getCapsule(self: MovingCircle) collision.Capsule {
        return .{
            .start = self.position_at_previous_tick,
            .end = self.position,
            .radius = self.radius,
        };
    }
};
