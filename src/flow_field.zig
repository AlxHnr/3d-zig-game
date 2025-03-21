const AxisAlignedBoundingBox = @import("collision.zig").AxisAlignedBoundingBox;
const Circle = @import("collision.zig").Circle;
const Map = @import("map/map.zig").Map;
const cell_side_length = @import("map/geometry.zig").obstacle_grid_cell_size;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const std = @import("std");

/// Grid of direction vectors leading towards its center, avoiding obstacles.
const Field = @This();

grid_cells_per_side: usize,
cell_unit_counter: []u8,
crowd_sampling_counter: usize,
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
const PriorityQueue = std.PriorityQueue(QueueItem, void, QueueItem.comparePriority);
const QueueItem = struct {
    x: usize,
    z: usize,
    cost: CostInt,

    fn comparePriority(_: void, a: QueueItem, b: QueueItem) std.math.Order {
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
    const cell_unit_counter = try allocator.alloc(u8, array_length);
    errdefer allocator.free(cell_unit_counter);
    @memset(cell_unit_counter, 0);
    const integration_field = try allocator.alloc(IntegrationCell, array_length);
    errdefer allocator.free(integration_field);
    const directional_vectors = try allocator.alloc(Direction, array_length);
    errdefer allocator.free(directional_vectors);
    @memset(directional_vectors, .none);
    return .{
        .grid_cells_per_side = grid_cells_per_side,
        .cell_unit_counter = cell_unit_counter,
        .crowd_sampling_counter = 0,
        .integration_field = integration_field,
        .directional_vectors = directional_vectors,
        .boundaries = .{ .min = math.FlatVector.zero, .max = math.FlatVector.zero },
        .queue = PriorityQueue.init(allocator, {}),
    };
}

pub fn destroy(self: *Field, allocator: std.mem.Allocator) void {
    self.queue.deinit();
    allocator.free(self.directional_vectors);
    allocator.free(self.integration_field);
    allocator.free(self.cell_unit_counter);
}

pub fn recompute(self: *Field, new_center_and_destination: math.FlatVector, map: Map) !void {
    const target = pushPositionOutOfObstacleCells(new_center_and_destination, map);
    self.boundaries = block: {
        const side_length = fp(self.grid_cells_per_side * cell_side_length);
        const half_side_length = side_length.div(fp(2));
        break :block .{
            .min = .{ .x = target.x.sub(half_side_length), .z = target.z.sub(half_side_length) },
            .max = .{ .x = target.x.add(half_side_length), .z = target.z.add(half_side_length) },
        };
    };

    @memset(self.integration_field, .{ .has_been_visited = false, .cost = max_cost });
    const target_tile = QueueItem{
        .x = self.grid_cells_per_side / 2,
        .z = self.grid_cells_per_side / 2,
        .cost = 0,
    };
    self.integration_field[self.getIndex(target_tile.x, target_tile.z)] =
        .{ .has_been_visited = true, .cost = target_tile.cost };
    try self.queue.add(target_tile);

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

    @memset(self.cell_unit_counter, 0);
}

// If the given position exists on the flow field, return a directional vector for navigating
// towards the flow fields center.
pub fn getDirection(self: Field, position: math.FlatVector, map: Map) ?math.FlatVector {
    const index = self.getIndexFromWorldPosition(position) orelse return null;
    const direction = self.directional_vectors[index];
    if (direction != .none) {
        return toDirectionVector(direction);
    }
    var iterator = GrowingRadiusIterator.create(position, &map);
    while (iterator.next()) |corrected_position| {
        const cell_index = self.getIndexFromWorldPosition(corrected_position) orelse continue;
        const corrected_direction = self.directional_vectors[cell_index];
        if (corrected_direction != .none) {
            return toDirectionVector(corrected_direction);
        }
    }
    return null;
}

/// Incorporate the given position into the next call to `recompute()` to mitigate overcrowding.
pub fn sampleCrowd(self: *Field, position: math.FlatVector) void {
    if (self.crowd_sampling_counter == 50) {
        self.crowd_sampling_counter = 0;
        if (self.getIndexFromWorldPosition(position)) |index| {
            self.cell_unit_counter[index] +|= 1;
        }
    }
    self.crowd_sampling_counter += 1;
}

pub const PrintableSnapshot = struct {
    grid_cells_per_side: usize,
    directional_vectors: std.ArrayList(Direction),

    pub fn create(allocator: std.mem.Allocator) PrintableSnapshot {
        return .{
            .grid_cells_per_side = 0,
            .directional_vectors = std.ArrayList(Direction).init(allocator),
        };
    }

    pub fn destroy(self: *PrintableSnapshot) void {
        self.directional_vectors.deinit();
    }

    /// Given buffer will be reset and overwritten.
    pub fn formatIntoBuffer(self: PrintableSnapshot, buffer: *std.ArrayList(u8)) !void {
        buffer.clearRetainingCapacity();
        for (0..self.grid_cells_per_side) |z| {
            for (0..self.grid_cells_per_side) |x| {
                try buffer.appendSlice(
                    switch (self.directional_vectors.items[getIndex(self, x, z)]) {
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
            try buffer.appendSlice("\n");
        }
    }
};

pub fn updatePrintableSnapshot(self: Field, snapshot: *PrintableSnapshot) !void {
    try snapshot.directional_vectors.resize(self.directional_vectors.len);
    @memcpy(snapshot.directional_vectors.items, self.directional_vectors);
    snapshot.grid_cells_per_side = self.grid_cells_per_side;
}

fn pushPositionOutOfObstacleCells(position: math.FlatVector, map: Map) math.FlatVector {
    if (map.geometry.getObstacleTile(position).isObstacle()) {
        var iterator = GrowingRadiusIterator.create(position, &map);
        while (iterator.next()) |corrected_position| {
            if (!map.geometry.getObstacleTile(corrected_position).isObstacle()) {
                return corrected_position;
            }
        }
    }
    return position;
}

fn getIndex(self: anytype, x: usize, z: usize) usize {
    return z * self.grid_cells_per_side + x;
}

fn getIndexFromWorldPosition(self: Field, world_position: math.FlatVector) ?usize {
    const cell_position = world_position.subtract(self.boundaries.min)
        .multiplyScalar(fp(1).div(fp(cell_side_length)));
    const x = cell_position.x.ceil().convertTo(isize);
    const z = cell_position.z.ceil().convertTo(isize);
    if (x < 0 or x >= self.grid_cells_per_side or
        z < 0 or z >= self.grid_cells_per_side)
    {
        return null;
    }
    return self.getIndex(@intCast(x), @intCast(z));
}

fn getWorldPosition(self: Field, x: usize, z: usize) math.FlatVector {
    const position = math.FlatVector{ .x = fp(x), .z = fp(z) };
    return position.multiplyScalar(fp(cell_side_length)).add(self.boundaries.min);
}

fn processCell(
    self: *Field,
    x: usize,
    z: usize,
    new_cost: CostInt,
    map: Map,
) !void {
    const index = self.getIndex(x, z);
    const cell = &self.integration_field[index];
    const should_skip = cell.has_been_visited;
    cell.has_been_visited = true;
    if (should_skip) {
        return;
    }

    const tile_type = map.geometry.getObstacleTile(self.getWorldPosition(x, z));
    const tile_base_cost: CostInt = switch (tile_type) {
        .none => 0,
        .neighbor_of_obstacle => 2,
        .obstacle_tranclucent, .obstacle_solid => max_cost,
    };
    cell.cost = tile_base_cost +| self.cell_unit_counter[index] * 5 +| new_cost;
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
                .{ .x = x, .z = z - 1, .dir = .up },
                .{ .x = x - 1, .z = z - 1, .dir = .up_left },
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

// `cells` must contain more than one item and should not start with a diagonal direction.
fn setDirectionalVector(self: *Field, x: usize, z: usize, cells: []const CellDirection) void {
    std.debug.assert(cells.len > 0);
    std.debug.assert(cells[0].x == x or cells[0].z == z);

    const index = self.getIndex(x, z);
    if (self.integration_field[index].cost == max_cost) {
        self.directional_vectors[index] = .none;
        return;
    }

    var cheapest_cell = .{ .cost = self.getCost(cells[0].x, cells[0].z), .dir = cells[0].dir };
    for (cells[1..]) |cell| {
        const cell_cost = self.getCost(cell.x, cell.z);
        if (cell_cost < cheapest_cell.cost and
            // Either not diagonal.
            ((cell.x == x or cell.z == z) or
            // Or doesn't go trough adjacent wall.
            (self.getCost(cell.x, z) != max_cost and
            self.getCost(x, cell.z) != max_cost)))
        {
            cheapest_cell = .{ .cost = cell_cost, .dir = cell.dir };
        }
    }
    self.directional_vectors[index] = cheapest_cell.dir;
}

fn getCost(self: Field, x: usize, z: usize) CostInt {
    return self.integration_field[self.getIndex(x, z)].cost;
}

const CellDirection = struct { x: usize, z: usize, dir: Direction };

fn toDirectionVector(direction: Direction) math.FlatVector {
    std.debug.assert(direction != .none);
    const sqrt1_2 = fp(std.math.sqrt1_2);
    return switch (direction) {
        .up_left => .{ .x = sqrt1_2.neg(), .z = sqrt1_2.neg() },
        .up => .{ .x = fp(0), .z = fp(-1) },
        .up_right => .{ .x = sqrt1_2, .z = sqrt1_2.neg() },
        .left => .{ .x = fp(-1), .z = fp(0) },
        .none => unreachable,
        .right => .{ .x = fp(1), .z = fp(0) },
        .down_left => .{ .x = sqrt1_2.neg(), .z = sqrt1_2 },
        .down => .{ .x = fp(0), .z = fp(1) },
        .down_right => .{ .x = sqrt1_2, .z = sqrt1_2 },
    };
}

/// Returns all positions encountered when incrementally pushing the specified position further
/// away from nearby geometry.
const GrowingRadiusIterator = struct {
    position: math.FlatVector,
    radius_factor: math.Fix32,
    map: *const Map,

    fn create(position: math.FlatVector, map: *const Map) GrowingRadiusIterator {
        return .{ .position = position, .radius_factor = fp(0.5), .map = map };
    }

    /// Returns null when there is no nearby geometry.
    fn next(self: *GrowingRadiusIterator) ?math.FlatVector {
        while (self.radius_factor.lt(fp(9))) {
            const circle = Circle{
                .position = self.position,
                .radius = fp(cell_side_length).mul(self.radius_factor),
            };
            self.radius_factor = self.radius_factor.mul(fp(2));

            const corrected_position = self.map.geometry.moveOutOfWalls(circle).position;
            if (!corrected_position.equal(circle.position)) {
                return corrected_position;
            }
        }
        return null;
    }
};
