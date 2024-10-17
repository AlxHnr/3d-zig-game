const CellIndex = @import("spatial_partitioning/cell_index.zig").Index;
const Enemy = @import("enemy.zig");
const FlowField = @import("flow_field.zig");
const Gem = @import("gem.zig");
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const RenderLoop = @import("render_loop.zig");
const SharedContext = @import("shared_context.zig").SharedContext;
const ThreadPool = @import("thread_pool.zig").Pool;
const ThreadSafeFixedQueue = @import("thread_safe_fixed_queue.zig").Queue;
const UnorderedCollection = @import("unordered_collection.zig").UnorderedCollection;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const enemy_grid = @import("enemy_grid.zig");
const enemy_presets = @import("enemy_presets.zig");
const fp = math.Fix32.fp;
const game_unit = @import("game_unit.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
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
billboard_animations: animation.BillboardAnimationCollection,

previous_tick_data: TickData,
current_tick_data: TickData,

thread_pool: ThreadPool,
thread_contexts: []ThreadContext,

/// Non-owning pointer.
render_loop: *RenderLoop,
render_snapshot: RenderLoop.Snapshot,
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
    var billboard_animations = try animation.BillboardAnimationCollection.create(allocator);
    errdefer billboard_animations.destroy(allocator);

    var shared_context = SharedContext.create();
    var map = try loadMap(
        allocator,
        &shared_context.object_id_generator,
        spritesheet,
        map_file_path,
    );
    errdefer map.destroy();

    var thread_pool = try ThreadPool.create(allocator);
    errdefer thread_pool.destroy(allocator);

    const thread_contexts = try allocator.alloc(ThreadContext, thread_pool.countThreads());
    errdefer allocator.free(thread_contexts);

    var contexts_initialized: usize = 0;
    errdefer for (thread_contexts[0..contexts_initialized]) |*context| {
        context.destroy(allocator);
    };
    for (thread_contexts) |*context| {
        context.* = try ThreadContext.create(allocator);
        contexts_initialized += 1;
    }

    var previous_tick_data = try TickData.create(allocator, thread_contexts.len);
    errdefer previous_tick_data.destroy(allocator);
    var current_tick_data = try TickData.create(allocator, thread_contexts.len);
    errdefer current_tick_data.destroy(allocator);

    for (0..10000) |_| {
        const position = math.FlatVector{
            .x = fp(shared_context.rng.random().float(f32)).mul(fp(400)).neg().sub(fp(50)),
            .z = fp(shared_context.rng.random().float(f32)).mul(fp(400)),
        };
        _ = try previous_tick_data.enemy_grid.insert(
            Enemy.create(position, &enemy_presets.floating_eye, spritesheet),
            position,
        );
    }
    try previous_tick_data.recomputeEnemyGridCellIndices();

    {
        var gem_collections = previous_tick_data.gem_collections.getLockedSlice();
        defer previous_tick_data.gem_collections.reclaimLockedSlice();
        for (0..10000) |counter| {
            const position = math.FlatVector{
                .x = fp(shared_context.rng.random().float(f32)).mul(fp(200)).add(fp(20)),
                .z = fp(shared_context.rng.random().float(f32)).mul(fp(-300)).sub(fp(100)),
            };
            try gem_collections[@mod(counter, gem_collections.len)]
                .append(Gem.create(position, position));
        }
    }

    var throwaway = try PerformanceMeasurements.create();
    try preallocateEnemyGrids(.{
        .in = .{
            .thread_count = thread_contexts.len,
            .enemy_grid = previous_tick_data.enemy_grid,
            .enemy_grid_cell_indices = previous_tick_data.enemy_grid_cell_indices.items,
        },
        .out = .{
            .performance_measurements = &throwaway,
            .enemy_grid = &current_tick_data.enemy_grid,
            .enemy_peer_grid = &current_tick_data.enemy_peer_grid,
        },
    });
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
        .billboard_animations = billboard_animations,

        .previous_tick_data = previous_tick_data,
        .current_tick_data = current_tick_data,
        .thread_pool = thread_pool,
        .thread_contexts = thread_contexts,

        .render_loop = render_loop,
        .render_snapshot = render_loop.makeRenderSnapshot(),
        .dialog_controller = dialog_controller,
    };
}

