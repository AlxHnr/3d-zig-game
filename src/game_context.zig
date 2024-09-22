const AttackingEnemyPosition = @import("enemy.zig").AttackingEnemyPosition;
const CellIndex = @import("spatial_partitioning/cell_index.zig").Index;
const Enemy = @import("enemy.zig").Enemy;
const EnemyObjectHandle = SharedContext.EnemyCollection.ObjectHandle;
const EnemyPositionGrid = @import("enemy.zig").EnemyPositionGrid;
const EnemyRenderSnapshot = @import("enemy.zig").RenderSnapshot;
const FlowField = @import("flow_field.zig");
const Gem = @import("gem.zig");
const GemObjectHandle = SharedContext.GemCollection.ObjectHandle;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const RenderLoop = @import("render_loop.zig");
const ScreenDimensions = @import("rendering.zig").ScreenDimensions;
const SharedContext = @import("shared_context.zig").SharedContext;
const ThirdPersonCamera = @import("third_person_camera.zig");
const ThreadPool = @import("thread_pool.zig").Pool;
const UnorderedCollection = @import("unordered_collection.zig").UnorderedCollection;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const enemy_presets = @import("enemy_presets.zig");
const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
const game_unit = @import("game_unit.zig");
const math = @import("math.zig");
const std = @import("std");
const textures = @import("textures.zig");

const Context = @This();

allocator: std.mem.Allocator,

tick_counter: u32,
main_character: game_unit.Player,
main_character_flow_field: FlowField,

map_file_path: []const u8,
map: Map,
shared_context: SharedContext,
spritesheet: textures.SpriteSheetTexture,

/// For objects which die at the end of each tick.
tick_lifetime_allocator: std.heap.ArenaAllocator,
/// Allocated with `tick_lifetime_allocator`.
attacking_enemy_positions_at_previous_tick: EnemyPositionGrid,
thread_pool: ThreadPool,
/// Contexts are not stored in a single contiguous array to avoid false sharing.
thread_contexts: []*ThreadContext,

/// Non-owning pointer.
render_loop: *RenderLoop,
/// Non-owning pointer.
dialog_controller: *dialog.Controller,

pub fn create(
    allocator: std.mem.Allocator,
    map_file_path: []const u8,
    /// Returned object will keep a reference to this pointer.
    render_loop: *RenderLoop,
    /// Returned object will keep a reference to this pointer.
    dialog_controller: *dialog.Controller,
) !Context {
    var flow_field = try FlowField.create(allocator, 200);
    errdefer flow_field.destroy(allocator);

    const map_file_path_buffer = try allocator.dupe(u8, map_file_path);
    errdefer allocator.free(map_file_path_buffer);

    var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
    errdefer spritesheet.destroy();

    var shared_context = SharedContext.create(allocator);
    errdefer shared_context.destroy();

    var map = try loadMap(
        allocator,
        &shared_context.object_id_generator,
        spritesheet,
        map_file_path,
    );
    errdefer map.destroy();

    for (0..2000) |_| {
        const position = math.FlatVector{
            .x = fp(shared_context.rng.random().float(f32)).mul(fp(100)).neg().sub(fp(50)),
            .z = fp(shared_context.rng.random().float(f32)).mul(fp(500)),
        };
        _ = try shared_context.enemy_collection.insert(
            Enemy.create(position, &enemy_presets.floating_eye, spritesheet),
            position,
        );
    }

    var tick_lifetime_allocator = std.heap.ArenaAllocator.init(allocator);
    errdefer tick_lifetime_allocator.deinit();

    var thread_pool = try ThreadPool.create(allocator);
    errdefer thread_pool.destroy(allocator);

    var thread_contexts = try allocator.alloc(*ThreadContext, thread_pool.countThreads());
    errdefer allocator.free(thread_contexts);
    var contexts_created: usize = 0;
    errdefer for (0..contexts_created) |index| {
        thread_contexts[index].destroy(allocator);
        allocator.destroy(thread_contexts[index]);
    };
    for (thread_contexts) |*context| {
        context.* = try allocator.create(ThreadContext);
        errdefer allocator.destroy(context.*);

        context.*.* = try ThreadContext.create(allocator);
        contexts_created += 1;
    }

    return .{
        .allocator = allocator,

        .tick_counter = 0,
        .main_character = game_unit.Player.create(
            fp(0),
            fp(0),
            spritesheet.getSpriteAspectRatio(.player_back_frame_1),
        ),
        .main_character_flow_field = flow_field,

        .map_file_path = map_file_path_buffer,
        .map = map,
        .shared_context = shared_context,
        .spritesheet = spritesheet,

        .tick_lifetime_allocator = tick_lifetime_allocator,
        .thread_pool = thread_pool,
        .attacking_enemy_positions_at_previous_tick = EnemyPositionGrid.create(
            tick_lifetime_allocator.allocator(),
        ),
        .thread_contexts = thread_contexts,
        .render_loop = render_loop,
        .dialog_controller = dialog_controller,
    };
}

