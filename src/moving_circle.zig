const Map = @import("map/map.zig").Map;
const collision = @import("collision.zig");
const math = @import("math.zig");
const std = @import("std");

pub const MovingCircle = struct {
    radius: f32,
    velocity: math.FlatVector,
    pass_trough_fences: bool,
    /// Contains the position of this object during the substeps of the last tick. The values are
    /// ordered from old to new. The last value contains the current position.
    trace: [4]math.FlatVector,

    pub fn create(
        position: math.FlatVector,
        radius: f32,
        velocity: math.FlatVector,
        pass_trough_fences: bool,
    ) MovingCircle {
        var trace: [4]math.FlatVector = undefined;
        for (&trace) |*point| {
            point.* = position;
        }
        return .{
            .radius = radius,
            .velocity = velocity,
            .trace = trace,
            .pass_trough_fences = pass_trough_fences,
        };
    }

    pub fn getPosition(self: MovingCircle) math.FlatVector {
        return self.trace[self.trace.len - 1];
    }

    pub fn setPosition(self: *MovingCircle, position: math.FlatVector) void {
        self.setTrace(&.{position});
    }

    pub fn processElapsedTick(self: *MovingCircle, map: Map) void {
        const velocity_length_squared = self.velocity.lengthSquared();
        if (velocity_length_squared < math.epsilon) {
            return;
        }
        const direction = self.velocity.normalize();

        // Max applicable velocity (limit) per tick is `radius * self.traces.len`.
        var index: usize = 0;
        var remaining_velocity = std.math.sqrt(velocity_length_squared);
        var boundaries = collision.Circle{ .position = self.getPosition(), .radius = self.radius };
        var trace: @TypeOf(self.trace) = undefined;
        while (remaining_velocity > math.epsilon and index < self.trace.len) : (index += 1) {
            const substep_length = @min(remaining_velocity, self.radius);
            remaining_velocity -= substep_length;

            var substep = direction.scale(substep_length);
            if (map.geometry.collidesWithCircle(boundaries, self.pass_trough_fences)) |displacement_vector| {
                boundaries.position = boundaries.position.add(displacement_vector);
                const friction = 1 + std.math
                    .clamp(direction.dotProduct(displacement_vector.normalize()), -1, 0);
                self.velocity = self.velocity.scale(friction);
                substep = substep.scale(friction);
            }
            boundaries.position = boundaries.position.add(substep);
            trace[index] = boundaries.position;
        }
        self.setTrace(trace[0..index]);
    }

    pub const PositionsDuringContact = struct { self: math.FlatVector, other: math.FlatVector };

    pub fn hasCollidedWith(self: MovingCircle, other: MovingCircle) ?PositionsDuringContact {
        for (self.trace, other.trace) |self_position, other_position| {
            const self_boundaries =
                collision.Circle{ .position = self_position, .radius = self.radius };
            const other_boundaries = .{ .position = other_position, .radius = other.radius };
            if (self_boundaries.collidesWithCircle(other_boundaries)) {
                return .{ .self = self_position, .other = other_position };
            }
        }
        return null;
    }

    /// Check if this object has collided with the given circle during `processElapsedTick()`.
    /// Returns the position of `self` during the substep at which the collision occurred.
    pub fn hasCollidedWithCircle(self: MovingCircle, other: collision.Circle) ?math.FlatVector {
        for (self.trace) |position| {
            const boundaries = collision.Circle{ .position = position, .radius = self.radius };
            if (boundaries.collidesWithCircle(other)) {
                return boundaries.position;
            }
        }
        return null;
    }

    /// Overwrite the positions occupied by this circle during the last tick. Can contain 0 or up to
    /// `self.trace.len` positions.
    pub fn setTrace(self: *MovingCircle, positions: []const math.FlatVector) void {
        std.debug.assert(positions.len <= self.trace.len);

        // Fill trace position array with interpolated values. This ensures that each trace contains
        // the same amount of positions, simplifying collision checks.
        switch (positions.len) {
            0 => {
                const position = self.getPosition();
                self.trace = .{ position, position, position, position };
            },
            1 => self.trace = .{ positions[0], positions[0], positions[0], positions[0] },
            2 => self.trace = .{
                positions[0],
                positions[0].lerp(positions[1], 1.0 / 3.0),
                positions[0].lerp(positions[1], 2.0 / 3.0),
                positions[1],
            },
            3 => self.trace = .{
                positions[0],
                positions[0].lerp(positions[1], 2.0 / 3.0),
                positions[1].lerp(positions[2], 1.0 / 3.0),
                positions[2],
            },
            4 => std.mem.copy(math.FlatVector, &self.trace, positions),
            else => unreachable,
        }
    }
};
