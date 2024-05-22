const FlatVector = @import("../math.zig").FlatVector;
const UnorderedCollection = @import("../unordered_collection.zig").UnorderedCollection;
const std = @import("std");

/// Collection which allows iterating over objects which are spatially close to each other.
pub fn Collection(comptime T: type, comptime cell_side_length: u32) type {
    return struct {
        allocator: std.mem.Allocator,
        cells: CellMap,
        ordered_indices: std.ArrayList(CellIndex),
        object_ptr_to_back_references: std.AutoHashMap(*const T, *BackReference),
        back_reference_pool: std.heap.MemoryPool(BackReference),

        const Self = @This();
        const CellIndex = @import("cell_index.zig").Index(cell_side_length);
        const CellMap = std.AutoHashMap(CellIndex, UnorderedCollection(T));
        const BackReference = struct { index: CellIndex, object_ptr: *T };

        /// Returned to the user of this collection to reference inserted objects. Can be used for
        /// removing objects from the collection.
        pub const ObjectHandle = opaque {};

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .cells = CellMap.init(allocator),
                .ordered_indices = std.ArrayList(CellIndex).init(allocator),
                .object_ptr_to_back_references = std.AutoHashMap(*const T, *BackReference)
                    .init(allocator),
                .back_reference_pool = std.heap.MemoryPool(BackReference).init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            self.back_reference_pool.deinit();
            self.object_ptr_to_back_references.deinit();
            self.ordered_indices.deinit();
            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |collection| {
                collection.destroy();
            }
            self.cells.deinit();
        }

        /// Inserts the given object into the collection. Invalidates existing iterators. The same
        /// object id should not be inserted twice.
        pub fn insert(self: *Self, object: T, position: FlatVector) !*ObjectHandle {
            const cell_index = CellIndex.fromPosition(position);

            const cell = try self.cells.getOrPut(cell_index);
            errdefer if (!cell.found_existing) {
                cell.value_ptr.destroy();
            };
            if (!cell.found_existing) {
                cell.value_ptr.* = UnorderedCollection(T).create(self.allocator);
                try self.ordered_indices.ensureUnusedCapacity(1);
            }

            const object_ptr = try cell.value_ptr.appendUninitialized();
            errdefer cell.value_ptr.removeLastAppendedItem();
            object_ptr.* = object;

            const back_reference = try self.back_reference_pool.create();
            errdefer self.back_reference_pool.destroy(back_reference);
            back_reference.* = .{ .index = cell_index, .object_ptr = object_ptr };

            try self.object_ptr_to_back_references.putNoClobber(object_ptr, back_reference);
            errdefer self.object_ptr_to_back_references.remove(object_ptr);

            if (!cell.found_existing) {
                self.ordered_indices.appendAssumeCapacity(cell_index);
                std.sort.insertion(CellIndex, self.ordered_indices.items, {}, lessThan);
            }

            return @ptrCast(back_reference);
        }

        /// Remove the object specified by the given handle. Will destroy the handle and invalidate
        /// all existing iterators. Preserves the collections capacity.
        pub fn remove(self: *Self, handle: *ObjectHandle) void {
            const back_reference = @as(*BackReference, @alignCast(@ptrCast(handle)));
            const cell = self.cells.getPtr(back_reference.index).?;
            if (cell.swapRemove(back_reference.object_ptr)) |displaced_object_ptr| {
                const displaced_back_reference =
                    self.object_ptr_to_back_references.fetchRemove(displaced_object_ptr).?.value;
                displaced_back_reference.object_ptr = back_reference.object_ptr;
                self.object_ptr_to_back_references.getPtr(back_reference.object_ptr).?.* =
                    displaced_back_reference;
            } else {
                _ = self.object_ptr_to_back_references.remove(back_reference.object_ptr);
            }
            self.back_reference_pool.destroy(back_reference);
        }

        /// The given object pointer must exist in this collection.
        pub fn getObjectHandle(self: Self, object_ptr: *T) *ObjectHandle {
            const ptr = self.object_ptr_to_back_references.get(object_ptr);
            std.debug.assert(ptr != null);
            return @ptrCast(ptr.?);
        }

        pub fn getCellIndex(_: Self, position: FlatVector) CellIndex {
            return CellIndex.fromPosition(position);
        }

        /// Will be invalidated by modifications to this collection.
        pub fn iterator(self: *Self) Iterator {
            return self.iteratorAdvanced(0, 0);
        }

        /// Iterates over all cells in this collection. Will be invalidated by modifications to this
        /// collection.
        pub fn cellGroupIterator(self: *Self) CellGroupIterator {
            return self.cellGroupIteratorAdvanced(0, 0);
        }

        /// Iterates over all items in this collection. Individual cells can be skipped by
        /// specifying offsets. Non-existing cells are not considered by the offsets. Will be
        /// invalidated by modifications to this collection.
        pub fn iteratorAdvanced(
            self: *Self,
            /// Cells to skip from the first cell in this collection.
            offset_from_start: usize,
            /// Number cells to skip before advancing to the next cell.
            stride: usize,
        ) Iterator {
            return .{
                .cell_group_iterator = self.cellGroupIteratorAdvanced(offset_from_start, stride),
                .cell_iterator = null,
            };
        }

        /// Iterates over all cells in this collection. Individual cells can be skipped by
        /// specifying offsets. Non-existing cells are not considered by the offsets. Will be
        /// invalidated by modifications to this collection.
        pub fn cellGroupIteratorAdvanced(
            self: *Self,
            /// Cells to skip from the first cell in this collection.
            offset_from_start: usize,
            /// Number cells to skip before advancing to the next cell.
            stride: usize,
        ) CellGroupIterator {
            return .{
                .cells = &self.cells,
                .ordered_indices = self.ordered_indices.items,
                .index = offset_from_start,
                .step = stride + 1,
            };
        }

        pub const Iterator = struct {
            cell_group_iterator: CellGroupIterator,
            cell_iterator: ?UnorderedCollection(T).Iterator,

            /// Returns a mutable pointer for updating objects in-place.
            pub fn next(self: *Iterator) ?*T {
                if (self.cell_iterator) |*cell_iterator| {
                    if (cell_iterator.next()) |object| {
                        return object;
                    }
                }
                if (self.cell_group_iterator.next()) |cell_group| {
                    self.cell_iterator = cell_group.cell.iterator();
                    return self.cell_iterator.?.next();
                }
                return null;
            }
        };

        pub const CellGroupIterator = struct {
            cells: *const CellMap,
            ordered_indices: []CellIndex,
            index: usize,
            step: usize,

            /// Returns the next cell group for mutable iteration. The returned collection itself
            /// should not be inserted to or deleted from.
            pub fn next(self: *CellGroupIterator) ?CellGroup {
                while (self.index < self.ordered_indices.len) {
                    const cell_index = self.ordered_indices[self.index];
                    self.index += self.step;

                    const cell = self.cells.getPtr(cell_index).?;
                    if (cell.count() > 0) {
                        return .{ .cell_index = cell_index, .cell = cell };
                    }
                }
                return null;
            }

            pub const CellGroup = struct {
                cell_index: CellIndex,
                cell: *UnorderedCollection(T),
            };
        };

        fn lessThan(_: void, a: CellIndex, b: CellIndex) bool {
            return a.compare(b) == .lt;
        }
    };
}
