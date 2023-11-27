const AttackingEnemyPosition = @import("enemy.zig").AttackingEnemyPosition;
const Enemy = @import("enemy.zig").Enemy;
const EnemyPositionGrid = @import("enemy.zig").EnemyPositionGrid;
const EnemyRenderSnapshot = @import("enemy.zig").RenderSnapshot;
const FlowField = @import("flow_field.zig").Field;
const Gem = @import("gem.zig");
const Hud = @import("hud.zig").Hud;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const PrerenderedEnemyNames = @import("enemy.zig").PrerenderedNames;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SharedContext = @import("shared_context.zig").SharedContext;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const ThreadPool = @import("thread_pool.zig").Pool;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const enemy_presets = @import("enemy_presets.zig");
const game_unit = @import("game_unit.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const textures = @import("textures.zig");

pub const Context = struct {
    tick_timer: simulation.TickTimer,
    tick_counter: u32,
    interval_between_previous_and_current_tick: f32,
    frame_timer: std.time.Timer,
    main_character: game_unit.Player,
    main_character_flow_field: FlowField,
    /// Prevents walls from covering the player.
    max_camera_distance: ?f32,

    map_file_path: []const u8,
    map: Map,
    shared_context: SharedContext,
    tileable_textures: textures.TileableArrayTexture,
    spritesheet: textures.SpriteSheetTexture,
    prerendered_enemy_names: PrerenderedEnemyNames,

    /// For objects which die at the end of each tick.
    tick_lifetime_allocator: std.heap.ArenaAllocator,
    thread_pool: ThreadPool,
    /// Contexts are not stored in a single contiguous array to avoid false sharing.
    thread_contexts: []*ThreadContext,
    performance_measurements: PerformanceMeasurements,

    billboard_renderer: rendering.BillboardRenderer,
    billboard_buffer: []rendering.SpriteData,

    hud: Hud,

    /// Prevents the engine from hanging if ticks take too long and catching up becomes impossible.
    const max_frame_time = std.time.ns_per_s / 10;

    pub fn create(allocator: std.mem.Allocator, map_file_path: []const u8) !Context {
        var flow_field = try FlowField.create(allocator, 100);
        errdefer flow_field.destroy(allocator);

        const map_file_path_buffer = try allocator.dupe(u8, map_file_path);
        errdefer allocator.free(map_file_path_buffer);

        var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
        errdefer tileable_textures.destroy();

        var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
        errdefer spritesheet.destroy();

        var prerendered_enemy_names = try PrerenderedEnemyNames.create(allocator, spritesheet);
        errdefer prerendered_enemy_names.destroy(allocator);

        var shared_context = try SharedContext.create(allocator);
        errdefer shared_context.destroy();

        var map = try loadMap(
            allocator,
            &shared_context.object_id_generator,
            spritesheet,
            map_file_path,
        );
        errdefer map.destroy();

        var counter: usize = 0;
        while (counter < 10000) : (counter += 1) {
            const position = .{
                .x = -shared_context.rng.random().float(f32) * 100 - 50,
                .z = shared_context.rng.random().float(f32) * 500,
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
            thread_contexts[index].destroy();
            allocator.destroy(thread_contexts[index]);
        };
        for (thread_contexts) |*context| {
            context.* = try allocator.create(ThreadContext);
            errdefer allocator.destroy(context.*);

            context.*.* = try ThreadContext.create(allocator);
            contexts_created += 1;
        }

        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        var hud = try Hud.create();
        errdefer hud.destroy(allocator);

        return .{
            .tick_timer = try simulation.TickTimer.start(simulation.tickrate),
            .tick_counter = 0,
            .interval_between_previous_and_current_tick = 1,
            .frame_timer = try std.time.Timer.start(),
            .main_character = game_unit.Player.create(
                0,
                0,
                spritesheet.getSpriteAspectRatio(.player_back_frame_1),
            ),
            .main_character_flow_field = flow_field,
            .max_camera_distance = null,

            .map_file_path = map_file_path_buffer,
            .map = map,
            .shared_context = shared_context,
            .tileable_textures = tileable_textures,
            .spritesheet = spritesheet,
            .prerendered_enemy_names = prerendered_enemy_names,

            .tick_lifetime_allocator = tick_lifetime_allocator,
            .thread_pool = thread_pool,
            .thread_contexts = thread_contexts,
            .performance_measurements = try PerformanceMeasurements.create(),

            .billboard_renderer = billboard_renderer,
            .billboard_buffer = &.{},

            .hud = hud,
        };
    }

    pub fn destroy(self: *Context, allocator: std.mem.Allocator) void {
        self.hud.destroy(allocator);
        allocator.free(self.billboard_buffer);
        self.billboard_renderer.destroy();
        for (self.thread_contexts) |context| {
            context.destroy();
            allocator.destroy(context);
        }
        allocator.free(self.thread_contexts);
        self.thread_pool.destroy(allocator);
        self.tick_lifetime_allocator.deinit();
        self.prerendered_enemy_names.destroy(allocator);
        self.spritesheet.destroy();
        self.tileable_textures.destroy();
        self.shared_context.destroy();
        self.map.destroy();
        allocator.free(self.map_file_path);
        self.main_character_flow_field.destroy(allocator);
    }

    pub fn markButtonAsPressed(self: *Context, button: game_unit.InputButton) void {
        self.main_character.markButtonAsPressed(button);

        var dialog_controller = &self.shared_context.dialog_controller;
        switch (button) {
            .cancel => dialog_controller.sendCommandToCurrentDialog(.cancel),
            .confirm => dialog_controller.sendCommandToCurrentDialog(.confirm),
            .forwards => dialog_controller.sendCommandToCurrentDialog(.previous),
            .backwards => dialog_controller.sendCommandToCurrentDialog(.next),
            else => {},
        }
    }

    pub fn markButtonAsReleased(self: *Context, button: game_unit.InputButton) void {
        self.main_character.markButtonAsReleased(button);
    }

    pub fn handleElapsedFrame(self: *Context) !void {
        self.frame_timer.reset();
        if (self.shared_context.dialog_controller.hasOpenDialogs()) {
            self.main_character.markAllButtonsAsReleased();
        }
        self.main_character.applyCurrentInput(self.interval_between_previous_and_current_tick);

        const lap_result = self.tick_timer.lap();
        self.interval_between_previous_and_current_tick = lap_result.next_tick_progress;

        const end_tick = self.tick_counter + lap_result.elapsed_ticks;
        while (self.tick_counter < end_tick and
            self.frame_timer.read() < max_frame_time) : (self.tick_counter += 1)
        {
            self.performance_measurements.begin(.tick);
            self.map.processElapsedTick();
            self.main_character.processElapsedTick(self.map);

            _ = self.tick_lifetime_allocator.reset(.retain_capacity);
            var attacking_enemy_positions_at_previous_tick =
                EnemyPositionGrid.create(self.tick_lifetime_allocator.allocator());
            self.performance_measurements.begin(.thread_aggregation_flow_field);
            try self.thread_pool.dispatchIgnoreErrors(
                updateSpatialGrids,
                .{ self, &attacking_enemy_positions_at_previous_tick },
            );
            try self.thread_pool.dispatchIgnoreErrors(recomputeFlowFieldThread, .{self});
            self.thread_pool.wait();
            self.performance_measurements.end(.thread_aggregation_flow_field);
            for (self.thread_contexts) |context| {
                self.main_character.gem_count += context.gems.amount_collected;
                context.reset();
            }

            for (0..self.thread_contexts.len) |thread_id| {
                try self.thread_pool.dispatchIgnoreErrors(
                    processEnemyThread,
                    .{ self, thread_id, attacking_enemy_positions_at_previous_tick },
                );
            }
            for (0..self.thread_contexts.len) |thread_id| {
                try self.thread_pool.dispatchIgnoreErrors(processGemThread, .{ self, thread_id });
            }
            self.thread_pool.wait();

            var slowest_thread = self.thread_contexts[0].performance_measurements;
            for (self.thread_contexts[1..]) |context| {
                slowest_thread = slowest_thread
                    .getLongest(context.performance_measurements, .enemy_logic);
            }
            self.performance_measurements.copySingleMetric(slowest_thread, .enemy_logic);
            for (self.thread_contexts) |context| {
                slowest_thread = slowest_thread
                    .getLongest(context.performance_measurements, .gem_logic);
            }
            self.performance_measurements.copySingleMetric(slowest_thread, .gem_logic);

            self.shared_context.dialog_controller.processElapsedTick();

            self.performance_measurements.end(.tick);
            if (@mod(self.tick_counter, simulation.tickrate) == 0) {
                self.performance_measurements.updateAverageAndReset();
                self.performance_measurements.printLogInfo();
            }
        }

        const ray_wall_collision = self.map.geometry.cast3DRayToWalls(
            self.main_character.getCamera(self.interval_between_previous_and_current_tick)
                .get3DRayFromTargetToSelf(),
            true,
        );
        self.max_camera_distance = if (ray_wall_collision) |ray_collision|
            ray_collision.impact_point.distance_from_start_position
        else
            null;
    }

    pub fn render(
        self: *Context,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
    ) !void {
        self.performance_measurements.begin(.render);
        const camera = self.main_character
            .getCamera(self.interval_between_previous_and_current_tick);

        var billboards_to_render: usize = 1; // Player sprite.
        for (self.thread_contexts) |context| {
            for (context.enemies.render_snapshots.items) |snapshot| {
                billboards_to_render += snapshot.getBillboardCount(
                    self.prerendered_enemy_names,
                    camera,
                    self.interval_between_previous_and_current_tick,
                );
            }
            billboards_to_render += context.gems.render_snapshots.items.len;
        }
        if (self.billboard_buffer.len < billboards_to_render) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, billboards_to_render);
        }

        self.performance_measurements.begin(.render_enemies);
        var start: usize = 0;
        var end: usize = 0;
        for (self.thread_contexts) |context| {
            for (context.enemies.render_snapshots.items) |snapshot| {
                start = end;
                end += snapshot.getBillboardCount(
                    self.prerendered_enemy_names,
                    camera,
                    self.interval_between_previous_and_current_tick,
                );
                snapshot.populateBillboardData(
                    self.spritesheet,
                    self.prerendered_enemy_names,
                    camera,
                    self.interval_between_previous_and_current_tick,
                    self.billboard_buffer[start..end],
                );
            }
        }
        self.performance_measurements.end(.render_enemies);

        for (self.thread_contexts) |context| {
            for (context.gems.render_snapshots.items) |snapshot| {
                start = end;
                end += 1;
                self.billboard_buffer[start] = snapshot.makeBillboardData(
                    self.spritesheet,
                    self.interval_between_previous_and_current_tick,
                );
            }
        }

        self.billboard_buffer[end] = self.main_character.getBillboardData(
            self.spritesheet,
            self.interval_between_previous_and_current_tick,
        );
        self.billboard_renderer.uploadBillboards(self.billboard_buffer[0..billboards_to_render]);

        const vp_matrix = camera.getViewProjectionMatrix(
            screen_dimensions,
            self.max_camera_distance,
        );
        self.map.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            self.tileable_textures,
            self.spritesheet,
        );
        self.billboard_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            self.spritesheet.id,
        );
        self.performance_measurements.end(.render);
    }

    pub fn renderHud(
        self: *Context,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
    ) !void {
        try self.hud.render(
            allocator,
            screen_dimensions,
            self.spritesheet,
            self.main_character.gem_count,
            self.main_character.character.health.current,
        );
        try self.shared_context.dialog_controller.render(
            screen_dimensions,
            self.interval_between_previous_and_current_tick,
        );
    }

    pub fn getMutableMap(self: *Context) *Map {
        return &self.map;
    }

    pub fn getMutableObjectIdGenerator(self: *Context) *ObjectIdGenerator {
        return &self.shared_context.object_id_generator;
    }

    pub fn playerIsOnFlowFieldObstacleTile(self: Context) bool {
        return self.map.geometry.getObstacleTile(
            self.main_character.character.moving_circle.getPosition(),
        ).isObstacle();
    }

    pub fn reloadMapFromDisk(self: *Context, allocator: std.mem.Allocator) !void {
        const map = try loadMap(
            allocator,
            &self.shared_context.object_id_generator,
            self.spritesheet,
            self.map_file_path,
        );
        self.map.destroy();
        self.map = map;
    }

    pub fn writeMapToDisk(self: Context, allocator: std.mem.Allocator) !void {
        var data = try self.map.toSerializableData(allocator);
        defer Map.freeSerializableData(allocator, &data);

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
        return self.main_character
            .getCamera(self.interval_between_previous_and_current_tick)
            .get3DRay(mouse_x, mouse_y, screen_dimensions, self.max_camera_distance);
    }

    pub fn increaseCameraDistance(self: *Context, value: f32) void {
        self.main_character.camera.increaseDistanceToObject(value);
    }

    pub fn setCameraAngleFromGround(self: *Context, angle: f32) void {
        self.main_character.camera.setAngleFromGround(angle);
    }

    pub fn resetCameraAngleFromGround(self: *Context) void {
        self.main_character.camera.resetAngleFromGround();
    }

    pub fn getCameraDirection(self: Context) math.Vector3d {
        return self.main_character
            .getCamera(self.interval_between_previous_and_current_tick)
            .getDirectionToTarget();
    }

    fn loadMap(
        allocator: std.mem.Allocator,
        object_id_generator: *ObjectIdGenerator,
        spritesheet: textures.SpriteSheetTexture,
        file_path: []const u8,
    ) !Map {
        var json_string = try std.fs.cwd().readFileAlloc(allocator, file_path, 20 * 1024 * 1024);
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

    fn updateSpatialGrids(
        self: *Context,
        attacking_enemy_positions_at_previous_tick: *EnemyPositionGrid,
    ) !void {
        self.performance_measurements.begin(.thread_aggregation);
        defer self.performance_measurements.end(.thread_aggregation);

        for (self.thread_contexts) |context| {
            for (context.enemies.removal_queue.items) |object_handle| {
                self.shared_context.enemy_collection.remove(object_handle);
            }
            for (context.enemies.insertion_queue.items) |enemy| {
                _ = try self.shared_context.enemy_collection.insert(
                    enemy,
                    enemy.character.moving_circle.getPosition(),
                );
            }
            for (context.enemies.attacking_positions.items) |attacking_enemy| {
                try attacking_enemy_positions_at_previous_tick.insertIntoArea(
                    attacking_enemy,
                    Enemy.makeSpacingBoundaries(attacking_enemy.position)
                        .getOuterBoundingBoxInGameCoordinates(),
                );
            }
            for (context.gems.removal_queue.items) |object_handle| {
                self.shared_context.gem_collection.remove(object_handle);
            }
        }
    }

    fn recomputeFlowFieldThread(self: *Context) !void {
        self.performance_measurements.begin(.flow_field);
        defer self.performance_measurements.end(.flow_field);

        for (self.thread_contexts) |context| {
            for (context.enemies.attacking_positions.items) |attacking_enemy| {
                self.main_character_flow_field.sampleCrowd(attacking_enemy.position);
            }
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
            seed.update(std.mem.asBytes(&cell_group.cell_index.x));
            seed.update(std.mem.asBytes(&cell_group.cell_index.z));
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
        while (enemy_iterator.next()) |enemy_ptr| {
            const old_cell_index = self.shared_context.enemy_collection.getCellIndex(
                enemy_ptr.character.moving_circle.getPosition(),
            );
            enemy_ptr.processElapsedTick(tick_context);
            const new_cell_index = self.shared_context.enemy_collection.getCellIndex(
                enemy_ptr.character.moving_circle.getPosition(),
            );

            if (enemy_ptr.state == .dead) {
                try thread_context.enemies.removal_queue.append(
                    self.shared_context.enemy_collection.getObjectHandle(enemy_ptr),
                );
            } else if (new_cell_index.compare(old_cell_index) != .eq) {
                try thread_context.enemies.removal_queue.append(
                    self.shared_context.enemy_collection.getObjectHandle(enemy_ptr),
                );
                try thread_context.enemies.insertion_queue.append(enemy_ptr.*);
            }
            if (enemy_ptr.state == .attacking) {
                try thread_context.enemies.attacking_positions.append(
                    enemy_ptr.makeAttackingEnemyPosition(),
                );
            }
            try thread_context.enemies.render_snapshots.append(enemy_ptr.makeRenderSnapshot());
        }
    }

    fn processGemThread(self: *Context, thread_id: usize) !void {
        const thread_context = self.thread_contexts[thread_id];
        thread_context.performance_measurements.begin(.gem_logic);
        defer thread_context.performance_measurements.end(.gem_logic);

        const tick_context = .{
            .map = &self.map,
            .main_character = &self.main_character.character,
        };

        var gems_collected: u64 = 0;
        var iterator = self.shared_context.gem_collection.cellGroupIteratorAdvanced(
            thread_id,
            self.thread_contexts.len - 1,
        );
        while (iterator.next()) |cell_group| {
            var gem_iterator = cell_group.cell.iterator();
            while (gem_iterator.next()) |gem_ptr| {
                switch (gem_ptr.processElapsedTick(tick_context)) {
                    .none => {},
                    .picked_up_by_player => gems_collected += 1,
                    .disappeared => try thread_context.gems.removal_queue.append(
                        self.shared_context.gem_collection.getObjectHandle(gem_ptr),
                    ),
                }
                try thread_context.gems.render_snapshots.append(gem_ptr.makeRenderSnapshot());
            }
        }
        thread_context.gems.amount_collected = gems_collected;
    }
};

const ThreadContext = struct {
    performance_measurements: PerformanceMeasurements,
    enemies: struct {
        insertion_queue: std.ArrayList(Enemy),
        removal_queue: std.ArrayList(*EnemyObjectHandle),
        attacking_positions: std.ArrayList(AttackingEnemyPosition),
        render_snapshots: std.ArrayList(EnemyRenderSnapshot),
    },
    gems: struct {
        amount_collected: u64,
        removal_queue: std.ArrayList(*GemObjectHandle),
        render_snapshots: std.ArrayList(Gem.RenderSnapshot),
    },

    const EnemyObjectHandle = SharedContext.EnemyCollection.ObjectHandle;
    const GemObjectHandle = SharedContext.GemCollection.ObjectHandle;

    fn create(allocator: std.mem.Allocator) !ThreadContext {
        return .{
            .performance_measurements = try PerformanceMeasurements.create(),
            .enemies = .{
                .insertion_queue = std.ArrayList(Enemy).init(allocator),
                .removal_queue = std.ArrayList(*EnemyObjectHandle).init(allocator),
                .attacking_positions = std.ArrayList(AttackingEnemyPosition).init(allocator),
                .render_snapshots = std.ArrayList(EnemyRenderSnapshot).init(allocator),
            },
            .gems = .{
                .amount_collected = 0,
                .removal_queue = std.ArrayList(*GemObjectHandle).init(allocator),
                .render_snapshots = std.ArrayList(Gem.RenderSnapshot).init(allocator),
            },
        };
    }

    fn destroy(self: *ThreadContext) void {
        self.gems.render_snapshots.deinit();
        self.gems.removal_queue.deinit();
        self.enemies.render_snapshots.deinit();
        self.enemies.attacking_positions.deinit();
        self.enemies.removal_queue.deinit();
        self.enemies.insertion_queue.deinit();
    }

    fn reset(self: *ThreadContext) void {
        self.performance_measurements.updateAverageAndReset();
        self.enemies.insertion_queue.clearRetainingCapacity();
        self.enemies.removal_queue.clearRetainingCapacity();
        self.enemies.attacking_positions.clearRetainingCapacity();
        self.enemies.render_snapshots.clearRetainingCapacity();
        self.gems.amount_collected = 0;
        self.gems.removal_queue.clearRetainingCapacity();
        self.gems.render_snapshots.clearRetainingCapacity();
    }
};
