const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
const math = @import("../math.zig");
const std = @import("std");

/// Visits all cells trough which the specified line passes.
pub fn iterator(
    comptime CellIndex: type,
    line_start: math.FlatVector,
    line_end: math.FlatVector,
) Iterator(CellIndex) {
    // Adapted from https://lodev.org/cgtutor/raycasting.html
    const direction = line_end.subtract(line_start).normalize();
    const step_lengths_to_next_axis = math.FlatVector{
        .x = getStepLengthToNextAxis(direction.x),
        .z = getStepLengthToNextAxis(direction.z),
    };
    const start = line_start.multiplyScalar(fp(1).div(fp(CellIndex.side_length)));
    const wrapped = .{ .x = start.x.mod(fp(1)), .z = start.z.mod(fp(1)) };
    const distance_to_next_axis = math.FlatVector{
        .x = getDistanceToNextAxis(step_lengths_to_next_axis.x, direction.x, wrapped.x),
        .z = getDistanceToNextAxis(step_lengths_to_next_axis.z, direction.z, wrapped.z),
    };

    return .{
        .current = CellIndex.fromPosition(line_start),
        .last = CellIndex.fromPosition(line_end),
        .step = .{
            .x = if (direction.x.lt(fp(0))) -1 else 1,
            .z = if (direction.z.lt(fp(0))) -1 else 1,
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
            if (self.distance_to_next_axis.z.lt(self.distance_to_next_axis.x)) {
                self.distance_to_next_axis.z =
                    self.distance_to_next_axis.z.saturatingAdd(self.step_lengths_to_next_axis.z);
                self.current.z += self.step.z;
            } else {
                self.distance_to_next_axis.x =
                    self.distance_to_next_axis.x.saturatingAdd(self.step_lengths_to_next_axis.x);
                self.current.x += self.step.x;
            }
            return result;
        }
    };
}

fn getStepLengthToNextAxis(direction: math.Fix32) math.Fix32 {
    if (direction.eql(fp(0))) {
        return math.Fix32.Limits.max;
    }

    const max32 = math.Fix32.Limits.max.convertTo(math.Fix64);
    return fp64(1)
        .div(direction.convertTo(math.Fix64))
        .clamp(max32.neg(), max32)
        .abs()
        .convertTo(math.Fix32);
}

fn getDistanceToNextAxis(
    step_length: math.Fix32,
    direction: math.Fix32,
    wrapped_start: math.Fix32,
) math.Fix32 {
    if (step_length.eql(math.Fix32.Limits.max)) {
        return math.Fix32.Limits.max;
    }
    if (direction.lt(fp(0)) and wrapped_start.gt(fp(0))) {
        return step_length.mul(wrapped_start);
    }
    return step_length.mul(fp(1).sub(wrapped_start));
}
