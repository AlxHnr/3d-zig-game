const AxisAlignedBoundingBox = @import("collision.zig").AxisAlignedBoundingBox;
const FlatVector = @import("math.zig").FlatVector;
const Map = @import("map/map.zig").Map;
const cell_side_length = @import("map/geometry.zig").Geometry.obstacle_grid_cell_size;
const std = @import("std");

/// Grid of direction vectors leading towards its center, avoiding obstacles.
pub const Field = struct {
    grid_cells_per_side: usize,
    integration_field: []IntegrationCell,
    directional_vectors: []Direction,
    boundaries: AxisAlignedBoundingBox,
    queue: PriorityQueue,

    const IntegrationCell = packed struct {
        has_been_visited: bool,
        cost: CostInt,
        comptime {
            std.debug.assert(@sizeOf(IntegrationCell) == 2);
        }
    };
    const CostInt = u15;
    const max_cost = std.math.maxInt(CostInt);
    const Direction = enum { up_left, up, up_right, left, none, right, down_left, down, down_right };
    const PriorityQueue = std.PriorityQueue(QueueItem, void, QueueItem.compare);
    const QueueItem = struct {
        x: usize,
        z: usize,
        cost: CostInt,

        fn compare(_: void, a: QueueItem, b: QueueItem) std.math.Order {
            if (a.cost < b.cost) {
                return .lt;
            }
            if (a.cost > b.cost) {
                return .gt;
            }
            return .eq;
        }
    };

    pub fn create(allocator: std.mem.Allocator, grid_cells_per_side: usize) !Field {
        std.debug.assert(grid_cells_per_side >= 3);
        const array_length = grid_cells_per_side * grid_cells_per_side;
        var integration_field = try allocator.alloc(IntegrationCell, array_length);
        errdefer allocator.free(integration_field);
        var directional_vectors = try allocator.alloc(Direction, array_length);
        errdefer allocator.free(directional_vectors);
        @memset(directional_vectors, .none);
        return .{
            .grid_cells_per_side = grid_cells_per_side,
            .integration_field = integration_field,
            .directional_vectors = directional_vectors,
            .boundaries = .{ .min = FlatVector.zero, .max = FlatVector.zero },
            .queue = PriorityQueue.init(allocator, {}),
        };
    }

    pub fn destroy(self: *Field, allocator: std.mem.Allocator) void {
        self.queue.deinit();
        allocator.free(self.directional_vectors);
        allocator.free(self.integration_field);
    }

    pub fn recompute(
        self: *Field,
        new_center_and_destination: FlatVector,
        map: Map,
    ) !void {
        // Push position further away from close walls. This prevents the target from being
        // unreachable when using coarse cell sizes.
        const center = block: {
            const circle = .{
                .position = new_center_and_destination,
                .radius = @as(f32, @floatFromInt(cell_side_length * 2)),
            };
            if (map.geometry.collidesWithCircle(circle, false)) |displacement_vector| {
                break :block new_center_and_destination.add(displacement_vector);
            }
            break :block new_center_and_destination;
        };
        self.boundaries = block: {
            const side_length = @as(f32, @floatFromInt(self.grid_cells_per_side * cell_side_length));
            const half_side_length = side_length / 2.0;
            break :block .{
                .min = .{ .x = center.x - half_side_length, .z = center.z - half_side_length },
                .max = .{ .x = center.x + half_side_length, .z = center.z + half_side_length },
            };
        };

        @memset(self.integration_field, .{ .has_been_visited = false, .cost = max_cost });
        const center_tile = .{
            .x = self.grid_cells_per_side / 2,
            .z = self.grid_cells_per_side / 2,
            .cost = 0,
        };
        self.integration_field[self.getIndex(center_tile.x, center_tile.z)] =
            .{ .has_been_visited = true, .cost = center_tile.cost };
        try self.queue.add(center_tile);

        while (self.queue.removeOrNull()) |item| {
            const cost = self.integration_field[self.getIndex(item.x, item.z)].cost +| 1;
            if (item.x + 1 < self.grid_cells_per_side) {
                try self.processCell(item.x + 1, item.z, cost, map);
            }
            if (item.x > 0) {
                try self.processCell(item.x - 1, item.z, cost, map);
            }
            if (item.z + 1 < self.grid_cells_per_side) {
                try self.processCell(item.x, item.z + 1, cost, map);
            }
            if (item.z > 0) {
                try self.processCell(item.x, item.z - 1, cost, map);
            }
        }
        self.recomputeDirectionalVectors();
    }

    pub fn dumpAsText(self: Field, writer: std.fs.File.Writer) !void {
        for (0..self.grid_cells_per_side) |z| {
            for (0..self.grid_cells_per_side) |x| {
                _ = try writer.write(
                    switch (self.directional_vectors[self.getIndex(x, z)]) {
                        .up_left => "↖",
                        .up => "↑",
                        .up_right => "↗",
                        .left => "←",
                        .none => " ",
                        .right => "→",
                        .down_left => "↙",
                        .down => "↓",
                        .down_right => "↘",
                    },
                );
            }
            _ = try writer.write("\n");
        }
    }

    fn getIndex(self: Field, x: usize, z: usize) usize {
        return z * self.grid_cells_per_side + x;
    }

    fn getWorldPosition(self: Field, x: usize, z: usize) FlatVector {
        return FlatVector.scale(.{
            .x = @as(f32, @floatFromInt(x)),
            .z = @as(f32, @floatFromInt(z)),
        }, cell_side_length).add(self.boundaries.min);
    }

    fn processCell(
        self: *Field,
        x: usize,
        z: usize,
        cost: CostInt,
        map: Map,
    ) !void {
        const cell = &self.integration_field[self.getIndex(x, z)];
        const should_skip = cell.has_been_visited or cost == max_cost;
        cell.has_been_visited = true;
        if (should_skip) {
            return;
        }

        const world_position = self.getWorldPosition(x, z);
        const tile_base_cost = if (map.geometry.tileMayContainObstacle(world_position))
            max_cost
        else
            @as(CostInt, 0);
        cell.cost = cost +| tile_base_cost;
        if (cell.cost < max_cost) {
            try self.queue.add(.{ .x = x, .z = z, .cost = cell.cost });
        }
    }

    fn recomputeDirectionalVectors(self: *Field) void {
        const last = self.grid_cells_per_side - 1;

        // Compute corners.
        self.setDirectionalVector(0, 0, &.{
            .{ .cost = self.getCost(1, 0), .dir = .right },
            .{ .cost = self.getCost(1, 1), .dir = .down_right },
            .{ .cost = self.getCost(0, 1), .dir = .down },
        });
        self.setDirectionalVector(last, 0, &.{
            .{ .cost = self.getCost(last - 1, 0), .dir = .left },
            .{ .cost = self.getCost(last - 1, 1), .dir = .down_left },
            .{ .cost = self.getCost(last, 1), .dir = .down },
        });
        self.setDirectionalVector(0, last, &.{
            .{ .cost = self.getCost(1, last), .dir = .right },
            .{ .cost = self.getCost(1, last - 1), .dir = .up_right },
            .{ .cost = self.getCost(0, last - 1), .dir = .up },
        });
        self.setDirectionalVector(last, last, &.{
            .{ .cost = self.getCost(last - 1, last), .dir = .left },
            .{ .cost = self.getCost(last - 1, last - 1), .dir = .up_left },
            .{ .cost = self.getCost(last, last - 1), .dir = .up },
        });

        for (1..last) |x| {
            // Top edge.
            self.setDirectionalVector(x, 0, &.{
                .{ .cost = self.getCost(x - 1, 0), .dir = .left },
                .{ .cost = self.getCost(x - 1, 1), .dir = .down_left },
                .{ .cost = self.getCost(x, 1), .dir = .down },
                .{ .cost = self.getCost(x + 1, 1), .dir = .down_right },
                .{ .cost = self.getCost(x + 1, 0), .dir = .right },
            });
            // Bottom edge.
            self.setDirectionalVector(x, last, &.{
                .{ .cost = self.getCost(x - 1, last), .dir = .left },
                .{ .cost = self.getCost(x - 1, last - 1), .dir = .up_left },
                .{ .cost = self.getCost(x, last - 1), .dir = .up },
                .{ .cost = self.getCost(x + 1, last - 1), .dir = .up_right },
                .{ .cost = self.getCost(x + 1, last), .dir = .right },
            });
        }

        for (1..last) |z| {
            // Left edge.
            self.setDirectionalVector(0, z, &.{
                .{ .cost = self.getCost(0, z - 1), .dir = .up },
                .{ .cost = self.getCost(1, z - 1), .dir = .up_right },
                .{ .cost = self.getCost(1, z), .dir = .right },
                .{ .cost = self.getCost(1, z + 1), .dir = .down_right },
                .{ .cost = self.getCost(0, z + 1), .dir = .down },
            });
            // Right edge.
            self.setDirectionalVector(last, z, &.{
                .{ .cost = self.getCost(last, z - 1), .dir = .up },
                .{ .cost = self.getCost(last - 1, z - 1), .dir = .up_left },
                .{ .cost = self.getCost(last - 1, z), .dir = .left },
                .{ .cost = self.getCost(last - 1, z + 1), .dir = .down_left },
                .{ .cost = self.getCost(last, z + 1), .dir = .down },
            });
        }

        // Center area.
        for (1..last) |z| {
            for (1..last) |x| {
                self.setDirectionalVector(x, z, &.{
                    .{ .cost = self.getCost(x - 1, z - 1), .dir = .up_left },
                    .{ .cost = self.getCost(x, z - 1), .dir = .up },
                    .{ .cost = self.getCost(x + 1, z - 1), .dir = .up_right },
                    .{ .cost = self.getCost(x + 1, z), .dir = .right },
                    .{ .cost = self.getCost(x + 1, z + 1), .dir = .down_right },
                    .{ .cost = self.getCost(x, z + 1), .dir = .down },
                    .{ .cost = self.getCost(x - 1, z + 1), .dir = .down_left },
                    .{ .cost = self.getCost(x - 1, z), .dir = .left },
                });
            }
        }
    }

    fn setDirectionalVector(self: *Field, x: usize, z: usize, pairs: []const CostDirPair) void {
        self.directional_vectors[self.getIndex(x, z)] = getDirection(pairs);
    }

    fn getDirection(pairs: []const CostDirPair) Direction {
        var result = CostDirPair{ .cost = max_cost, .dir = .none };
        for (pairs[0..]) |pair| {
            if (pair.cost < result.cost) {
                result = pair;
            }
        }
        return result.dir;
    }

    fn getCost(self: Field, x: usize, z: usize) CostInt {
        return self.integration_field[self.getIndex(x, z)].cost;
    }

    const CostDirPair = struct { cost: CostInt, dir: Direction };
};
