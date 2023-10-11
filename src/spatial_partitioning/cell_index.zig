const FlatVector = @import("../math.zig").FlatVector;
const Order = @import("std").math.Order;
const assert = @import("std").debug.assert;

/// Takes the side length of a square cell specified in game units.
pub fn Index(comptime cell_side_length: u32) type {
    comptime {
        assert(cell_side_length > 0);
    }
    return struct {
        x: i16,
        z: i16,

        const Self = @This();

        pub fn fromPosition(position: FlatVector) Self {
            return Self{
                .x = @intFromFloat(position.x / @as(f32, @floatFromInt(cell_side_length))),
                .z = @intFromFloat(position.z / @as(f32, @floatFromInt(cell_side_length))),
            };
        }

        pub fn compare(self: Self, other: Self) Order {
            if (self.z < other.z) {
                return .lt;
            }
            if (self.z > other.z) {
                return .gt;
            }
            if (self.x < other.x) {
                return .lt;
            }
            if (self.x > other.x) {
                return .gt;
            }
            return .eq;
        }
    };
}
