const std = @import("std");

pub const Pool = struct {
    pool: *std.Thread.Pool,
    wait_group: *std.Thread.WaitGroup,

    pub fn create(allocator: std.mem.Allocator) !Pool {
        var pool = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(pool);
        try pool.init(.{ .allocator = allocator });
        errdefer pool.deinit();

        const wait_group = try allocator.create(std.Thread.WaitGroup);
        errdefer allocator.destroy(wait_group);
        wait_group.* = .{};

        return .{ .pool = pool, .wait_group = wait_group };
    }

    pub fn destroy(self: *Pool, allocator: std.mem.Allocator) void {
        allocator.destroy(self.wait_group);
        self.pool.deinit();
        allocator.destroy(self.pool);
    }

    pub fn dispatch(self: *Pool, comptime function: anytype, args: anytype) !void {
        self.wait_group.start();
        try self.pool.spawn(job, .{ self, function, args });
    }

    pub fn dispatchIgnoreErrors(self: *Pool, comptime function: anytype, args: anytype) !void {
        try self.dispatch(callAndIgnoreError, .{ function, args });
    }

    pub fn wait(self: *Pool) void {
        self.pool.waitAndWork(self.wait_group);
        self.wait_group.reset();
    }

    pub fn countThreads(self: Pool) usize {
        return self.pool.threads.len;
    }

    fn job(self: *Pool, comptime function: anytype, args: anytype) void {
        @call(.auto, function, args);
        self.wait_group.finish();
    }

    fn callAndIgnoreError(comptime function: anytype, args: anytype) void {
        @call(.auto, function, args) catch |err| {
            std.log.err("thread failed: {}", .{err});
        };
    }
};
