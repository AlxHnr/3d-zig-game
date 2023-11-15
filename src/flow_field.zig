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

    pub fn recompute(self: *Field, new_center_and_destination: FlatVector, map: Map) !void {
        // This prevents the target from being unreachable when using coarse cell sizes.
        const center = correctPosition(new_center_and_destination, map);
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

    // If the given position exists on the flow field, return a directional vector for navigating
    // towards the flow fields center.
    pub fn getDirection(self: Field, position: FlatVector, map: Map) ?FlatVector {
        if (self.getIndexFromWorldPosition(position)) |index| {
            const direction = self.directional_vectors[index];
            if (direction != .none) {
                return toDirectionVector(direction);
            }
            var radius_factor: f32 = 0.5;
            while (radius_factor < 9) : (radius_factor *= 2) {
                const circle = .{
                    .position = position,
                    .radius = @as(f32, @floatFromInt(cell_side_length)) * radius_factor,
                };
                if (map.geometry.collidesWithCircle(circle, false)) |displacement_vector| {
                    const corrected_position = position.add(displacement_vector);
                    if (self.getIndexFromWorldPosition(corrected_position)) |cell_index| {
                        const corrected_direction = self.directional_vectors[cell_index];
                        if (corrected_direction != .none) {
                            return toDirectionVector(corrected_direction);
                        }
                    }
                }
            }
        }
        return null;
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

    // Push position further away from close walls.
    fn correctPosition(position: FlatVector, map: Map) FlatVector {
        const circle = .{
            .position = position,
            .radius = @as(f32, @floatFromInt(cell_side_length * 2)),
        };
        if (map.geometry.collidesWithCircle(circle, false)) |displacement_vector| {
            return position.add(displacement_vector);
        }
        return position;
    }

    fn getIndex(self: Field, x: usize, z: usize) usize {
        return z * self.grid_cells_per_side + x;
    }

    fn getIndexFromWorldPosition(self: Field, world_position: FlatVector) ?usize {
        const cell_position = world_position.subtract(self.boundaries.min)
            .scale(1.0 / @as(f32, @floatFromInt(cell_side_length)));
        const x: isize = @intFromFloat(@ceil(cell_position.x));
        const z: isize = @intFromFloat(@ceil(cell_position.z));
        if (x < 0 or x >= self.grid_cells_per_side or
            z < 0 or z >= self.grid_cells_per_side)
        {
            return null;
        }
        return self.getIndex(@intCast(x), @intCast(z));
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
        const tile_base_cost: CostInt = switch (map.geometry.getObstacleTile(world_position)) {
            .none => 0,
            .neighbor_of_obstacle => 4,
            .neighbor_of_multiple_obstacles => 6,
            .obstacle => max_cost,
        };
        cell.cost = cost +| tile_base_cost;
        if (cell.cost < max_cost) {
            try self.queue.add(.{ .x = x, .z = z, .cost = cell.cost });
        }
    }

    fn recomputeDirectionalVectors(self: *Field) void {
        const last = self.grid_cells_per_side - 1;

        // Compute corners.
        self.setDirectionalVector(0, 0, &.{
            .{ .x = 1, .z = 0, .dir = .right },
            .{ .x = 1, .z = 1, .dir = .down_right },
            .{ .x = 0, .z = 1, .dir = .down },
        });
        self.setDirectionalVector(last, 0, &.{
            .{ .x = last - 1, .z = 0, .dir = .left },
            .{ .x = last - 1, .z = 1, .dir = .down_left },
            .{ .x = last, .z = 1, .dir = .down },
        });
        self.setDirectionalVector(0, last, &.{
            .{ .x = 1, .z = last, .dir = .right },
            .{ .x = 1, .z = last - 1, .dir = .up_right },
            .{ .x = 0, .z = last - 1, .dir = .up },
        });
        self.setDirectionalVector(last, last, &.{
            .{ .x = last - 1, .z = last, .dir = .left },
            .{ .x = last - 1, .z = last - 1, .dir = .up_left },
            .{ .x = last, .z = last - 1, .dir = .up },
        });

        for (1..last) |x| {
            // Top edge.
            self.setDirectionalVector(x, 0, &.{
                .{ .x = x - 1, .z = 0, .dir = .left },
                .{ .x = x - 1, .z = 1, .dir = .down_left },
                .{ .x = x, .z = 1, .dir = .down },
                .{ .x = x + 1, .z = 1, .dir = .down_right },
                .{ .x = x + 1, .z = 0, .dir = .right },
            });
            // Bottom edge.
            self.setDirectionalVector(x, last, &.{
                .{ .x = x - 1, .z = last, .dir = .left },
                .{ .x = x - 1, .z = last - 1, .dir = .up_left },
                .{ .x = x, .z = last - 1, .dir = .up },
                .{ .x = x + 1, .z = last - 1, .dir = .up_right },
                .{ .x = x + 1, .z = last, .dir = .right },
            });
        }

        for (1..last) |z| {
            // Left edge.
            self.setDirectionalVector(0, z, &.{
                .{ .x = 0, .z = z - 1, .dir = .up },
                .{ .x = 1, .z = z - 1, .dir = .up_right },
                .{ .x = 1, .z = z, .dir = .right },
                .{ .x = 1, .z = z + 1, .dir = .down_right },
                .{ .x = 0, .z = z + 1, .dir = .down },
            });
            // Right edge.
            self.setDirectionalVector(last, z, &.{
                .{ .x = last, .z = z - 1, .dir = .up },
                .{ .x = last - 1, .z = z - 1, .dir = .up_left },
                .{ .x = last - 1, .z = z, .dir = .left },
                .{ .x = last - 1, .z = z + 1, .dir = .down_left },
                .{ .x = last, .z = z + 1, .dir = .down },
            });
        }

        // Center area.
        for (1..last) |z| {
            for (1..last) |x| {
                self.setDirectionalVector(x, z, &.{
                    .{ .x = x - 1, .z = z - 1, .dir = .up_left },
                    .{ .x = x, .z = z - 1, .dir = .up },
                    .{ .x = x + 1, .z = z - 1, .dir = .up_right },
                    .{ .x = x + 1, .z = z, .dir = .right },
                    .{ .x = x + 1, .z = z + 1, .dir = .down_right },
                    .{ .x = x, .z = z + 1, .dir = .down },
                    .{ .x = x - 1, .z = z + 1, .dir = .down_left },
                    .{ .x = x - 1, .z = z, .dir = .left },
                });
            }
        }
    }

    fn setDirectionalVector(self: *Field, x: usize, z: usize, cells: []const CellDirection) void {
        std.debug.assert(cells.len > 0);

        const index = self.getIndex(x, z);
        if (self.integration_field[index].cost == max_cost) {
            self.directional_vectors[index] = .none;
            return;
        }

        var cheapest_cell = .{ .cost = self.getCost(cells[0].x, cells[0].z), .dir = cells[0].dir };
        for (cells[1..]) |cell| {
            const cell_cost = self.getCost(cell.x, cell.z);
            if (cell_cost < cheapest_cell.cost) {
                cheapest_cell = .{ .cost = cell_cost, .dir = cell.dir };
            }
        }
        self.directional_vectors[index] = cheapest_cell.dir;
    }

    fn getCost(self: Field, x: usize, z: usize) CostInt {
        return self.integration_field[self.getIndex(x, z)].cost;
    }

    const CellDirection = struct { x: usize, z: usize, dir: Direction };

    fn toDirectionVector(direction: Direction) FlatVector {
        std.debug.assert(direction != .none);
        return switch (direction) {
            .up_left => .{ .x = -std.math.sqrt1_2, .z = -std.math.sqrt1_2 },
            .up => .{ .x = 0, .z = -1 },
            .up_right => .{ .x = std.math.sqrt1_2, .z = -std.math.sqrt1_2 },
            .left => .{ .x = -1, .z = 0 },
            .none => unreachable,
            .right => .{ .x = 1, .z = 0 },
            .down_left => .{ .x = -std.math.sqrt1_2, .z = std.math.sqrt1_2 },
            .down => .{ .x = 0, .z = 1 },
            .down_right => .{ .x = std.math.sqrt1_2, .z = std.math.sqrt1_2 },
        };
    }
};
