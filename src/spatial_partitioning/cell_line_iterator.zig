const math = @import("../math.zig");
const std = @import("std");

/// Visits all cells trough which the specified line passes.
pub fn iterator(
    comptime CellIndex: type,
    line_start: math.FlatVector,
    line_end: math.FlatVector,
) Iterator(CellIndex) {
    const abs = std.math.fabs;
    const f32_max = std.math.floatMax(f32);

    // Adapted from https://lodev.org/cgtutor/raycasting.html
    const direction = line_end.subtract(line_start).normalize();
    const step_lengths_to_next_axis = .{
        .x = if (abs(direction.x) < math.epsilon) f32_max else abs(1 / direction.x),
        .z = if (abs(direction.z) < math.epsilon) f32_max else abs(1 / direction.z),
    };
    const start = line_start.scale(1 / @as(f32, @floatFromInt(CellIndex.side_length)));
    const wrapped = .{ .x = @mod(start.x, 1), .z = @mod(start.z, 1) };
    const distance_to_next_axis = .{
        .x = step_lengths_to_next_axis.x *
            if (direction.x < 0 and wrapped.x > math.epsilon) wrapped.x else 1 - wrapped.x,
        .z = step_lengths_to_next_axis.z *
            if (direction.z < 0 and wrapped.z > math.epsilon) wrapped.z else 1 - wrapped.z,
    };

    return .{
        .current = CellIndex.fromPosition(line_start),
        .last = CellIndex.fromPosition(line_end),
        .step = .{
            .x = if (direction.x < 0) -1 else 1,
            .z = if (direction.z < 0) -1 else 1,
        },
        .step_lengths_to_next_axis = step_lengths_to_next_axis,
        .distance_to_next_axis = distance_to_next_axis,
    };
}

pub fn Iterator(comptime CellIndex: type) type {
    return struct {
        current: CellIndex,
        last: CellIndex,
        step: struct { x: i2, z: i2 },
        step_lengths_to_next_axis: math.FlatVector,
        distance_to_next_axis: math.FlatVector,

        const Self = @This();

        pub fn next(self: *Self) ?CellIndex {
            if (self.step.x == 0 and self.step.z == 0) {
                return null;
            }

            const result = self.current;
            if (result.x == self.last.x) {
                self.step.x = 0;
            }
            if (result.z == self.last.z) {
                self.step.z = 0;
            }
            if (self.distance_to_next_axis.z < self.distance_to_next_axis.x) {
                self.distance_to_next_axis.z += self.step_lengths_to_next_axis.z;
                self.current.z += self.step.z;
            } else {
                self.distance_to_next_axis.x += self.step_lengths_to_next_axis.x;
                self.current.x += self.step.x;
            }
            return result;
        }
    };
}
