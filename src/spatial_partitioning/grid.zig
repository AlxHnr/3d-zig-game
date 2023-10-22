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
        /// References all cells containing copies of the same object.
        back_references: std.TailQueue([]BackReference),
        /// Allows each individual object copy to be traced back to all cells the object occupies.
        object_ptr_to_back_references: std.AutoHashMap(*const T, *BackReferenceNode),

        const Self = @This();
        const CellIndex = @import("cell_index.zig").Index(cell_side_length);
        const CellRange = @import("cell_range.zig").Range(cell_side_length);
        const BackReference = struct { cell_index: CellIndex, object_ptr: *T };
        const BackReferenceNode = std.TailQueue([]BackReference).Node;

        /// Returned to the user of this grid to reference inserted objects. Can be used for
        /// removing objects from the grid.
        pub const ObjectHandle = opaque {};

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .cells = std.AutoHashMap(CellIndex, UnorderedCollection(T)).init(allocator),
                .back_references = .{},
                .object_ptr_to_back_references = std.AutoHashMap(*const T, *BackReferenceNode)
                    .init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            self.object_ptr_to_back_references.deinit();
            while (self.back_references.popFirst()) |back_references| {
                self.allocator.free(back_references.data);
                self.allocator.destroy(back_references);
            }
            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.destroy();
            }
            self.cells.deinit();
        }

        /// Reset this grid, including all of its cells, to an empty state. Preserves its allocated
        /// capacity. Invalidates all existing iterators and pointers to objects in this grid.
        pub fn resetPreservingCapacity(self: *Self) void {
            self.object_ptr_to_back_references.clearRetainingCapacity();
            while (self.back_references.popFirst()) |back_references| {
                self.allocator.free(back_references.data);
                self.allocator.destroy(back_references);
            }
            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.resetPreservingCapacity();
            }
        }

        /// Insert copies of the given object into every cell which intersects with the specified
        /// bounding box. Invalidates existing iterators. The returned handle can be ignored and is
        /// only needed for optionally removing the inserted object from the grid.
        pub fn insertIntoArea(
            self: *Self,
            object: T,
            area: AxisAlignedBoundingBox,
        ) !*ObjectHandle {
            const cell_range = CellRange.fromAABB(area);
            var iterator = cell_range.iterator();
            return try self.insertRaw(object, &iterator, cell_range.countCoveredCells());
        }

        /// Insert copies of the given object into every cell which intersects with the edges/sides
        /// of the specified polygon. A cell which intersects with multiple edges will still contain
        /// only one single copy. The first and last vertex of the polygon represent an edge.
        /// Invalidates existing iterators. The returned handle can be ignored and is only needed
        /// for optionally removing the inserted object from the grid.
        pub fn insertIntoPolygonBorders(
            self: *Self,
            object: T,
            polygon_vertices: []const FlatVector,
        ) !*ObjectHandle {
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
            return try self.insertRaw(object, &iterator, indices.count());
        }

        /// Remove the object specified by the given handle. Will destroy the handle and invalidate
        /// all existing iterators. Preserves the grids capacity.
        pub fn remove(self: *Self, handle: *ObjectHandle) void {
            const back_reference_node = @as(*BackReferenceNode, @alignCast(@ptrCast(handle)));
            for (back_reference_node.data) |back_reference| {
                const cell = self.cells.getPtr(back_reference.cell_index).?;
                if (cell.swapRemove(back_reference.object_ptr)) |displaced_object_ptr| {
                    const displaced_handle = self.object_ptr_to_back_references
                        .fetchRemove(displaced_object_ptr).?.value;
                    self.object_ptr_to_back_references
                        .getPtr(back_reference.object_ptr).?.* = displaced_handle;
                    for (displaced_handle.data) |*reference_to_displaced_object| {
                        if (reference_to_displaced_object.object_ptr == displaced_object_ptr) {
                            reference_to_displaced_object.object_ptr = back_reference.object_ptr;
                        }
                    }
                } else {
                    _ = self.object_ptr_to_back_references.remove(back_reference.object_ptr);
                }
            }
            self.back_references.remove(back_reference_node);
            self.allocator.free(back_reference_node.data);
            self.allocator.destroy(back_reference_node);
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

        fn insertRaw(
            self: *Self,
            object: T,
            /// Iterator which returns all indices into which a copy of the given object should be
            /// inserted.
            cell_index_iterator: anytype,
            /// Total amount of indices returned by `cell_index_iterator`.
            total_cell_count: usize,
        ) !*ObjectHandle {
            var back_reference_node = try self.allocator.create(BackReferenceNode);
            errdefer self.allocator.destroy(back_reference_node);
            back_reference_node.* = .{
                .data = try self.allocator.alloc(BackReference, total_cell_count),
            };
            errdefer self.allocator.free(back_reference_node.data);
            self.back_references.append(back_reference_node);
            errdefer self.back_references.remove(back_reference_node);

            var cell_counter: usize = 0;
            errdefer self.destroyPartialReferencesDuringInsert(
                back_reference_node.data[0..cell_counter],
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

                try self.object_ptr_to_back_references
                    .putNoClobber(object_ptr, back_reference_node);
                errdefer _ = self.object_ptr_to_back_references.remove(object_ptr);

                back_reference_node.data[cell_counter] =
                    .{ .cell_index = cell_index, .object_ptr = object_ptr };
            }

            return @ptrCast(back_reference_node);
        }

        fn destroyPartialReferencesDuringInsert(
            self: *Self,
            back_references: []BackReference,
        ) void {
            for (back_references) |back_reference| {
                _ = self.object_ptr_to_back_references.remove(back_reference.object_ptr);

                const cell = self.cells.getPtr(back_reference.cell_index).?;
                cell.removeLastAppendedItem();
                if (cell.count() == 0) {
                    cell.destroy();
                    _ = self.cells.remove(back_reference.cell_index);
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
