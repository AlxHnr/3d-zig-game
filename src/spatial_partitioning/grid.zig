const AxisAlignedBoundingBox = @import("../collision.zig").AxisAlignedBoundingBox;
const FlatVector = @import("../math.zig").FlatVector;
const UnorderedCollection = @import("../unordered_collection.zig").UnorderedCollection;
const cell_line_iterator = @import("cell_line_iterator.zig");
const std = @import("std");

/// Collection for storing objects redundantly in multiple cells. Allows fast queries over objects
/// which are spatially close to each other. Grow-only data structure which uses contiguous memory
/// where possible.
pub fn Grid(comptime T: type, comptime cell_side_length: u32) type {
    return struct {
        allocator: std.mem.Allocator,
        cells: std.AutoHashMap(CellIndex, UnorderedCollection(T)),
        /// Maps object ids to references of all cells containing copies of the object.
        object_ids_to_cell_references: std.AutoHashMap(u64, CellReferenceList),
        /// Counterpart to previous table.
        object_ptrs_to_object_ids: std.AutoHashMap(*const T, u64),

        const Self = @This();
        const CellIndex = @import("cell_index.zig").Index(cell_side_length);
        const CellRange = @import("cell_range.zig").Range(cell_side_length);

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .cells = std.AutoHashMap(CellIndex, UnorderedCollection(T)).init(allocator),
                .object_ids_to_cell_references = std.AutoHashMap(u64, CellReferenceList)
                    .init(allocator),
                .object_ptrs_to_object_ids = std.AutoHashMap(*const T, u64).init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            self.object_ptrs_to_object_ids.deinit();

            var ref_iterator = self.object_ids_to_cell_references.valueIterator();
            while (ref_iterator.next()) |cell_references| {
                self.allocator.free(cell_references.items);
            }
            self.object_ids_to_cell_references.deinit();

            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.destroy();
            }
            self.cells.deinit();
        }

        /// Reset this grid, including all of its cells, to an empty state. Preserves its allocated
        /// capacity. Invalidates all existing iterators and pointers to objects in this grid.
        pub fn resetPreservingCapacity(self: *Self) void {
            self.object_ptrs_to_object_ids.clearRetainingCapacity();
            var ref_iterator = self.object_ids_to_cell_references.valueIterator();
            while (ref_iterator.next()) |cell_references| {
                self.allocator.free(cell_references.items);
            }
            self.object_ids_to_cell_references.clearRetainingCapacity();
            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.resetPreservingCapacity();
            }
        }

        /// Insert copies of the given object into every cell which intersects with the specified
        /// bounding box. Invalidates existing iterators. The same object id should not be inserted
        /// twice.
        pub fn insertIntoArea(
            self: *Self,
            object: T,
            object_id: u64,
            area: AxisAlignedBoundingBox,
        ) !void {
            const cell_range = CellRange.fromAABB(area);
            var iterator = cell_range.iterator();
            try self.insertRaw(object, object_id, &iterator, cell_range.countCoveredCells());
        }

        /// Insert copies of the given object into every cell which intersects with the edges/sides
        /// of the specified polygon. A cell which intersects with multiple edges will still contain
        /// only one single copy. The first and last vertex of the polygon represent an edge.
        /// Invalidates existing iterators. The same object id should not be inserted twice.
        pub fn insertIntoPolygonBorders(
            self: *Self,
            object: T,
            object_id: u64,
            polygon_vertices: []const FlatVector,
        ) !void {
            var indices = std.AutoHashMap(CellIndex, void).init(self.allocator);
            defer indices.deinit();

            for (polygon_vertices, 1..) |vertex, next_index| {
                const next_vertex = polygon_vertices[@mod(next_index, polygon_vertices.len)];
                var iterator = cell_line_iterator.iterator(CellIndex, vertex, next_vertex);
                while (iterator.next()) |cell_index| {
                    try indices.put(cell_index, {});
                }
            }

            var iterator = KeyIteratorWrapper{ .iterator = indices.keyIterator() };
            try self.insertRaw(object, object_id, &iterator, indices.count());
        }

        /// The specified object id must exist in this grid. Invalidates existing iterators.
        /// Preserves the grids capacity.
        pub fn remove(self: *Self, object_id: u64) void {
            const key_value_pair = self.object_ids_to_cell_references.fetchRemove(object_id);
            std.debug.assert(key_value_pair != null);
            const cell_references = key_value_pair.?.value;

            for (cell_references.items) |cell_reference| {
                const cell = self.cells.getPtr(cell_reference.cell_index).?;
                if (cell.swapRemove(cell_reference.object_ptr)) |displaced_item_address| {
                    const displaced_object_id =
                        self.object_ptrs_to_object_ids.fetchRemove(displaced_item_address).?.value;
                    self.object_ptrs_to_object_ids.getPtr(cell_reference.object_ptr).?.* =
                        displaced_object_id;
                    const items =
                        self.object_ids_to_cell_references.get(displaced_object_id).?.items;
                    for (items) |*reference_to_displaced_object| {
                        if (reference_to_displaced_object.object_ptr == displaced_item_address) {
                            reference_to_displaced_object.object_ptr = cell_reference.object_ptr;
                        }
                    }
                } else {
                    _ = self.object_ptrs_to_object_ids.remove(cell_reference.object_ptr);
                }
            }
            self.allocator.free(cell_references.items);
        }

        /// Visit all cells intersecting with the specified area. Objects occupying multiple cells
        /// may be visited multiple times. Will be invalidated by updates to this grid.
        pub fn areaIterator(self: *const Self, area: AxisAlignedBoundingBox) ConstAreaIterator {
            return .{
                .cells = &self.cells,
                .index_iterator = CellRange.fromAABB(area).iterator(),
                .cell_iterator = null,
            };
        }

        pub const ConstAreaIterator = ConstBaseIterator(CellRange.Iterator);

        /// Visit all cells trough which the specified line passes. Objects occupying multiple cells
        /// may be visited multiple times. Will be invalidated by updates to the grid.
        pub fn straightLineIterator(
            self: *const Self,
            line_start: FlatVector,
            line_end: FlatVector,
        ) ConstStraightLineIterator {
            return .{
                .cells = &self.cells,
                .index_iterator = cell_line_iterator.iterator(CellIndex, line_start, line_end),
                .cell_iterator = null,
            };
        }

        pub const ConstStraightLineIterator = ConstBaseIterator(
            cell_line_iterator.Iterator(CellIndex),
        );

        const CellReference = struct { cell_index: CellIndex, object_ptr: *T };
        const CellReferenceList = struct { items: []CellReference };

        fn insertRaw(
            self: *Self,
            object: T,
            object_id: u64,
            /// Iterator which returns all indices into which a copy of the given object should be
            /// inserted.
            cell_index_iterator: anytype,
            /// Total amount of indices returned by `cell_index_iterator`.
            total_cell_count: usize,
        ) !void {
            const cell_reference_list = .{
                .items = try self.allocator.alloc(CellReference, total_cell_count),
            };
            errdefer self.allocator.free(cell_reference_list.items);

            try self.object_ids_to_cell_references.putNoClobber(object_id, cell_reference_list);
            errdefer _ = self.object_ids_to_cell_references.remove(object_id);

            var cell_counter: usize = 0;
            errdefer self.destroyPartialReferencesDuringInsert(
                cell_reference_list.items[0..cell_counter],
            );

            while (cell_index_iterator.next()) |cell_index| : (cell_counter += 1) {
                const cell = try self.cells.getOrPut(cell_index);
                if (!cell.found_existing) {
                    cell.value_ptr.* = UnorderedCollection(T).create(self.allocator);
                }
                errdefer if (!cell.found_existing) {
                    cell.value_ptr.destroy();
                    _ = self.cells.remove(cell_index);
                };

                const object_ptr = try cell.value_ptr.appendUninitialized();
                errdefer cell.value_ptr.removeLastAppendedItem();
                object_ptr.* = object;

                try self.object_ptrs_to_object_ids.putNoClobber(object_ptr, object_id);
                errdefer _ = self.object_ptrs_to_object_ids.remove(object_ptr);

                cell_reference_list.items[cell_counter] = .{
                    .cell_index = cell_index,
                    .object_ptr = object_ptr,
                };
            }
        }

        fn destroyPartialReferencesDuringInsert(
            self: *Self,
            cell_references: []CellReference,
        ) void {
            for (cell_references) |cell_reference| {
                _ = self.object_ptrs_to_object_ids.remove(cell_reference.object_ptr);

                const cell = self.cells.getPtr(cell_reference.cell_index).?;
                cell.removeLastAppendedItem();
                if (cell.count() == 0) {
                    cell.destroy();
                    _ = self.cells.remove(cell_reference.cell_index);
                }
            }
        }

        /// Dereferences results from the wrapped iterator.
        const KeyIteratorWrapper = struct {
            iterator: std.AutoHashMap(CellIndex, void).KeyIterator,

            fn next(self: *KeyIteratorWrapper) ?CellIndex {
                if (self.iterator.next()) |ptr| {
                    return ptr.*;
                }
                return null;
            }
        };

        fn ConstBaseIterator(comptime IndexIterator: type) type {
            return struct {
                cells: *const std.AutoHashMap(CellIndex, UnorderedCollection(T)),
                index_iterator: IndexIterator,
                cell_iterator: ?UnorderedCollection(T).ConstIterator,

                pub fn next(self: *@This()) ?T {
                    if (self.nextFromCellIterator()) |object| {
                        return object;
                    }
                    while (self.index_iterator.next()) |cell_index| {
                        if (self.cells.getPtr(cell_index)) |cell| {
                            self.cell_iterator = cell.constIterator();
                            if (self.nextFromCellIterator()) |object| {
                                return object;
                            }
                        }
                    }
                    return null;
                }

                fn nextFromCellIterator(self: *@This()) ?T {
                    if (self.cell_iterator) |*cell_iterator| {
                        if (cell_iterator.next()) |object| {
                            return object.*;
                        }
                        self.cell_iterator = null;
                    }
                    return null;
                }
            };
        }
    };
}
