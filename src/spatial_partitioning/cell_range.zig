const AxisAlignedBoundingBox = @import("../collision.zig").AxisAlignedBoundingBox;
const assert = @import("std").debug.assert;
const cell_index = @import("cell_index.zig");
const getOverlap = @import("../math.zig").getOverlap;

/// Range is inclusive. A range from (1, 1) to (2, 2) represent 4 cells.
pub fn Range(comptime cell_side_length: u32) type {
    return struct {
        min: CellIndex,
        max: CellIndex,

        const Self = @This();
        const CellIndex = cell_index.Index(cell_side_length);

        pub fn fromAABB(aabb: AxisAlignedBoundingBox) Self {
            const min = CellIndex.fromPosition(aabb.min);
            const max = CellIndex.fromPosition(aabb.max);
            assert(min.x <= max.x);
            assert(min.z <= max.z);
            return .{ .min = min, .max = max };
        }

        pub fn countCoveredCells(self: Self) usize {
            return @intCast((self.max.x + 1 - self.min.x) * (self.max.z + 1 - self.min.z));
        }

        pub fn countTouchingCells(self: Self, other: Self) usize {
            const touching_rows =
                @max(0, 1 + getOverlap(self.min.z, self.max.z, other.min.z, other.max.z));
            const touching_columns =
                @max(0, 1 + getOverlap(self.min.x, self.max.x, other.min.x, other.max.x));
            return touching_rows * touching_columns;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .min = self.min, .max = self.max, .current = null };
        }

        pub const Iterator = struct {
            min: CellIndex,
            max: CellIndex,
            current: ?CellIndex,

            pub fn next(self: *Iterator) ?CellIndex {
                if (self.current) |*current| {
                    current.x += 1;
                    if (current.x > self.max.x) {
                        current.x = self.min.x;
                        current.z += 1;
                    }
                    if (current.z > self.max.z) {
                        return null;
                    }
                    return current.*;
                }
                self.current = self.min;
                return self.min;
            }

            pub fn isOverlappingWithOnlyOneCell(self: Iterator, range: Self) bool {
                const current = self.current orelse return false;
                var overlapping_cells: usize = 0;

                if (current.z > self.min.z) {
                    const already_traversed_block = Self{
                        .min = self.min,
                        .max = .{ .x = self.max.x, .z = current.z - 1 },
                    };
                    overlapping_cells += range.countTouchingCells(already_traversed_block);
                }

                const current_rows_block = Self{
                    .min = .{ .x = self.min.x, .z = current.z },
                    .max = .{ .x = current.x, .z = current.z },
                };
                overlapping_cells += range.countTouchingCells(current_rows_block);

                return overlapping_cells == 1;
            }
        };
    };
}
