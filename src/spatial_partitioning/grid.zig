const AxisAlignedBoundingBox = @import("../collision.zig").AxisAlignedBoundingBox;
const UnorderedCollection = @import("../unordered_collection.zig").UnorderedCollection;
const std = @import("std");

/// Collection for storing objects redundantly in multiple cells. Allows fast queries over objects
/// which are spatially close to each other. Grow-only data structure which uses contiguous memory
/// where possible.
pub fn Grid(comptime T: type, comptime cell_side_length: u32) type {
    return struct {
        allocator: std.mem.Allocator,
        cells: std.AutoHashMap(CellIndex, Cell),
        /// Maps object ids to references of all cells containing copies of the object.
        object_ids_to_cell_items: std.AutoHashMap(u64, CellReferenceList),
        /// Counterpart to previous table.
        cell_items_to_object_ids: std.AutoHashMap(*const CellItem, u64),

        const Self = @This();
        const Cell = UnorderedCollection(CellItem);
        const CellIndex = @import("cell_index.zig").Index(cell_side_length);
        const CellRange = @import("cell_range.zig").Range(cell_side_length);

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
        /// box. Invalidates existing iterators. The same object id should not be inserted twice.
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

        /// The specified object id must exist in this grid. Invalidates existing iterators.
        /// Preserves the grids capacity.
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

        /// Will be invalidated by updates to this grid. Objects occupying multiple cells will only
        /// be visited once.
        pub fn constIterator(self: *Self, region: AxisAlignedBoundingBox) ConstIterator {
            return .{
                .cells = &self.cells,
                .range_iterator = CellRange.fromAABB(region).iterator(),
                .cell_iterator = null,
            };
        }

        pub const ConstIterator = struct {
            cells: *const std.AutoHashMap(CellIndex, Cell),
            range_iterator: CellRange.Iterator,
            cell_iterator: ?Cell.ConstIterator,

            pub fn next(self: *ConstIterator) ?T {
                if (self.nextFromCellIterator()) |object| {
                    return object;
                }
                while (self.range_iterator.next()) |cell_index| {
                    if (self.cells.get(cell_index)) |cell| {
                        if (cell.count() > 0) {
                            self.cell_iterator = cell.constIterator();
                            if (self.nextFromCellIterator()) |object| {
                                return object;
                            }
                        }
                    }
                }
                return null;
            }

            fn nextFromCellIterator(self: *ConstIterator) ?T {
                if (self.cell_iterator) |*cell_iterator| {
                    while (cell_iterator.next()) |item| {
                        if (self.range_iterator.isOverlappingWithOnlyOneCell(item.cell_range)) {
                            return item.object;
                        }
                    }
                    self.cell_iterator = null;
                }
                return null;
            }
        };

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