pub fn destroy(self: *Context) void {
    self.render_snapshot.destroy();

    for (self.thread_contexts) |*context| {
        context.destroy(self.allocator);
    }
    self.allocator.free(self.thread_contexts);
    self.thread_pool.destroy(self.allocator);
    self.current_tick_data.destroy(self.allocator);
    self.previous_tick_data.destroy(self.allocator);
    self.billboard_animations.destroy(self.allocator);
    self.spritesheet.destroy();
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

pub fn processElapsedTick(
    self: *Context,
    performance_measurements: *PerformanceMeasurements,
) !void {
    for (self.thread_contexts) |*context| {
        context.reset();
    }
    try self.preallocateBillboardData();

    if (self.dialog_controller.hasOpenDialogs()) {
        self.main_character.markAllButtonsAsReleased();
    }
    self.main_character.applyCurrentInput();
    self.map.processElapsedTick();
    self.main_character.processElapsedTick(self.map);
    self.dialog_controller.processElapsedTick();

    for (self.thread_contexts, 0..) |*thread_context, thread_id| {
        try self.thread_pool.dispatchIgnoreErrors(processEnemies, .{.{
            .in = .{
                .current_tick = self.tick_counter,
                .spritesheet = self.spritesheet,
                .map = self.map,
                .main_character = self.main_character,
                .flow_field = self.main_character_flow_field,
                .enemy_grid = self.previous_tick_data.enemy_grid,
                .enemy_grid_cell_index_iterator = EnemyGridCellIndexIterator.create(
                    self.previous_tick_data.enemy_grid_cell_indices.items,
                    thread_id,
                    self.thread_contexts.len - 1,
                ),
                .enemy_peer_grid = self.previous_tick_data.enemy_peer_grid,
            },
            .out = .{
                .performance_measurements = &thread_context.performance_measurements,
                .allocator = thread_context.enemies.arena_allocator.allocator(),
                .enemy_grid = &self.current_tick_data.enemy_grid,
                .enemy_peer_grid = &self.current_tick_data.enemy_peer_grid,
                .insertion_queue = &thread_context.enemies.insertion_queue,
                .peer_insertion_queue = &thread_context.enemies.peer_insertion_queue,
                .billboard_buffer = thread_context.enemies.billboard_buffer,
                .particle_sprite_collections = &self.current_tick_data.particle_sprite_collections,
            },
        }});
    }
    {
        const gem_collections = self.previous_tick_data.gem_collections.getLockedSlice();
        defer self.previous_tick_data.gem_collections.reclaimLockedSlice();
        for (self.thread_contexts, 0..) |*thread_context, thread_id| {
            try self.thread_pool.dispatchIgnoreErrors(processGems, .{.{
                .in = .{
                    .current_tick = self.tick_counter,
                    .spritesheet = self.spritesheet,
                    .map = self.map,
                    .main_character = self.main_character,
                    .billboard_animations = self.billboard_animations,
                    .gems = gem_collections[thread_id],
                },
                .out = .{
                    .performance_measurements = &thread_context.performance_measurements,
                    .allocator = thread_context.gems.arena_allocator.allocator(),
                    .billboard_buffer = thread_context.gems.billboard_buffer,
                    .queue = &self.current_tick_data.gem_collections,
                    .gems_collected = &thread_context.gems.amount_collected,
                },
            }});
        }

        const sprite_collections =
            self.previous_tick_data.particle_sprite_collections.getLockedSlice();
        defer self.previous_tick_data.particle_sprite_collections.reclaimLockedSlice();
        for (self.thread_contexts, 0..) |*thread_context, thread_id| {
            try self.thread_pool.dispatchIgnoreErrors(processParticleSprites, .{.{
                .in = .{
                    .current_tick = self.tick_counter,
                    .sprites = sprite_collections[thread_id].sprites,
                },
                .out = .{
                    .performance_measurements = &thread_context.performance_measurements,
                    .queue = &self.current_tick_data.particle_sprite_collections,
                    .billboard_buffer = thread_context.particle_sprite_collection.billboard_buffer,
                },
            }});
        }

        self.thread_pool.wait();
    }

    for (self.thread_contexts) |*context| {
        self.main_character.gem_count += context.gems.amount_collected;
    }
    self.render_snapshot.previous_tick = self.tick_counter;
    self.render_snapshot.main_character = self.main_character;
    try self.map.geometry.populateRenderSnapshot(&self.render_snapshot.geometry);
    self.render_loop.swapRenderSnapshot(&self.render_snapshot);

    self.mergeMeasurementsFromThreads(.enemy_logic, performance_measurements);
    self.mergeMeasurementsFromThreads(.gem_logic, performance_measurements);
    var enemy_insertion_queue =
        try self.mergeThreadResults("enemies", "insertion_queue", Enemy);
    defer enemy_insertion_queue.destroy();
    var enemy_peer_insertion_queue = try self
        .mergeThreadResults("enemies", "peer_insertion_queue", Enemy.PeerInfo);
    defer enemy_peer_insertion_queue.destroy();

    try self.updateSpatialGrids(enemy_insertion_queue);
    try self.current_tick_data.recomputeEnemyGridCellIndices();
    std.mem.swap(TickData, &self.current_tick_data, &self.previous_tick_data);
    self.current_tick_data.reset();

    try self.thread_pool.dispatchIgnoreErrors(updateEnemyPeerGrid, .{.{
        .in = .{
            .enemy_peer_insertion_queue = enemy_peer_insertion_queue,
        },
        .out = .{
            .performance_measurements = performance_measurements,
            // `Previous` is incomplete at this point, but not needed by other threads.
            .enemy_peer_grid = &self.previous_tick_data.enemy_peer_grid,
        },
    }});
    try self.thread_pool.dispatchIgnoreErrors(recomputeFlowField, .{.{
        .in = .{
            .map = self.map,
            .main_character = self.main_character,
            .enemy_grid = self.previous_tick_data.enemy_grid,
        },
        .out = .{
            .performance_measurements = performance_measurements,
            .flow_field = &self.main_character_flow_field,
        },
    }});
    try self.thread_pool.dispatchIgnoreErrors(preallocateEnemyGrids, .{.{
        .in = .{
            .thread_count = self.thread_contexts.len,
            .enemy_grid = self.previous_tick_data.enemy_grid,
            .enemy_grid_cell_indices = self.previous_tick_data.enemy_grid_cell_indices.items,
        },
        .out = .{
            .performance_measurements = performance_measurements,
            .enemy_grid = &self.current_tick_data.enemy_grid,
            .enemy_peer_grid = &self.current_tick_data.enemy_peer_grid,
        },
    }});
    self.thread_pool.wait();

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
    screen_dimensions: rendering.ScreenDimensions,
) collision.Ray3d {
    const camera = self.main_character.camera;
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
    return self.main_character.camera.getDirectionToTarget();
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

const PreallocateTickDataThreadData = struct {
    in: struct {
        thread_count: usize,
        enemy_grid: enemy_grid.Grid,
        enemy_grid_cell_indices: []const enemy_grid.CellIndex,
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        enemy_grid: *enemy_grid.Grid,
        enemy_peer_grid: *enemy_grid.PeerGrid,
    },
};

fn preallocateEnemyGrids(data: PreallocateTickDataThreadData) !void {
    data.out.performance_measurements.begin(.preallocate_tick_buffers);
    defer data.out.performance_measurements.end(.preallocate_tick_buffers);

    for (0..data.in.thread_count) |thread_id| {
        var cell_index_iterator = EnemyGridCellIndexIterator.create(
            data.in.enemy_grid_cell_indices,
            thread_id,
            data.in.thread_count - 1,
        );
        while (cell_index_iterator.next()) |cell_index| {
            const enemy_count = data.in.enemy_grid.countItemsInCell(cell_index);
            if (enemy_count == 0) {
                continue;
            }
            try data.out.enemy_grid.ensureUnusedCapacityInCell(enemy_count, cell_index);
            try data.out.enemy_peer_grid.ensureUnusedCapacityInEachCellNonInclusive(
                enemy_grid.estimated_enemies_per_cell,
                data.out.enemy_grid.getAreaOfCell(cell_index),
            );
        }
    }
}

fn preallocateBillboardData(self: *Context) !void {
    var billboard_buffer_size: usize = 0;
    for (self.thread_contexts, 0..) |*context, thread_id| {
        const stride = self.thread_contexts.len - 1;
        var cell_index_iterator = EnemyGridCellIndexIterator.create(
            self.previous_tick_data.enemy_grid_cell_indices.items,
            thread_id,
            stride,
        );
        while (cell_index_iterator.next()) |cell_index| {
            const enemy_count = self.previous_tick_data.enemy_grid.countItemsInCell(cell_index);
            context.enemies.required_billboard_buffer_size +=
                enemy_count * Enemy.required_billboard_count;
        }
        billboard_buffer_size += context.enemies.required_billboard_buffer_size;

        context.gems.required_billboard_buffer_size +=
            self.previous_tick_data.gem_collections.getLockedSlice()[thread_id].count();
        self.previous_tick_data.gem_collections.reclaimLockedSlice();
        billboard_buffer_size += context.gems.required_billboard_buffer_size;

        context.particle_sprite_collection.required_billboard_buffer_size +=
            self.previous_tick_data.particle_sprite_collections
            .getLockedSlice()[thread_id].active_sprite_count;
        self.previous_tick_data.particle_sprite_collections.reclaimLockedSlice();
        billboard_buffer_size += context.particle_sprite_collection.required_billboard_buffer_size;
    }

    try self.render_snapshot.billboard_buffer.resize(billboard_buffer_size);
    var billboard_slice = self.render_snapshot.billboard_buffer.items;
    for (self.thread_contexts) |*context| {
        context.enemies.billboard_buffer =
            billboard_slice[0..context.enemies.required_billboard_buffer_size];
        billboard_slice = billboard_slice[context.enemies.required_billboard_buffer_size..];

        context.gems.billboard_buffer =
            billboard_slice[0..context.gems.required_billboard_buffer_size];
        billboard_slice = billboard_slice[context.gems.required_billboard_buffer_size..];

        context.particle_sprite_collection.billboard_buffer =
            billboard_slice[0..context.particle_sprite_collection.required_billboard_buffer_size];
        billboard_slice =
            billboard_slice[context.particle_sprite_collection.required_billboard_buffer_size..];
    }
    std.debug.assert(billboard_slice.len == 0);
}

fn mergeMeasurementsFromThreads(
    self: *Context,
    metric_type: PerformanceMeasurements.MetricType,
    out: *PerformanceMeasurements,
) void {
    var longest = self.thread_contexts[0].performance_measurements;
    for (self.thread_contexts[1..]) |context| {
        longest = longest.merge(context.performance_measurements, metric_type);
    }
    out.copySingleMetric(longest, metric_type);
}

fn updateSpatialGrids(self: *Context, enemy_insertion_queue: MergedThreadResults(Enemy)) !void {
    var insertion_iterator = enemy_insertion_queue.constIterator();
    while (insertion_iterator.next()) |enemy| {
        const enemy_position = enemy.character.moving_circle.getPosition();
        _ = try self.current_tick_data.enemy_grid.insert(
            enemy,
            enemy_position,
        );

        const peer_info = enemy.getPeerInfo();
        try self.current_tick_data.enemy_peer_grid.insertIntoArea(
            peer_info,
            peer_info.getSpacingBoundaries().getOuterBoundingBoxInGameCoordinates(),
        );
    }
}

const UpdateEnemyPeerGridThreadData = struct {
    in: struct {
        enemy_peer_insertion_queue: MergedThreadResults(Enemy.PeerInfo),
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        enemy_peer_grid: *enemy_grid.PeerGrid,
    },
};

fn updateEnemyPeerGrid(data: UpdateEnemyPeerGridThreadData) !void {
    data.out.performance_measurements.begin(.update_enemy_peer_grid);
    defer data.out.performance_measurements.end(.update_enemy_peer_grid);

    var peer_insertion_iterator = data.in.enemy_peer_insertion_queue.constIterator();
    while (peer_insertion_iterator.next()) |peer_info| {
        try data.out.enemy_peer_grid.insertIntoArea(
            peer_info,
            peer_info.getSpacingBoundaries().getOuterBoundingBoxInGameCoordinates(),
        );
    }
}

const FlowFieldThreadData = struct {
    in: struct {
        map: Map,
        main_character: game_unit.Player,
        enemy_grid: enemy_grid.Grid,
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        flow_field: *FlowField,
    },
};

fn recomputeFlowField(data: FlowFieldThreadData) !void {
    data.out.performance_measurements.begin(.flow_field);
    defer data.out.performance_measurements.end(.flow_field);

    var iterator = data.in.enemy_grid.cellIndexIterator();
    while (iterator.next()) |cell_index| {
        var enemy_iterator = data.in.enemy_grid.constCellIterator(cell_index);
        while (enemy_iterator.next()) |enemy_ptr| {
            data.out.flow_field.sampleCrowd(enemy_ptr.character.moving_circle.getPosition());
        }
    }

    try data.out.flow_field.recompute(
        data.in.main_character.character.moving_circle.getPosition(),
        data.in.map,
    );
}

const EnemyThreadData = struct {
    in: struct {
        current_tick: u32,
        spritesheet: textures.SpriteSheetTexture,
        map: Map,
        main_character: game_unit.Player,
        flow_field: FlowField,
        enemy_grid: enemy_grid.Grid,
        enemy_grid_cell_index_iterator: EnemyGridCellIndexIterator,
        enemy_peer_grid: enemy_grid.PeerGrid,
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        allocator: std.mem.Allocator,
        enemy_grid: *enemy_grid.Grid,
        enemy_peer_grid: *enemy_grid.PeerGrid,
        insertion_queue: *UnorderedCollection(CellItems(Enemy)),
        peer_insertion_queue: *UnorderedCollection(CellItems(Enemy.PeerInfo)),
        billboard_buffer: []rendering.SpriteData,
        particle_sprite_collections: *ThreadSafeFixedQueue(ParticleSpriteCollection),
    },
};

fn processEnemies(data: EnemyThreadData) !void {
    data.out.performance_measurements.begin(.enemy_logic);
    defer data.out.performance_measurements.end(.enemy_logic);

    var billboard_buffer = data.out.billboard_buffer;
    var iterator = data.in.enemy_grid_cell_index_iterator;
    while (iterator.next()) |cell_index| {
        var rng = blk: {
            // Deterministic and portably reproducible seed which is oblivious to core count
            // and thread execution order.
            var seed = std.hash.Wyhash.init(data.in.current_tick);
            seed.update(std.mem.asBytes(&std.mem.nativeToLittle(i16, cell_index.x)));
            seed.update(std.mem.asBytes(&std.mem.nativeToLittle(i16, cell_index.z)));
            break :blk std.rand.Xoroshiro128.init(seed.final());
        };
        const tick_context = .{
            .rng = rng.random(),
            .map = &data.in.map,
            .main_character = &data.in.main_character.character,
            .main_character_flow_field = &data.in.flow_field,
            .peer_grid = &data.in.enemy_peer_grid,
        };

        // Must be recreated for each cell group because these lists will stay referenced by
        // data.out.insertion_queue.
        var enemy_insertion_list = UnorderedCollection(Enemy).create(data.out.allocator);
        var peer_insertion_list = UnorderedCollection(Enemy.PeerInfo).create(data.out.allocator);

        var enemy_iterator = data.in.enemy_grid.constCellIterator(cell_index);
        while (enemy_iterator.next()) |enemy_ptr| {
            var enemy = enemy_ptr.*;
            enemy.processElapsedTick(tick_context);
            const new_cell_index = enemy_grid.CellIndex
                .fromPosition(enemy.character.moving_circle.getPosition());
            const enemy_outer_boundaries =
                enemy.getPeerInfo().getSpacingBoundaries().getOuterBoundingBoxInGameCoordinates();

            if (enemy.state == .dead) {
                // Do nothing.
            } else if (new_cell_index.compare(cell_index) != .eq) {
                try enemy_insertion_list.append(enemy);
            } else {
                data.out.enemy_grid.insertIntoCellAssumeCapacity(enemy, cell_index);
                const bordering_with_other_thread_cells = enemy_grid.CellRange
                    .fromAABB(enemy_outer_boundaries)
                    .countCoveredCells() > 1;
                if (!bordering_with_other_thread_cells) {
                    data.out.enemy_peer_grid.insertIntoAreaAssumeCapacity(
                        enemy.getPeerInfo(),
                        enemy_outer_boundaries,
                    );
                } else {
                    try peer_insertion_list.append(enemy.getPeerInfo());
                }
            }
            enemy.populateBillboardData(
                data.in.spritesheet,
                data.in.current_tick,
                billboard_buffer,
            );
            billboard_buffer = billboard_buffer[Enemy.required_billboard_count..];
        }

        try appendUnorderedResultsIfNeeded(
            Enemy,
            enemy_insertion_list,
            data.out.insertion_queue,
            cell_index,
        );
        try appendUnorderedResultsIfNeeded(
            Enemy.PeerInfo,
            peer_insertion_list,
            data.out.peer_insertion_queue,
            cell_index,
        );
    }
}

const GemThreadData = struct {
    in: struct {
        current_tick: u32,
        spritesheet: textures.SpriteSheetTexture,
        map: Map,
        main_character: game_unit.Player,
        billboard_animations: animation.BillboardAnimationCollection,
        gems: UnorderedCollection(Gem),
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        allocator: std.mem.Allocator,
        billboard_buffer: []rendering.SpriteData,
        queue: *ThreadSafeFixedQueue(UnorderedCollection(Gem)),
        gems_collected: *u64,
    },
};

fn processGems(data: GemThreadData) !void {
    data.out.performance_measurements.begin(.gem_logic);
    defer data.out.performance_measurements.end(.gem_logic);

    var collection = data.out.queue.pop();
    defer data.out.queue.pushAssumeCapacity(collection);

    var gems_collected: u64 = 0;
    var billboard_buffer = data.out.billboard_buffer;
    const tick_context = .{
        .map = &data.in.map,
        .main_character = &data.in.main_character.character,
    };

    var iterator = data.in.gems.constIterator();
    while (iterator.next()) |input_gem| {
        var gem = input_gem.*;
        switch (gem.processElapsedTick(tick_context)) {
            .none => {},
            .picked_up_by_player => gems_collected += 1,
            .disappeared => continue,
        }
        try collection.append(gem);
        billboard_buffer[0] = gem.makeBillboardData(
            data.in.spritesheet,
            data.in.billboard_animations,
            data.in.current_tick,
        );
        billboard_buffer = billboard_buffer[1..];
    }
    data.out.gems_collected.* = gems_collected;
}

const ParticleSpriteThreadData = struct {
    in: struct {
        current_tick: u32,
        sprites: UnorderedCollection(ParticleSpriteCollection.Sprite),
    },
    out: struct {
        performance_measurements: *PerformanceMeasurements,
        queue: *ThreadSafeFixedQueue(ParticleSpriteCollection),
        billboard_buffer: []rendering.SpriteData,
    },
};

fn processParticleSprites(data: ParticleSpriteThreadData) !void {
    data.out.performance_measurements.begin(.particle_sprite_logic);
    defer data.out.performance_measurements.end(.particle_sprite_logic);

    var collection = data.out.queue.pop();
    defer data.out.queue.pushAssumeCapacity(collection);

    var billboard_buffer = data.out.billboard_buffer;
    var iterator = data.in.sprites.constIterator();
    while (iterator.next()) |sprite| {
        if (sprite.sprite_data.animation_start_tick < data.in.current_tick) {
            billboard_buffer[0] = sprite.sprite_data;
            billboard_buffer = billboard_buffer[1..];
        }
        if (data.in.current_tick < sprite.last_tick) {
            try collection.insertSprite(sprite.*, data.in.current_tick);
        }
    }
}

/// Contains short-lived objects.
const TickData = struct {
    /// For preallocating enemy grids at the start of each tick.
    arena_allocator: *std.heap.ArenaAllocator,
    enemy_grid: enemy_grid.Grid,
    enemy_grid_cell_indices: std.ArrayList(enemy_grid.CellIndex),
    enemy_peer_grid: enemy_grid.PeerGrid,

    /// Each thread can pop a collection from the queue to emit particle sprites. Thread execution
    /// order is not relevant.
    particle_sprite_collections: ThreadSafeFixedQueue(ParticleSpriteCollection),
    /// Each thread can pop a collection from the queue to emit gems. Thread execution order is not
    /// relevant.
    gem_collections: ThreadSafeFixedQueue(UnorderedCollection(Gem)),

    fn create(allocator: std.mem.Allocator, thread_count: usize) !TickData {
        const arena_allocator = try createArenaAllocatorOnHeap(allocator);
        errdefer destroyArenaAllocatorOnHeap(allocator, arena_allocator);

        var particle_sprite_collections =
            try ThreadSafeFixedQueue(ParticleSpriteCollection).create(allocator, thread_count);
        errdefer particle_sprite_collections.destroy();
        errdefer {
            for (particle_sprite_collections.getLockedSlice()) |*collection| {
                collection.destroy();
            }
            particle_sprite_collections.reclaimLockedSlice();
        }
        for (0..thread_count) |_| {
            particle_sprite_collections.pushAssumeCapacity(
                ParticleSpriteCollection.create(allocator),
            );
        }

        var gem_collections =
            try ThreadSafeFixedQueue(UnorderedCollection(Gem)).create(allocator, thread_count);
        errdefer gem_collections.destroy();
        errdefer {
            for (gem_collections.getLockedSlice()) |*collection| {
                collection.destroy();
            }
            gem_collections.reclaimLockedSlice();
        }
        for (0..thread_count) |_| {
            gem_collections.pushAssumeCapacity(UnorderedCollection(Gem).create(allocator));
        }

        return .{
            .arena_allocator = arena_allocator,
            .enemy_grid = enemy_grid.Grid.create(arena_allocator.allocator()),
            .enemy_grid_cell_indices = std.ArrayList(enemy_grid.CellIndex)
                .init(arena_allocator.allocator()),
            .enemy_peer_grid = enemy_grid.PeerGrid.create(arena_allocator.allocator()),

            .particle_sprite_collections = particle_sprite_collections,
            .gem_collections = gem_collections,
        };
    }

    fn destroy(self: *TickData, allocator: std.mem.Allocator) void {
        for (self.gem_collections.getLockedSlice()) |*collection| {
            collection.destroy();
        }
        self.gem_collections.reclaimLockedSlice();
        self.gem_collections.destroy();

        for (self.particle_sprite_collections.getLockedSlice()) |*collection| {
            collection.destroy();
        }
        self.particle_sprite_collections.reclaimLockedSlice();
        self.particle_sprite_collections.destroy();

        destroyArenaAllocatorOnHeap(allocator, self.arena_allocator);
    }

    fn reset(self: *TickData) void {
        _ = self.arena_allocator.reset(.retain_capacity);
        self.enemy_grid = enemy_grid.Grid.create(self.arena_allocator.allocator());
        self.enemy_grid_cell_indices = std.ArrayList(enemy_grid.CellIndex)
            .init(self.arena_allocator.allocator());
        self.enemy_peer_grid = enemy_grid.PeerGrid.create(self.arena_allocator.allocator());

        for (self.particle_sprite_collections.getLockedSlice()) |*collection| {
            collection.reset();
        }
        self.particle_sprite_collections.reclaimLockedSlice();

        for (self.gem_collections.getLockedSlice()) |*collection| {
            collection.resetPreservingCapacity();
        }
        self.gem_collections.reclaimLockedSlice();
    }

    fn recomputeEnemyGridCellIndices(self: *TickData) !void {
        self.enemy_grid_cell_indices.clearRetainingCapacity();
        try self.enemy_grid_cell_indices.ensureUnusedCapacity(self.enemy_grid.countCells());

        var iterator = self.enemy_grid.cellIndexIterator();
        while (iterator.next()) |cell_index| {
            self.enemy_grid_cell_indices.appendAssumeCapacity(cell_index);
        }
        std.mem.sort(enemy_grid.CellIndex, self.enemy_grid_cell_indices.items, {}, lessThan);
    }

    fn lessThan(_: void, a: enemy_grid.CellIndex, b: enemy_grid.CellIndex) bool {
        return a.compare(b) == .lt;
    }
};

const EnemyGridCellIndexIterator = struct {
    indices: []const enemy_grid.CellIndex,
    index: usize,
    step: usize,

    /// Returned iterator keeps a reference to the given indices and will be invalidated if they
    /// change.
    fn create(
        indices: []const enemy_grid.CellIndex,
        /// Cells to skip from the first cell in this collection.
        offset_from_start: usize,
        /// Number cells to skip before advancing to the next cell.
        stride: usize,
    ) EnemyGridCellIndexIterator {
        return .{
            .indices = indices,
            .index = offset_from_start,
            .step = stride + 1,
        };
    }

    pub fn next(self: *EnemyGridCellIndexIterator) ?enemy_grid.CellIndex {
        if (self.index < self.indices.len) {
            const cell_index = self.indices[self.index];
            self.index += self.step;
            return cell_index;
        }
        return null;
    }
};

/// Thread-specific data which gets wiped every tick.
const ThreadContext = struct {
    performance_measurements: PerformanceMeasurements,
    enemies: struct {
        arena_allocator: *std.heap.ArenaAllocator,
        insertion_queue: UnorderedCollection(CellItems(Enemy)),
        peer_insertion_queue: UnorderedCollection(CellItems(Enemy.PeerInfo)),
        required_billboard_buffer_size: usize,
        billboard_buffer: []rendering.SpriteData,
    } align(std.atomic.cache_line),
    gems: struct {
        arena_allocator: *std.heap.ArenaAllocator,
        amount_collected: u64,
        required_billboard_buffer_size: usize,
        billboard_buffer: []rendering.SpriteData,
    } align(std.atomic.cache_line),
    particle_sprite_collection: struct {
        required_billboard_buffer_size: usize,
        billboard_buffer: []rendering.SpriteData,
    } align(std.atomic.cache_line),

    fn create(allocator: std.mem.Allocator) !ThreadContext {
        const measurements = try PerformanceMeasurements.create();

        var enemy_allocator = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(enemy_allocator);
        enemy_allocator.* = std.heap.ArenaAllocator.init(allocator);
        errdefer enemy_allocator.deinit();

        var gem_allocator = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(gem_allocator);
        gem_allocator.* = std.heap.ArenaAllocator.init(allocator);
        errdefer gem_allocator.deinit();

        return .{
            .performance_measurements = measurements,
            .enemies = .{
                .arena_allocator = enemy_allocator,
                .insertion_queue = UnorderedCollection(CellItems(Enemy))
                    .create(enemy_allocator.allocator()),
                .peer_insertion_queue = UnorderedCollection(CellItems(Enemy.PeerInfo))
                    .create(enemy_allocator.allocator()),
                .required_billboard_buffer_size = 0,
                .billboard_buffer = &.{},
            },
            .gems = .{
                .arena_allocator = gem_allocator,
                .amount_collected = 0,
                .required_billboard_buffer_size = 0,
                .billboard_buffer = &.{},
            },
            .particle_sprite_collection = .{
                .required_billboard_buffer_size = 0,
                .billboard_buffer = &.{},
            },
        };
    }

    fn destroy(self: *ThreadContext, allocator: std.mem.Allocator) void {
        self.gems.arena_allocator.deinit();
        allocator.destroy(self.gems.arena_allocator);
        self.enemies.arena_allocator.deinit();
        allocator.destroy(self.enemies.arena_allocator);
    }

    fn reset(self: *ThreadContext) void {
        self.performance_measurements.updateAverageAndReset();
        _ = self.enemies.arena_allocator.reset(.retain_capacity);
        self.enemies.insertion_queue = UnorderedCollection(CellItems(Enemy))
            .create(self.enemies.arena_allocator.allocator());
        self.enemies.peer_insertion_queue = UnorderedCollection(CellItems(Enemy.PeerInfo))
            .create(self.enemies.arena_allocator.allocator());
        self.enemies.required_billboard_buffer_size = 0;
        self.enemies.billboard_buffer = &.{};
        self.gems.amount_collected = 0;
        self.gems.required_billboard_buffer_size = 0;
        self.gems.billboard_buffer = &.{};
        self.particle_sprite_collection.required_billboard_buffer_size = 0;
        self.particle_sprite_collection.billboard_buffer = &.{};
    }
};

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
        merged_cells: std.ArrayList(CellItems(Item)),

        const Self = @This();

        /// Merges thread computation results in a portably deterministic way, oblivious to core
        /// count and execution order. Returned object will get invalidated by updates to the
        /// specified fields/collections.
        fn create(
            allocator: std.mem.Allocator,
            thread_contexts: []const ThreadContext,
            comptime toplevel_field: []const u8,
            comptime collection_field: []const u8,
        ) !Self {
            var cell_count: usize = 0;
            for (thread_contexts) |context| {
                const collection = @field(@field(context, toplevel_field), collection_field);
                cell_count += collection.count();
            }

            var merged_cells = try std.ArrayList(CellItems(Item))
                .initCapacity(allocator, cell_count);
            errdefer merged_cells.deinit();

            for (thread_contexts) |context| {
                const collection = @field(@field(context, toplevel_field), collection_field);
                var iterator = collection.constIterator();
                while (iterator.next()) |cell_items| {
                    merged_cells.appendAssumeCapacity(cell_items.*);
                }
            }

            std.mem.sort(CellItems(Item), merged_cells.items, {}, CellItems(Item).lessThan);

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

// Appends a shallow copy into the given target list, which will keep references to the given cell
// lists content.
fn appendUnorderedResultsIfNeeded(
    comptime Item: type,
    cell_list: anytype,
    target_list: anytype,
    cell_index: anytype,
) !void {
    if (cell_list.count() > 0) {
        const cell_items = CellItems(Item).create(cell_index, cell_list);
        try target_list.append(cell_items);
    }
}

fn createArenaAllocatorOnHeap(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const result = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(result);

    result.* = std.heap.ArenaAllocator.init(allocator);
    errdefer result.deinit();

    return result;
}

fn destroyArenaAllocatorOnHeap(
    allocator: std.mem.Allocator,
    arena_allocator: *std.heap.ArenaAllocator,
) void {
    arena_allocator.deinit();
    allocator.destroy(arena_allocator);
}

const ParticleSpriteCollection = struct {
    sprites: UnorderedCollection(Sprite),
    /// Amount of sprites, which animations have already started.
    active_sprite_count: usize,

    const Sprite = struct {
        sprite_data: rendering.SpriteData,
        last_tick: u32,
    };

    fn create(allocator: std.mem.Allocator) ParticleSpriteCollection {
        return .{
            .sprites = UnorderedCollection(Sprite).create(allocator),
            .active_sprite_count = 0,
        };
    }

    fn destroy(self: *ParticleSpriteCollection) void {
        self.sprites.destroy();
    }

    fn insert(
        self: *ParticleSpriteCollection,
        sprite_data: rendering.SpriteData,
        current_tick: u32,
        lifetime_in_ticks: u32,
    ) !void {
        try self.insertSprite(.{
            .sprite_data = sprite_data,
            .last_tick = current_tick + lifetime_in_ticks,
        }, current_tick);
    }

    fn insertSprite(self: *ParticleSpriteCollection, sprite: Sprite, current_tick: u32) !void {
        try self.sprites.append(sprite);
        self.active_sprite_count += @intFromBool(
            sprite.sprite_data.animation_start_tick <= current_tick,
        );
    }

    fn reset(self: *ParticleSpriteCollection) void {
        self.sprites.resetPreservingCapacity();
        self.active_sprite_count = 0;
    }
};