pub fn destroy(self: *Context) void {
    for (self.thread_contexts) |context| {
        context.destroy(self.allocator);
        self.allocator.destroy(context);
    }
    self.allocator.free(self.thread_contexts);
    self.thread_pool.destroy(self.allocator);
    self.tick_lifetime_allocator.deinit();
    self.spritesheet.destroy();
    self.shared_context.destroy();
    self.map.destroy();
    self.allocator.free(self.map_file_path);
    self.main_character_flow_field.destroy(self.allocator);
}

pub fn markButtonAsPressed(self: *Context, button: game_unit.InputButton) void {
    self.main_character.markButtonAsPressed(button);

    switch (button) {
        .cancel => self.dialog_controller.sendCommandToCurrentDialog(.cancel),
        .confirm => self.dialog_controller.sendCommandToCurrentDialog(.confirm),
        .forwards => self.dialog_controller.sendCommandToCurrentDialog(.previous),
        .backwards => self.dialog_controller.sendCommandToCurrentDialog(.next),
        else => {},
    }
}

pub fn markButtonAsReleased(self: *Context, button: game_unit.InputButton) void {
    self.main_character.markButtonAsReleased(button);
}

pub fn handleElapsedTick(
    self: *Context,
    performance_measurements: *PerformanceMeasurements,
) !void {
    if (self.dialog_controller.hasOpenDialogs()) {
        self.main_character.markAllButtonsAsReleased();
    }
    self.main_character.applyCurrentInput(
        self.render_loop.getInterpolationIntervalUsedInLatestFrame(),
    );

    performance_measurements.begin(.logic_total);
    self.map.processElapsedTick();
    self.main_character.processElapsedTick(self.map);

    for (0..self.thread_contexts.len) |thread_id| {
        try self.thread_pool.dispatchIgnoreErrors(
            processEnemyThread,
            .{ self, thread_id, self.attacking_enemy_positions_at_previous_tick },
        );
    }
    for (0..self.thread_contexts.len) |thread_id| {
        try self.thread_pool.dispatchIgnoreErrors(processGemThread, .{ self, thread_id });
    }
    self.thread_pool.wait();
    self.mergeMeasurementsFromSlowestThread(.enemy_logic, performance_measurements);
    self.mergeMeasurementsFromSlowestThread(.gem_logic, performance_measurements);

    self.dialog_controller.processElapsedTick();
    performance_measurements.end(.logic_total);

    _ = self.tick_lifetime_allocator.reset(.retain_capacity);
    self.attacking_enemy_positions_at_previous_tick = EnemyPositionGrid.create(
        self.tick_lifetime_allocator.allocator(),
    );
    try self.thread_pool.dispatchIgnoreErrors(
        updateSpatialGridsThread,
        .{ self, &self.attacking_enemy_positions_at_previous_tick, performance_measurements },
    );
    try self.thread_pool.dispatchIgnoreErrors(
        recomputeFlowFieldThread,
        .{ self, performance_measurements },
    );
    try self.thread_pool.dispatchIgnoreErrors(
        populateRenderSnapshotsThread,
        .{ self.*, performance_measurements },
    );
    self.thread_pool.wait();

    for (self.thread_contexts) |context| {
        self.main_character.gem_count += context.gems.amount_collected;
        context.reset();
    }
    self.tick_counter += 1;
}

