const AxisAlignedBoundingBox = @import("collision.zig").AxisAlignedBoundingBox;
const FlatVector = @import("math.zig").FlatVector;
const std = @import("std");

/// Side length of a square cell specified in game units.
const cell_side_length = 7;

pub const CellIndex = struct {
    x: i16,
    z: i16,

    pub fn fromPosition(position: FlatVector) CellIndex {
        return CellIndex{
            .x = @intFromFloat(position.x / cell_side_length),
            .z = @intFromFloat(position.z / cell_side_length),
        };
    }
};

/// Range is inclusive. A range from (1, 1) to (2, 2) represent 4 cells.
pub const CellRange = struct {
    min: CellIndex,
    max: CellIndex,

    pub fn fromAABB(aabb: AxisAlignedBoundingBox) CellRange {
        const min = CellIndex.fromPosition(aabb.min);
        const max = CellIndex.fromPosition(aabb.max);
        std.debug.assert(min.x <= max.x);
        std.debug.assert(min.z <= max.z);
        return .{ .min = min, .max = max };
    }

    pub fn countCoveredCells(self: CellRange) usize {
        return @intCast((self.max.x + 1 - self.min.x) * (self.max.z + 1 - self.min.z));
    }

    pub fn iterator(self: CellRange) Iterator {
        return .{ .min = self.min, .max = self.max, .current = self.min };
    }

    const Iterator = struct {
        min: CellIndex,
        max: CellIndex,
        current: CellIndex,

        pub fn next(self: *Iterator) ?CellIndex {
            if (self.current.z > self.max.z) {
                return null;
            }

            const result = self.current;
            self.current.x += 1;
            if (self.current.x > self.max.x) {
                self.current.x = self.min.x;
                self.current.z += 1;
            }
            return result;
        }
    };
};
