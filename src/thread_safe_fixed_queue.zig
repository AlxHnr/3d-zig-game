const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

        const Self = @This();

        pub fn create(allocator: std.mem.Allocator, queue_size: usize) !Self {
            return .{
                .items = try std.ArrayList(T).initCapacity(allocator, queue_size),
                .mutex = .{},
                .condition = .{},
            };
        }

        pub fn destroy(self: *Self) void {
            self.items.deinit();
        }

        pub fn pushAssumeCapacity(self: *Self, object: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.items.appendAssumeCapacity(object);
            self.condition.signal();
        }

        /// Will block until an object becomes available.
        pub fn pop(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.items.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
            return self.items.pop().?;
        }

        /// Must be followed by `reclaimLockedSlice()`.
        pub fn getLockedSlice(self: *Self) []T {
            self.mutex.lock();
            return self.items.items;
        }

        /// Must be preceded by `getLockedSlice()`.
        pub fn reclaimLockedSlice(self: *Self) void {
            self.mutex.unlock();
        }
    };
}
