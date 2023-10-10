const AxisAlignedBoundingBox = @import("collision.zig").AxisAlignedBoundingBox;
const FlatVector = @import("math.zig").FlatVector;
const UnorderedCollection = @import("unordered_collection.zig").UnorderedCollection;
const getOverlap = @import("math.zig").getOverlap;
const std = @import("std");

/// Collection which stores objects redundantly in spatial bins, using contiguous memory where
/// possible. Allows fast traversal and queries over objects which are spatially close to each
/// other.
pub fn SpatialGrid(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        cells: std.AutoHashMap(CellIndex, Cell),
        /// Maps object ids to references of all cells containing copies of the object.
        object_ids_to_cell_items: std.AutoHashMap(u64, CellReferenceList),
        /// Counterpart to previous table.
        cell_items_to_object_ids: std.AutoHashMap(*const CellItem, u64),

        const Self = @This();
        const Cell = UnorderedCollection(CellItem);

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .cells = std.AutoHashMap(CellIndex, Cell).init(allocator),
                .object_ids_to_cell_items = std.AutoHashMap(u64, CellReferenceList).init(allocator),
                .cell_items_to_object_ids = std.AutoHashMap(*const CellItem, u64).init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            self.cell_items_to_object_ids.deinit();

            var ref_iterator = self.object_ids_to_cell_items.valueIterator();
            while (ref_iterator.next()) |cell_references| {
                self.allocator.free(cell_references.items);
            }
            self.object_ids_to_cell_items.deinit();

            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.destroy();
            }
            self.cells.deinit();
        }

        /// Inserts copies of the given object into every cell covered by the specified bounding
        /// box. The given object will be visited by existing iterators. The same object id should
        /// not be inserted twice.
        pub fn insert(
            self: *Self,
            object: T,
            object_id: u64,
            object_bounding_box: AxisAlignedBoundingBox,
        ) !void {
            const cell_range = CellRange.fromAABB(object_bounding_box);

            const cell_reference_list = .{
                .items = try self.allocator.alloc(CellReference, cell_range.countCoveredCells()),
            };
            errdefer self.allocator.free(cell_reference_list.items);

            try self.object_ids_to_cell_items.putNoClobber(object_id, cell_reference_list);
            errdefer _ = self.object_ids_to_cell_items.remove(object_id);

            var cell_counter: usize = 0;
            errdefer self.destroyPartialReferencesDuringInsert(
                cell_reference_list.items[0..cell_counter],
            );

            var it = cell_range.iterator();
            while (it.next()) |index| : (cell_counter += 1) {
                const cell = try self.cells.getOrPut(index);
                if (!cell.found_existing) {
                    cell.value_ptr.* = Cell.create(self.allocator);
                }
                errdefer if (!cell.found_existing) {
                    cell.value_ptr.destroy();
                    _ = self.cells.remove(index);
                };

                const item = try cell.value_ptr.appendUninitialized();
                errdefer cell.value_ptr.removeLastAppendedItem();
                item.* = .{ .cell_range = cell_range, .object = object };

                try self.cell_items_to_object_ids.putNoClobber(item, object_id);
                errdefer _ = self.cell_items_to_object_ids.remove(item);

                cell_reference_list.items[cell_counter] = .{ .index = index, .item = item };
            }
        }

        // The specified object id must exist in this grid.
        pub fn remove(self: *Self, object_id: u64) void {
            const key_value_pair = self.object_ids_to_cell_items.fetchRemove(object_id);
            std.debug.assert(key_value_pair != null);
            const cell_references = key_value_pair.?.value;

            for (cell_references.items) |cell_reference| {
                const cell = self.cells.getPtr(cell_reference.index).?;
                if (cell.swapRemove(cell_reference.item)) |displaced_item_address| {
                    const displaced_object_id =
                        self.cell_items_to_object_ids.fetchRemove(displaced_item_address).?.value;
                    self.cell_items_to_object_ids.getPtr(cell_reference.item).?.* =
                        displaced_object_id;
                    const items = self.object_ids_to_cell_items.get(displaced_object_id).?.items;
                    for (items) |*reference_to_displaced_object| {
                        if (reference_to_displaced_object.item == displaced_item_address) {
                            reference_to_displaced_object.item = cell_reference.item;
                        }
                    }
                } else {
                    _ = self.cell_items_to_object_ids.remove(cell_reference.item);
                }
            }
            self.allocator.free(cell_references.items);
        }

        const CellItem = struct {
            /// Contains all cells occupied by this item. Used for determining whether this item has
            /// already been visited by an iterator.
            cell_range: CellRange,
            object: T,
        };

        const CellReference = struct { index: CellIndex, item: *CellItem };
        const CellReferenceList = struct { items: []CellReference };

        fn destroyPartialReferencesDuringInsert(
            self: *Self,
            cell_references: []CellReference,
        ) void {
            for (cell_references) |cell_reference| {
                _ = self.cell_items_to_object_ids.remove(cell_reference.item);

                const cell = self.cells.getPtr(cell_reference.index).?;
                cell.removeLastAppendedItem();
                if (cell.count() == 0) {
                    cell.destroy();
                    _ = self.cells.remove(cell_reference.index);
                }
            }
        }
    };
}

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

    pub fn countTouchingCells(self: CellRange, other: CellRange) usize {
        const touching_rows =
            @max(0, 1 + getOverlap(self.min.z, self.max.z, other.min.z, other.max.z));
        const touching_columns =
            @max(0, 1 + getOverlap(self.min.x, self.max.x, other.min.x, other.max.x));
        return touching_rows * touching_columns;
    }

    pub fn iterator(self: CellRange) Iterator {
        return .{ .min = self.min, .max = self.max, .current = null };
    }

    const Iterator = struct {
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

        pub fn isOverlappingWithOnlyOneCell(self: Iterator, range: CellRange) bool {
            if (self.current) |current| {
                var overlapping_cells: usize = 0;

                if (current.z > self.min.z) {
                    const already_traversed_block = .{
                        .min = self.min,
                        .max = .{ .x = self.max.x, .z = current.z - 1 },
                    };
                    overlapping_cells += range.countTouchingCells(already_traversed_block);
                }

                const current_rows_block = .{
                    .min = .{ .x = self.min.x, .z = current.z },
                    .max = .{ .x = current.x, .z = current.z },
                };
                overlapping_cells += range.countTouchingCells(current_rows_block);

                return overlapping_cells == 1;
            }
            return false;
        }
    };
};