pub fn getMutableMap(self: *Context) *Map {
    return &self.map;
}

pub fn getMutableObjectIdGenerator(self: *Context) *ObjectIdGenerator {
    return &self.shared_context.object_id_generator;
}

pub fn getMutablePlayerFlowField(self: *Context) *FlowField {
    return &self.main_character_flow_field;
}

pub fn reloadMapFromDisk(self: *Context) !void {
    const map = try loadMap(
        self.allocator,
        &self.shared_context.object_id_generator,
        self.spritesheet,
        self.map_file_path,
    );
    self.map.destroy();
    self.map = map;
}

pub fn writeMapToDisk(self: Context) !void {
    var data = try self.map.toSerializableData(self.allocator);
    defer Map.freeSerializableData(self.allocator, &data);

    var file = try std.fs.cwd().createFile(self.map_file_path, .{});
    defer file.close();

    try std.json.stringify(data, .{ .whitespace = .indent_1 }, file.writer());
}

pub fn castRay(
    self: Context,
    mouse_x: u16,
    mouse_y: u16,
    screen_dimensions: ScreenDimensions,
) collision.Ray3d {
    const camera = self.main_character.getCamera(
        self.render_loop.getInterpolationIntervalUsedInLatestFrame(),
    );
    const ray_wall_collision = self.map.geometry
        .cast3DRayToWalls(camera.get3DRayFromTargetToSelf());
    const max_camera_distance = if (ray_wall_collision) |ray_collision|
        ray_collision.impact_point.distance_from_start_position
    else
        null;
    return camera.get3DRay(mouse_x, mouse_y, screen_dimensions, max_camera_distance);
}

pub fn increaseCameraDistance(self: *Context, value: math.Fix32) void {
    self.main_character.camera.increaseDistanceToObject(value);
}

pub fn setCameraAngleFromGround(self: *Context, angle: math.Fix32) void {
    self.main_character.camera.setAngleFromGround(angle);
}

pub fn resetCameraAngleFromGround(self: *Context) void {
    self.main_character.camera.resetAngleFromGround();
}

pub fn getCameraDirection(self: Context) math.Vector3d {
    return self.main_character
        .getCamera(self.render_loop.getInterpolationIntervalUsedInLatestFrame())
        .getDirectionToTarget();
}

fn loadMap(
    allocator: std.mem.Allocator,
    object_id_generator: *ObjectIdGenerator,
    spritesheet: textures.SpriteSheetTexture,
    file_path: []const u8,
) !Map {
    const json_string = try std.fs.cwd().readFileAlloc(allocator, file_path, 20 * 1024 * 1024);
    defer allocator.free(json_string);

    const serializable_data =
        try std.json.parseFromSlice(Map.SerializableData, allocator, json_string, .{});
    defer serializable_data.deinit();

    return Map.createFromSerializableData(
        allocator,
        object_id_generator,
        spritesheet,
        serializable_data.value,
    );
}

fn mergeMeasurementsFromSlowestThread(
    self: *Context,
    metric_type: PerformanceMeasurements.MetricType,
    out: *PerformanceMeasurements,
) void {
    var longest = self.thread_contexts[0].performance_measurements;
    for (self.thread_contexts[1..]) |context| {
        longest = longest.getLongest(context.performance_measurements, metric_type);
    }
    out.copySingleMetric(longest, metric_type);
}

