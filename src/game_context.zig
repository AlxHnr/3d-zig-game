const Enemy = @import("enemy.zig").Enemy;
const EnemyPositionGrid = @import("enemy.zig").EnemyPositionGrid;
const FlowField = @import("flow_field.zig").Field;
const Hud = @import("hud.zig").Hud;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SharedContext = @import("shared_context.zig").SharedContext;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const enemy_presets = @import("enemy_presets.zig");
const game_unit = @import("game_unit.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const textures = @import("textures.zig");

pub const Context = struct {
    tick_timer: simulation.TickTimer,
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

    /// For objects which die at the end of each tick.
    tick_lifetime_allocator: std.heap.ArenaAllocator,

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

        var shared_context = try SharedContext.create(allocator);
        errdefer shared_context.destroy();

        var map = try loadMap(allocator, &shared_context.object_id_generator, map_file_path);
        errdefer map.destroy();

        var counter: usize = 0;
        while (counter < 10000) : (counter += 1) {
            try shared_context.enemies.append(
                Enemy.create(
                    .{
                        .x = -shared_context.rng.random().float(f32) * 100 - 50,
                        .z = shared_context.rng.random().float(f32) * 500,
                    },
                    &enemy_presets.floating_eye,
                    spritesheet,
                ),
            );
        }

        var tick_lifetime_allocator = std.heap.ArenaAllocator.init(allocator);
        errdefer tick_lifetime_allocator.deinit();

        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        var hud = try Hud.create();
        errdefer hud.destroy(allocator);

        return .{
            .tick_timer = try simulation.TickTimer.start(simulation.tickrate),
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

            .tick_lifetime_allocator = tick_lifetime_allocator,

            .billboard_renderer = billboard_renderer,
            .billboard_buffer = &.{},

            .hud = hud,
        };
    }

    pub fn destroy(self: *Context, allocator: std.mem.Allocator) void {
        self.hud.destroy(allocator);
        allocator.free(self.billboard_buffer);
        self.billboard_renderer.destroy();
        self.tick_lifetime_allocator.deinit();
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

        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            self.map.processElapsedTick();
            self.main_character.processElapsedTick(self.map, &self.shared_context);
            try self.main_character_flow_field.recompute(
                self.main_character.character.moving_circle.getPosition(),
                self.map,
            );
            self.shared_context.gem_collection.processElapsedTick();

            _ = self.tick_lifetime_allocator.reset(.retain_capacity);
            var attacking_enemy_positions_at_previous_tick =
                EnemyPositionGrid.create(self.tick_lifetime_allocator.allocator());
            for (self.shared_context.previous_tick_attacking_enemies.items) |attacking_enemy| {
                try attacking_enemy_positions_at_previous_tick.insertIntoArea(
                    attacking_enemy,
                    Enemy.makeSpacingBoundaries(attacking_enemy.position)
                        .getOuterBoundingBoxInGameCoordinates(),
                );
            }
            self.shared_context.previous_tick_attacking_enemies.clearRetainingCapacity();

            const tick_context = .{
                .rng = self.shared_context.rng.random(),
                .map = &self.map,
                .main_character = &self.main_character.character,
                .main_character_flow_field = &self.main_character_flow_field,
                .attacking_enemy_positions_at_previous_tick = &attacking_enemy_positions_at_previous_tick,
            };
            for (self.shared_context.enemies.items) |*enemy| {
                enemy.processElapsedTick(tick_context);
                if (enemy.state == .attacking) {
                    try self.shared_context.previous_tick_attacking_enemies.append(
                        enemy.makeAttackingEnemyPosition(),
                    );
                }
            }

            self.shared_context.dialog_controller.processElapsedTick();
            if (self.frame_timer.read() > max_frame_time) {
                self.interval_between_previous_and_current_tick = 1;
                break;
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
        try self.map.prepareRender(self.spritesheet);
        const camera = self.main_character
            .getCamera(self.interval_between_previous_and_current_tick);

        var billboards_to_render: usize = 0;

        const gems_to_render = self.shared_context.gem_collection.getBillboardCount();
        billboards_to_render += gems_to_render;
        for (self.shared_context.enemies.items) |*enemy| {
            enemy.prepareRender(camera, self.interval_between_previous_and_current_tick);
            billboards_to_render += enemy.getBillboardCount();
        }
        billboards_to_render += 1; // Player sprite.

        if (self.billboard_buffer.len < billboards_to_render) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, billboards_to_render);
        }

        self.shared_context.gem_collection.populateBillboardData(
            self.billboard_buffer[0..gems_to_render],
            self.spritesheet,
            self.interval_between_previous_and_current_tick,
        );
        var start: usize = gems_to_render;
        var end: usize = gems_to_render;
        for (self.shared_context.enemies.items) |enemy| {
            start = end;
            end += enemy.getBillboardCount();
            enemy.populateBillboardData(self.spritesheet, self.billboard_buffer[start..end]);
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
        ) == .obstacle;
    }

    pub fn reloadMapFromDisk(self: *Context, allocator: std.mem.Allocator) !void {
        const map =
            try loadMap(allocator, &self.shared_context.object_id_generator, self.map_file_path);
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
            serializable_data.value,
        );
    }
};
