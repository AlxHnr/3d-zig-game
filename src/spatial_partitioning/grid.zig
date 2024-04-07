const AxisAlignedBoundingBox = @import("../collision.zig").AxisAlignedBoundingBox;
const FlatVectorF32 = @import("../math.zig").FlatVectorF32;
const UnorderedCollection = @import("../unordered_collection.zig").UnorderedCollection;
const cell_line_iterator = @import("cell_line_iterator.zig");
const std = @import("std");

pub const Mode = enum {
    /// Grow-only grid for fast insertions.
    insert_only,
    /// Adds a `remove()` function to the grid.
    insert_remove,
};

/// Collection for storing objects redundantly in multiple cells. Allows fast queries over objects
/// which are spatially close to each other.
pub fn Grid(comptime T: type, comptime cell_side_length: u32, comptime grid_mode: Mode) type {
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
            while (self.back_references.popFirst()) |back_reference_node| {
                self.allocator.free(back_reference_node.data);
                self.allocator.destroy(back_reference_node);
            }
            var cell_iterator = self.cells.valueIterator();
            while (cell_iterator.next()) |cell| {
                cell.destroy();
            }
            self.cells.deinit();
        }

        // Make public functions available for the configured grid type.
        pub usingnamespace switch (grid_mode) {
            .insert_only => InsertOnlyFunctions,
            .insert_remove => InsertRemoveFunctions,
        };

        const InsertOnlyFunctions = struct {
            /// Insert copies of the given object into every cell which intersects with the
            /// specified bounding box. Invalidates existing iterators.
            pub fn insertIntoArea(self: *Self, object: T, area: AxisAlignedBoundingBox) !void {
                const cell_range = CellRange.fromAABB(area);
                var iterator = cell_range.iterator();
                try self.insertRaw(object, &iterator);
            }

            /// Insert copies of the given object into every cell which intersects with the
            /// edges/sides of the specified polygon. A cell which intersects with multiple edges
            /// will still contain only one single copy. The first and last vertex of the polygon
            /// represent an edge. Invalidates existing iterators.
            pub fn insertIntoPolygonBorders(
                self: *Self,
                object: T,
                polygon_vertices: []const FlatVectorF32,
            ) !void {
                var indices = try getPolygonIndices(self.allocator, polygon_vertices);
                defer indices.deinit();
                var iterator = .{ .iterator = indices.keyIterator() };
                try self.insertRaw(object, &iterator);
            }

            fn insertRaw(
                self: *Self,
                object: T,
                /// Iterator which returns all indices into which a copy of the given object should
                /// be inserted.
                cell_index_iterator: anytype,
            ) !void {
                while (cell_index_iterator.next()) |cell_index| {
                    const cell = try self.cells.getOrPut(cell_index);
                    if (!cell.found_existing) {
                        cell.value_ptr.* = UnorderedCollection(T).create(self.allocator);
                    }
                    errdefer if (!cell.found_existing) {
                        cell.value_ptr.destroy();
                        _ = self.cells.remove(cell_index);
                    };

                    try cell.value_ptr.append(object);
                    errdefer cell.value_ptr.removeLastAppendedItem();
                }
            }
        };

        const InsertRemoveFunctions = struct {
            /// Insert copies of the given object into every cell which intersects with the
            /// specified bounding box. Invalidates existing iterators. The returned handle can be
            /// ignored and is only needed for optionally removing the inserted object from the
            /// grid.
            pub fn insertIntoArea(
                self: *Self,
                object: T,
                area: AxisAlignedBoundingBox,
            ) !*ObjectHandle {
                const cell_range = CellRange.fromAABB(area);
                var iterator = cell_range.iterator();
                return try self.insertRaw(object, &iterator, cell_range.countCoveredCells());
            }

            /// Insert copies of the given object into every cell which intersects with the
            /// edges/sides of the specified polygon. A cell which intersects with multiple edges
            /// will still contain only one single copy. The first and last vertex of the polygon
            /// represent an edge. Invalidates existing iterators. The returned handle can be
            /// ignored and is only needed for optionally removing the inserted object from the
            /// grid.
            pub fn insertIntoPolygonBorders(
                self: *Self,
                object: T,
                polygon_vertices: []const FlatVectorF32,
            ) !*ObjectHandle {
                var indices = try getPolygonIndices(self.allocator, polygon_vertices);
                defer indices.deinit();
                var iterator = KeyIteratorWrapper{ .iterator = indices.keyIterator() };
                return try self.insertRaw(object, &iterator, indices.count());
            }

            /// Remove the object specified by the given handle. Will destroy the handle and
            /// invalidate all existing iterators. Preserves the grids capacity.
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

            fn insertRaw(
                self: *Self,
                object: T,
                /// Iterator which returns all indices into which a copy of the given object should
                /// be inserted.
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
                errdefer self.destroyPartialReferences(back_reference_node.data[0..cell_counter]);

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

                    try self.object_ptr_to_back_references.putNoClobber(
                        object_ptr,
                        back_reference_node,
                    );
                    errdefer _ = self.object_ptr_to_back_references.remove(object_ptr);

                    back_reference_node.data[cell_counter] =
                        .{ .cell_index = cell_index, .object_ptr = object_ptr };
                }

                return @ptrCast(back_reference_node);
            }

            fn destroyPartialReferences(self: *Self, back_references: []BackReference) void {
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
        };

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
            line_start: FlatVectorF32,
            line_end: FlatVectorF32,
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

        fn getPolygonIndices(
            allocator: std.mem.Allocator,
            vertices: []const FlatVectorF32,
        ) !std.AutoHashMap(CellIndex, void) {
            var indices = std.AutoHashMap(CellIndex, void).init(allocator);
            errdefer indices.deinit();

            for (vertices, 1..) |vertex, next_index| {
                const next_vertex = vertices[@mod(next_index, vertices.len)];
                var iterator = cell_line_iterator.iterator(CellIndex, vertex, next_vertex);
                while (iterator.next()) |cell_index| {
                    try indices.put(cell_index, {});
                }
            }

            return indices;
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