fn updateSpatialGridsThread(
    self: *Context,
    attacking_enemy_positions_at_previous_tick: *EnemyPositionGrid,
    performance_measurements: *PerformanceMeasurements,
) !void {
    performance_measurements.begin(.spatial_grids);
    defer performance_measurements.end(.spatial_grids);

    var merged_removal_queue =
        try self.mergeThreadResults("enemies", "removal_queue", *EnemyObjectHandle);
    defer merged_removal_queue.destroy();
    var removal_iterator = merged_removal_queue.constIterator();
    while (removal_iterator.next()) |object_handle| {
        self.shared_context.enemy_collection.remove(object_handle);
    }

    var merged_insertion_queue = try self.mergeThreadResults("enemies", "insertion_queue", Enemy);
    defer merged_insertion_queue.destroy();
    var insertion_iterator = merged_insertion_queue.constIterator();
    while (insertion_iterator.next()) |enemy| {
        _ = try self.shared_context.enemy_collection.insert(
            enemy,
            enemy.character.moving_circle.getPosition(),
        );
    }

    var merged_attacking_positions =
        try self.mergeThreadResults("enemies", "attacking_positions", AttackingEnemyPosition);
    defer merged_attacking_positions.destroy();
    var attacking_positions = merged_attacking_positions.constIterator();
    while (attacking_positions.next()) |attacking_enemy| {
        try attacking_enemy_positions_at_previous_tick.insertIntoArea(
            attacking_enemy,
            Enemy.makeSpacingBoundaries(attacking_enemy.position)
                .getOuterBoundingBoxInGameCoordinates(),
        );
    }

    var merged_gem_removal_queue =
        try self.mergeThreadResults("gems", "removal_queue", *GemObjectHandle);
    defer merged_gem_removal_queue.destroy();
    var gem_removal_iterator = merged_gem_removal_queue.constIterator();
    while (gem_removal_iterator.next()) |object_handle| {
        self.shared_context.gem_collection.remove(object_handle);
    }
}

fn recomputeFlowFieldThread(
    self: *Context,
    performance_measurements: *PerformanceMeasurements,
) !void {
    performance_measurements.begin(.flow_field);
    defer performance_measurements.end(.flow_field);

    var merged_attacking_positions =
        try self.mergeThreadResults("enemies", "attacking_positions", AttackingEnemyPosition);
    defer merged_attacking_positions.destroy();
    var attacking_positionstor = merged_attacking_positions.constIterator();
    while (attacking_positionstor.next()) |attacking_enemy| {
        self.main_character_flow_field.sampleCrowd(attacking_enemy.position);
    }

    try self.main_character_flow_field.recompute(
        self.main_character.character.moving_circle.getPosition(),
        self.map,
    );
}

fn processEnemyThread(
    self: *Context,
    thread_id: usize,
    attacking_enemy_positions_at_previous_tick: EnemyPositionGrid,
) !void {
    const thread_context = self.thread_contexts[thread_id];
    thread_context.performance_measurements.begin(.enemy_logic);
    defer thread_context.performance_measurements.end(.enemy_logic);

    var iterator = self.shared_context.enemy_collection
        .cellGroupIteratorAdvanced(thread_id, self.thread_contexts.len - 1);
    while (iterator.next()) |cell_group| {
        try self.processEnemyCellGroup(
            cell_group,
            thread_context,
            attacking_enemy_positions_at_previous_tick,
        );
    }
}

