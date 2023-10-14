const FlatVector = @import("../math.zig").FlatVector;
const UnorderedCollection = @import("../unordered_collection.zig").UnorderedCollection;
const std = @import("std");

/// Collection which allows iterating over objects which are spatially close to each other.
/// Grow-only data structure which uses contiguous memory where possible.
pub fn Collection(comptime T: type, comptime cell_side_length: u32) type {
    return struct {
        allocator: std.mem.Allocator,
        cells: CellMap,
        object_ids_to_cell_references: std.AutoHashMap(u64, CellReference),
        ordered_indices: std.ArrayList(CellIndex),

        const Self = @This();
        const CellIndex = @import("cell_index.zig").Index(cell_side_length);
        const CellMap = std.AutoHashMap(CellIndex, UnorderedCollection(T));

        pub fn create(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .cells = CellMap.init(allocator),
                .object_ids_to_cell_references = std.AutoHashMap(u64, CellReference).init(allocator),
                .ordered_indices = std.ArrayList(CellIndex).init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            self.ordered_indices.deinit();
            self.object_ids_to_cell_references.deinit();

            var it = self.cells.valueIterator();
            while (it.next()) |collection| {
                collection.destroy();
            }
            self.cells.deinit();
        }

        /// Inserts the given object into the collection. Invalidates existing iterators. The same
        /// object id should not be inserted twice.
        pub fn insert(
            self: *Self,
            object: T,
            object_id: u64,
            position: FlatVector,
        ) !void {
            const cell_index = CellIndex.fromPosition(position);

            const cell = try self.cells.getOrPut(cell_index);
            errdefer if (!cell.found_existing) {
                cell.value_ptr.destroy();
            };
            if (!cell.found_existing) {
                cell.value_ptr.* = UnorderedCollection(T).create(self.allocator);
                try self.ordered_indices.append(cell_index);
            }
            errdefer if (!cell.found_existing) {
                _ = self.ordered_indices.pop();
            };

            const object_ptr = try cell.value_ptr.appendUninitialized();
            errdefer cell.value_ptr.removeLastAppendedItem();
            object_ptr.* = object;

            try self.object_ids_to_cell_references.putNoClobber(
                object_id,
                .{ .index = cell_index, .object_ptr = object_ptr },
            );
            errdefer _ = self.object_ids_to_cell_references.remove(object_id);
        }

        /// Specified object must exist in this collection. Invalidates all iterators. Preserves the
        /// grids capacity.
        pub fn remove(self: *Self, object_id: u64) void {
            const cell_reference = self.object_ids_to_cell_references.fetchRemove(object_id).?.value;
            const cell = self.cells.getPtr(cell_reference.index).?;
            _ = cell.swapRemove(cell_reference.object_ptr);
        }

        /// Will be invalidated by modifications to this collection.
        pub fn iterator(self: *Self) Iterator {
            return self.iteratorAdvanced(0, 0);
        }

        /// Iterates over all items in this collection. Individual cells can be skipped by
        /// specifying offsets. Empty/non-existing cells are not considered by the offsets. Will be
        /// invalidated by modifications to this collection.
        pub fn iteratorAdvanced(
            self: *Self,
            /// Cells to skip from the first cell in this collection.
            offset_from_start: usize,
            /// Number cells to skip before advancing to the next cell.
            stride: usize,
        ) Iterator {
            std.mem.sort(CellIndex, self.ordered_indices.items, {}, lessThan);
            return .{
                .cells = &self.cells,
                .cell_iterator = null,
                .ordered_indices = self.ordered_indices.items,
                .index = offset_from_start,
                .step = stride + 1,
            };
        }

        pub const Iterator = struct {
            cells: *const CellMap,
            cell_iterator: ?UnorderedCollection(T).Iterator,
            ordered_indices: []CellIndex,
            index: usize,
            step: usize,

            /// Returns a mutable pointer for updating objects in-place.
            pub fn next(self: *Iterator) ?*T {
                if (self.cell_iterator) |*cell_iterator| {
                    if (cell_iterator.next()) |object| {
                        return object;
                    }
                }
                while (self.index < self.ordered_indices.len) {
                    const cell_index = self.ordered_indices[self.index];
                    self.index += self.step;

                    const cell = self.cells.getPtr(cell_index).?;
                    if (cell.count() > 0) {
                        self.cell_iterator = cell.iterator();
                        return self.cell_iterator.?.next();
                    }
                }
                return null;
            }
        };

        fn lessThan(_: void, a: CellIndex, b: CellIndex) bool {
            return a.compare(b) == .lt;
        }

        const CellReference = struct {
            index: CellIndex,
            /// Non-owning pointer.
            object_ptr: *T,
        };
    };
}
