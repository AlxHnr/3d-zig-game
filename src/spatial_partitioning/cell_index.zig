const FlatVector = @import("../math.zig").FlatVector;
const Order = @import("std").math.Order;
const assert = @import("std").debug.assert;
const fp = @import("../math.zig").Fix32.fp;

/// Takes the side length of a square cell specified in game units.
pub fn Index(comptime cell_side_length: u32) type {
    comptime {
        assert(cell_side_length > 0);
    }
    return struct {
        x: i16,
        z: i16,
        pub const side_length = cell_side_length;

        const Self = @This();

        pub fn fromPosition(position: FlatVector) Self {
            return Self{
                .x = position.x.div(fp(cell_side_length)).convertTo(i16),
                .z = position.z.div(fp(cell_side_length)).convertTo(i16),
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