fn processEnemyCellGroup(
    self: Context,
    cell_group: SharedContext.EnemyCollection.CellGroupIterator.CellGroup,
    thread_context: *ThreadContext,
    enemy_position_grid: EnemyPositionGrid,
) !void {
    var rng = blk: {
        // Deterministic and portably reproducible seed which is oblivious to core count
        // and thread execution order.
        var seed = std.hash.Wyhash.init(self.tick_counter);
        seed.update(std.mem.asBytes(&std.mem.nativeToLittle(i16, cell_group.cell_index.x)));
        seed.update(std.mem.asBytes(&std.mem.nativeToLittle(i16, cell_group.cell_index.z)));
        break :blk std.rand.Xoroshiro128.init(seed.final());
    };
    const tick_context = .{
        .rng = rng.random(),
        .map = &self.map,
        .main_character = &self.main_character.character,
        .main_character_flow_field = &self.main_character_flow_field,
        .attacking_enemy_positions_at_previous_tick = &enemy_position_grid,
    };

    var enemy_iterator = cell_group.cell.iterator();
    const arena_allocator = thread_context.enemies.arena_allocator.allocator();
    var cell_insertion_list = UnorderedCollection(Enemy).create(arena_allocator);
    var cell_removal_list = UnorderedCollection(*EnemyObjectHandle).create(arena_allocator);
    var cell_attacking_list = UnorderedCollection(AttackingEnemyPosition).create(arena_allocator);
    while (enemy_iterator.next()) |enemy_ptr| {
        const old_cell_index = self.shared_context.enemy_collection.getCellIndex(
            enemy_ptr.character.moving_circle.getPosition(),
        );
        enemy_ptr.processElapsedTick(tick_context);
        const new_cell_index = self.shared_context.enemy_collection.getCellIndex(
            enemy_ptr.character.moving_circle.getPosition(),
        );

        if (enemy_ptr.state == .dead) {
            try cell_removal_list.append(
                self.shared_context.enemy_collection.getObjectHandle(enemy_ptr),
            );
        } else if (new_cell_index.compare(old_cell_index) != .eq) {
            try cell_removal_list.append(
                self.shared_context.enemy_collection.getObjectHandle(enemy_ptr),
            );
            try cell_insertion_list.append(enemy_ptr.*);
        }
        if (enemy_ptr.state == .attacking) {
            try cell_attacking_list.append(enemy_ptr.makeAttackingEnemyPosition());
        }
        try thread_context.enemies.render_snapshots.append(enemy_ptr.makeRenderSnapshot());
    }

    try appendUnorderedResultsIfNeeded(
        *EnemyObjectHandle,
        cell_removal_list,
        &thread_context.enemies.removal_queue,
        cell_group,
    );
    try appendUnorderedResultsIfNeeded(
        Enemy,
        cell_insertion_list,
        &thread_context.enemies.insertion_queue,
        cell_group,
    );
    try appendUnorderedResultsIfNeeded(
        AttackingEnemyPosition,
        cell_attacking_list,
        &thread_context.enemies.attacking_positions,
        cell_group,
    );
}

fn processGemThread(self: *Context, thread_id: usize) !void {
    const thread_context = self.thread_contexts[thread_id];
    thread_context.performance_measurements.begin(.gem_logic);
    defer thread_context.performance_measurements.end(.gem_logic);

    const tick_context = .{
        .map = &self.map,
        .main_character = &self.main_character.character,
    };
    const arena_allocator = thread_context.gems.arena_allocator.allocator();

    var gems_collected: u64 = 0;
    var iterator = self.shared_context.gem_collection.cellGroupIteratorAdvanced(
        thread_id,
        self.thread_contexts.len - 1,
    );
    while (iterator.next()) |cell_group| {
        var gem_iterator = cell_group.cell.iterator();
        var removal_list = UnorderedCollection(*GemObjectHandle).create(arena_allocator);
        while (gem_iterator.next()) |gem_ptr| {
            switch (gem_ptr.processElapsedTick(tick_context)) {
                .none => {},
                .picked_up_by_player => gems_collected += 1,
                .disappeared => try removal_list.append(
                    self.shared_context.gem_collection.getObjectHandle(gem_ptr),
                ),
            }
            try thread_context.gems.render_snapshots.append(gem_ptr.makeRenderSnapshot());
        }
        try appendUnorderedResultsIfNeeded(
            *GemObjectHandle,
            removal_list,
            &thread_context.gems.removal_queue,
            cell_group,
        );
    }
    thread_context.gems.amount_collected = gems_collected;
}

