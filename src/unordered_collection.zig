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

        /// Append a new, uninitialized object to this collection and return its address. This
        /// address will be valid until it gets swap-removed or the collection dies. The created
        /// item will be be visited by existing iterators.
        pub fn appendUninitialized(self: *Self) !*T {
            var item = try self.segments.addOne(self.allocator);
            item.* = undefined;
            return item;
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
            return .{
                .segment_iterator = self.segments.iterator(0),
                .current_item = null,
                .return_current_item_again = false,
            };
        }

        pub fn constIterator(self: *const Self) std.SegmentedList(T, 0).ConstIterator {
            return self.segments.constIterator(0);
        }

        /// Destroy the current item returned by Iterator.next() and replace it with the last item
        /// in this collection. This will invalidate all pointers to the current item and the last
        /// item.
        pub fn swapRemoveCurrentItem(self: *Self, it: *Iterator) void {
            std.debug.assert(it.current_item != null);
            std.debug.assert(it.return_current_item_again == false);
            if (it.segment_iterator.peek() == null) {
                _ = self.segments.pop();
                return;
            }
            it.current_item.?.* = self.segments.pop().?;
            it.return_current_item_again = true;
        }

        pub const Iterator = struct {
            segment_iterator: std.SegmentedList(T, 0).Iterator,
            current_item: ?*T,
            return_current_item_again: bool,

            pub fn next(self: *Iterator) ?*T {
                if (self.return_current_item_again) {
                    self.return_current_item_again = false;
                    return self.current_item;
                }
                self.current_item = self.segment_iterator.next();
                return self.current_item;
            }
        };

        pub const ConstIterator = std.SegmentedList(T, 0).ConstIterator;
    };
}
