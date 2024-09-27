const std = @import("std");

/// Cache friendly container for fast iteration, insertion and deletion. Modifying this container
/// will not invalidate existing iterators and can be done while looping over it.
pub fn UnorderedCollection(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        segments: std.SegmentedList(T, 0),

        const Self = @This();

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .segments = .{} };
        }

        pub fn destroy(self: *Self) void {
            self.segments.deinit(self.allocator);
        }

        /// The appended item will be be visited by existing iterators.
        pub fn append(self: *Self, value: T) !void {
            try self.segments.append(self.allocator, value);
        }

        /// The appended item will be be visited by existing iterators.
        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            self.appendUninitializedAssumeCapacity().* = value;
        }

        /// Append a new, uninitialized object to this collection and return its address. This
        /// address will be valid until it gets swap-removed or the collection dies. The created
        /// item will be be visited by existing iterators.
        pub fn appendUninitialized(self: *Self) !*T {
            try self.ensureUnusedCapacity(1);
            return self.appendUninitializedAssumeCapacity();
        }

        // Like `appendUninitialized()` but without allocating.
        pub fn appendUninitializedAssumeCapacity(self: *Self) *T {
            const item = self.segments.uncheckedAt(self.segments.len);
            item.* = undefined;
            self.segments.len += 1;
            return item;
        }

        pub fn ensureUnusedCapacity(self: *Self, object_count: usize) !void {
            try self.segments.growCapacity(self.allocator, self.segments.count() + object_count);
        }

        /// Empty this collection and invalidate all pointers into it. Existing iterators will
        /// return null.
        pub fn resetPreservingCapacity(self: *Self) void {
            self.segments.clearRetainingCapacity();
        }

        /// Overwrite the given item with the last item in this collection and return the old, now
        /// invalid address of the last item. If the given item points to the last item, it will be
        /// destroyed and null gets returned. Other existing pointers to the given item and to the
        /// last item will be invalidated.
        pub fn swapRemove(self: *Self, item: *T) ?*T {
            std.debug.assert(self.segments.count() > 0);
            const last_item_address = self.segments.at(self.segments.count() - 1);
            if (item == last_item_address) {
                item.* = undefined;
                _ = self.segments.pop();
                return null;
            }
            item.* = self.segments.pop().?;
            return last_item_address;
        }

        pub fn removeLastAppendedItem(self: *Self) void {
            _ = self.segments.pop();
        }

        pub fn count(self: Self) usize {
            return self.segments.count();
        }

        pub fn iterator(self: *Self) Iterator {
            return self.segments.iterator(0);
        }

        pub fn constIterator(self: *const Self) std.SegmentedList(T, 0).ConstIterator {
            return self.segments.constIterator(0);
        }

        pub const Iterator = std.SegmentedList(T, 0).Iterator;
        pub const ConstIterator = std.SegmentedList(T, 0).ConstIterator;
    };
}