fn populateRenderSnapshotsThread(
    self: Context,
    performance_measurements: *PerformanceMeasurements,
) !void {
    performance_measurements.begin(.populate_render_snapshots);
    defer performance_measurements.end(.populate_render_snapshots);

    const snapshots = self.render_loop.getLockedSnapshotsForWriting();
    defer self.render_loop.releaseSnapshotsAfterWriting();

    snapshots.previous_tick = self.tick_counter;
    snapshots.main_character = self.main_character;
    try self.map.geometry.populateRenderSnapshot(&snapshots.geometry);
    for (self.thread_contexts) |context| {
        try snapshots.enemies.appendSlice(context.enemies.render_snapshots.items);
        try snapshots.gems.appendSlice(context.gems.render_snapshots.items);
    }
}

const ThreadContext = struct {
    performance_measurements: PerformanceMeasurements,
    enemies: struct {
        arena_allocator: *std.heap.ArenaAllocator,
        insertion_queue: UnorderedCollection(CellItems(Enemy)),
        removal_queue: UnorderedCollection(CellItems(*EnemyObjectHandle)),
        attacking_positions: UnorderedCollection(CellItems(AttackingEnemyPosition)),
        render_snapshots: std.ArrayList(EnemyRenderSnapshot),
    },
    gems: struct {
        arena_allocator: *std.heap.ArenaAllocator,
        amount_collected: u64,
        removal_queue: UnorderedCollection(CellItems(*GemObjectHandle)),
        render_snapshots: std.ArrayList(Gem.RenderSnapshot),
    },

    fn create(allocator: std.mem.Allocator) !ThreadContext {
        const enemy_allocator = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(enemy_allocator);
        enemy_allocator.* = std.heap.ArenaAllocator.init(allocator);

        const gem_allocator = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(gem_allocator);
        gem_allocator.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .performance_measurements = try PerformanceMeasurements.create(),
            .enemies = .{
                .arena_allocator = enemy_allocator,
                .insertion_queue = UnorderedCollection(CellItems(Enemy))
                    .create(enemy_allocator.allocator()),
                .removal_queue = UnorderedCollection(CellItems(*EnemyObjectHandle))
                    .create(enemy_allocator.allocator()),
                .attacking_positions = UnorderedCollection(CellItems(AttackingEnemyPosition))
                    .create(enemy_allocator.allocator()),
                .render_snapshots = std.ArrayList(EnemyRenderSnapshot).init(allocator),
            },
            .gems = .{
                .arena_allocator = gem_allocator,
                .amount_collected = 0,
                .removal_queue = UnorderedCollection(CellItems(*GemObjectHandle))
                    .create(gem_allocator.allocator()),
                .render_snapshots = std.ArrayList(Gem.RenderSnapshot).init(allocator),
            },
        };
    }

    fn destroy(self: *ThreadContext, allocator: std.mem.Allocator) void {
        self.gems.render_snapshots.deinit();
        self.gems.arena_allocator.deinit();
        allocator.destroy(self.gems.arena_allocator);
        self.enemies.render_snapshots.deinit();
        self.enemies.arena_allocator.deinit();
        allocator.destroy(self.enemies.arena_allocator);
    }

    fn reset(self: *ThreadContext) void {
        self.performance_measurements.updateAverageAndReset();
        _ = self.enemies.arena_allocator.reset(.retain_capacity);
        self.enemies.insertion_queue = UnorderedCollection(CellItems(Enemy))
            .create(self.enemies.arena_allocator.allocator());
        self.enemies.removal_queue = UnorderedCollection(CellItems(*EnemyObjectHandle))
            .create(self.enemies.arena_allocator.allocator());
        self.enemies.attacking_positions = UnorderedCollection(CellItems(AttackingEnemyPosition))
            .create(self.enemies.arena_allocator.allocator());
        self.enemies.render_snapshots.clearRetainingCapacity();
        self.gems.amount_collected = 0;
        self.gems.removal_queue = UnorderedCollection(CellItems(*GemObjectHandle))
            .create(self.gems.arena_allocator.allocator());
        self.gems.render_snapshots.clearRetainingCapacity();
    }

    fn CellItems(comptime T: type) type {
        return struct {
            index: CellIndex(1), // Argument Erases `cell_side_length` from CellIndex.
            items: UnorderedCollection(T),

            const Self = @This();

            pub fn create(index: anytype, items: UnorderedCollection(T)) Self {
                return .{
                    .index = .{ .x = index.x, .z = index.z },
                    .items = items,
                };
            }

            fn lessThan(_: void, self: Self, other: Self) bool {
                return self.index.compare(other.index) == .lt;
            }
        };
    }
};

