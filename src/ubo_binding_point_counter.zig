const Error = @import("error.zig").Error;
const StaticBitSet = @import("std").StaticBitSet;
const assert = @import("std").debug.assert;

unused_binding_points: StaticBitSet(36), // Guaranteed minimum amount of locations.

const Self = @This();

pub fn create() Self {
    return .{ .unused_binding_points = StaticBitSet(36).initFull() };
}

pub fn popAvailableBindingPoint(self: *Self) Error!usize {
    if (self.unused_binding_points.findFirstSet()) |binding_point| {
        self.unused_binding_points.unset(binding_point);
        return binding_point;
    }
    return Error.OutOfAvailableUboBindingPoints;
}

pub fn releaseBindingPoint(self: *Self, binding_point: usize) void {
    assert(!self.unused_binding_points.isSet(binding_point));
    self.unused_binding_points.set(binding_point);
}
