const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const game_unit = @import("game_unit.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const std = @import("std");
const textures = @import("textures.zig");

const Hud = @import("hud.zig").Hud;
const Map = @import("map/map.zig").Map;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const TickTimer = @import("util.zig").TickTimer;

pub const Context = struct {
    tick_timer: TickTimer,
    interval_between_previous_and_current_tick: f32,
    main_character: game_unit.Player,
    /// Prevents walls from covering the player.
    max_camera_distance: ?f32,

    map_file_path: []const u8,
    map: Map,
    gem_collection: gems.Collection,
    tileable_textures: textures.TileableArrayTexture,
    spritesheet: textures.SpriteSheetTexture,

    billboard_renderer: rendering.BillboardRenderer,
    billboard_buffer: []rendering.SpriteData,

    hud: Hud,
    dialog_controller: dialog.Controller,

    pub fn create(allocator: std.mem.Allocator, map_file_path: []const u8) !Context {
        const map_file_path_buffer = try allocator.dupe(u8, map_file_path);
        errdefer allocator.free(map_file_path_buffer);

        var map = try loadMap(allocator, map_file_path);
        errdefer map.destroy();

        var gem_collection = gems.Collection.create(allocator);
        errdefer gem_collection.destroy();

        var rng = std.rand.DefaultPrng.init(0);
        var counter: usize = 0;
        while (counter < 3000) : (counter += 1) {
            try gem_collection.addGem(.{
                .x = rng.random().float(f32) * 100 + 100,
                .z = rng.random().float(f32) * 180 - 280,
            });
        }

        var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
        errdefer tileable_textures.destroy();

        var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
        errdefer spritesheet.destroy();

        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        var hud = try Hud.create();
        errdefer hud.destroy(allocator);

        var dialog_controller = try dialog.Controller.create(allocator);
        errdefer dialog_controller.destroy();

        return .{
            .tick_timer = try TickTimer.start(60),
            .interval_between_previous_and_current_tick = 1,
            .main_character = game_unit.Player.create(
                0,
                0,
                0,
                spritesheet.getSpriteAspectRatio(.player_back_frame_1),
            ),
            .max_camera_distance = null,

            .map_file_path = map_file_path_buffer,
            .map = map,
            .gem_collection = gem_collection,
            .tileable_textures = tileable_textures,
            .spritesheet = spritesheet,

            .billboard_renderer = billboard_renderer,
            .billboard_buffer = &.{},

            .hud = hud,
            .dialog_controller = dialog_controller,
        };
    }

    pub fn destroy(self: *Context, allocator: std.mem.Allocator) void {
        self.dialog_controller.destroy();
        self.hud.destroy(allocator);
        allocator.free(self.billboard_buffer);
        self.billboard_renderer.destroy();
        self.spritesheet.destroy();
        self.tileable_textures.destroy();
        self.gem_collection.destroy();
        self.map.destroy();
        allocator.free(self.map_file_path);
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

    pub fn handleElapsedFrame(self: *Context) void {
        if (self.dialog_controller.hasOpenDialogs()) {
            self.main_character.markAllButtonsAsReleased();
        }
        self.main_character.applyCurrentInput(self.interval_between_previous_and_current_tick);

        const lap_result = self.tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            self.map.processElapsedTick();
            self.main_character.processElapsedTick(self.map, &self.gem_collection);
            self.gem_collection.processElapsedTick();
            self.dialog_controller.processElapsedTick();
        }
        self.interval_between_previous_and_current_tick = lap_result.next_tick_progress;

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

        const billboards_to_render = self.gem_collection.getBillboardCount();
        if (self.billboard_buffer.len < billboards_to_render) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, billboards_to_render);
        }
        self.gem_collection.populateBillboardData(
            self.billboard_buffer,
            self.spritesheet,
            &.{self.main_character
                .getLerpedCollisionObject(self.interval_between_previous_and_current_tick)},
            self.interval_between_previous_and_current_tick,
        );
        self.billboard_renderer.uploadBillboards(self.billboard_buffer[0..billboards_to_render]);

        const camera = self.main_character
            .getCamera(self.interval_between_previous_and_current_tick);
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

        const player_billboard_data = [_]rendering.SpriteData{
            self.main_character.getBillboardData(
                self.spritesheet,
                self.interval_between_previous_and_current_tick,
            ),
        };
        self.billboard_renderer.uploadBillboards(player_billboard_data[0..]);
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
        );
        try self.dialog_controller.render(
            screen_dimensions,
            self.interval_between_previous_and_current_tick,
        );
    }

    pub fn hasOpenDialogs(self: Context) bool {
        return self.dialog_controller.hasOpenDialogs();
    }

    pub fn getMutableMap(self: *Context) *Map {
        return &self.map;
    }

    pub fn reloadMapFromDisk(self: *Context, allocator: std.mem.Allocator) !void {
        const map = try loadMap(allocator, self.map_file_path);
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
        self.main_character.state_at_next_tick.camera.increaseDistanceToObject(value);
    }

    pub fn setCameraAngleFromGround(self: *Context, angle: f32) void {
        self.main_character.state_at_next_tick.camera.setAngleFromGround(angle);
    }

    pub fn resetCameraAngleFromGround(self: *Context) void {
        self.main_character.state_at_next_tick.camera.resetAngleFromGround();
    }

    pub fn getCameraDirection(self: Context) math.Vector3d {
        return self.main_character
            .getCamera(self.interval_between_previous_and_current_tick)
            .getDirectionToTarget();
    }

    fn loadMap(allocator: std.mem.Allocator, file_path: []const u8) !Map {
        var json_string = try std.fs.cwd().readFileAlloc(allocator, file_path, 20 * 1024 * 1024);
        defer allocator.free(json_string);

        const serializable_data =
            try std.json.parseFromSlice(Map.SerializableData, allocator, json_string, .{});
        defer serializable_data.deinit();

        return Map.createFromSerializableData(allocator, serializable_data.value);
    }
};