/// Merges computation results in a portably deterministic way, oblivious to core count and
/// execution order. Returned object will get invalidated by updates to the specified
/// fields/collections.
fn mergeThreadResults(
    self: Context,
    comptime toplevel_field: []const u8,
    comptime collection_field: []const u8,
    comptime Item: type,
) !MergedThreadResults(Item) {
    return MergedThreadResults(Item).create(
        self.allocator,
        self.thread_contexts,
        toplevel_field,
        collection_field,
    );
}

fn MergedThreadResults(comptime Item: type) type {
    return struct {
        /// Does not own the referenced cell items.
        merged_cells: std.ArrayList(CellItems),

        const Self = @This();
        const CellItems = ThreadContext.CellItems(Item);

        /// Merges thread computation results in a portably deterministic way, oblivious to core
        /// count and execution order. Returned object will get invalidated by updates to the
        /// specified fields/collections.
        fn create(
            allocator: std.mem.Allocator,
            thread_contexts: []const *const ThreadContext,
            comptime toplevel_field: []const u8,
            comptime collection_field: []const u8,
        ) !Self {
            var cell_count: usize = 0;
            for (thread_contexts) |context| {
                const collection = @field(@field(context, toplevel_field), collection_field);
                cell_count += collection.count();
            }

            var merged_cells = try std.ArrayList(CellItems).initCapacity(allocator, cell_count);
            errdefer merged_cells.deinit();

            for (thread_contexts) |context| {
                const collection = @field(@field(context, toplevel_field), collection_field);
                var iterator = collection.constIterator();
                while (iterator.next()) |cell_items| {
                    merged_cells.appendAssumeCapacity(cell_items.*);
                }
            }

            std.mem.sort(CellItems, merged_cells.items, {}, CellItems.lessThan);

            return .{ .merged_cells = merged_cells };
        }

        fn destroy(self: *Self) void {
            self.merged_cells.deinit();
        }

        /// Returned iterator will be invalidated by updates to the referenced fields/collections.
        fn constIterator(self: *const Self) ConstIterator {
            return .{
                .merged_results = self,
                .cell_group_iterator = null,
                .index = 0,
            };
        }

        const ConstIterator = struct {
            merged_results: *const Self,
            cell_group_iterator: ?UnorderedCollection(Item).ConstIterator,
            index: usize,

            fn next(self: *ConstIterator) ?Item {
                if (self.cell_group_iterator) |*cell_group_iterator| {
                    if (cell_group_iterator.next()) |item| {
                        return item.*;
                    }
                }
                if (self.index == self.merged_results.merged_cells.items.len) {
                    return null;
                }
                self.cell_group_iterator =
                    self.merged_results.merged_cells.items[self.index].items.constIterator();
                self.index += 1;
                return self.next();
            }
        };
    };
}

fn appendUnorderedResultsIfNeeded(
    comptime Item: type,
    cell_list: anytype,
    target_list: anytype,
    cell_group: anytype,
) !void {
    if (cell_list.count() > 0) {
        const cell_items = ThreadContext.CellItems(Item).create(cell_group.cell_index, cell_list);
        try target_list.append(cell_items);
    }
}
