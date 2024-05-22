const Color = @import("util.zig").Color;
const DialogController = @import("dialog.zig").Controller;
const EditModeState = @import("edit_mode.zig").State;
const EnemySnapshot = @import("enemy.zig").RenderSnapshot;
const GemSnapshot = @import("gem.zig").RenderSnapshot;
const GeometryRenderer = @import("map/geometry.zig").Renderer;
const GeometrySnapshot = @import("map/geometry.zig").RenderSnapshot;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const Player = @import("game_unit.zig").Player;
const PrerenderedEnemyNames = @import("enemy.zig").PrerenderedNames;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const fp = @import("math.zig").Fix32.fp;
const gl = @import("gl");
const rendering = @import("rendering.zig");
const sdl = @import("sdl.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const textures = @import("textures.zig");
const ui = @import("ui.zig");

const Loop = @This();

allocator: std.mem.Allocator,
keep_running: std.atomic.Value(bool),
current: Snapshots,
/// Will be atomically swapped with `current`.
secondary: Snapshots,
secondary_is_populated: bool,
mutex: std.Thread.Mutex,
condition: std.Thread.Condition,

/// Other rendering data which is unrelated to the actual game.
extra_data: struct {
    mutex: std.Thread.Mutex,
    screen_dimensions: ScreenDimensions,
    screen_dimensions_changed: bool,
    edit_mode_state: EditModeState,
    player_is_on_obstacle_tile: bool,
},

/// Value between 0 and 1.
interpolation_interval_used_in_latest_frame: std.atomic.Value(f32),

pub fn create(
    allocator: std.mem.Allocator,
    screen_dimensions: ScreenDimensions,
    edit_mode_state: EditModeState,
) Loop {
    return .{
        .allocator = allocator,
        .keep_running = std.atomic.Value(bool).init(true),
        .current = Snapshots.create(allocator),
        .secondary = Snapshots.create(allocator),
        .secondary_is_populated = false,
        .mutex = .{},
        .condition = .{},
        .extra_data = .{
            .mutex = .{},
            .screen_dimensions = screen_dimensions,
            .screen_dimensions_changed = false,
            .edit_mode_state = edit_mode_state,
            .player_is_on_obstacle_tile = false,
        },
        .interpolation_interval_used_in_latest_frame = std.atomic.Value(f32).init(0),
    };
}

pub fn destroy(self: *Loop) void {
    self.secondary.destroy();
    self.current.destroy();
}

pub fn run(
    self: *Loop,
    window: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,
    dialog_controller: *DialogController,
) !void {
    try sdl.makeGLContextCurrent(window, gl_context);
    var timer = try simulation.TickTimer.start(simulation.tickrate);
    var performance_measurements = try PerformanceMeasurements.create();
    var frame_counter: usize = 0;
    const refresh_rate = getRefreshRate() orelse 60;

    var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
    defer spritesheet.destroy();

    var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
    defer tileable_textures.destroy();

    var geometry_renderer = try GeometryRenderer.create();
    defer geometry_renderer.destroy();

    var billboard_renderer = try rendering.BillboardRenderer.create();
    defer billboard_renderer.destroy();

    var sprite_renderer = try rendering.SpriteRenderer.create();
    defer sprite_renderer.destroy();

    var billboard_buffer = std.ArrayList(rendering.SpriteData).init(self.allocator);
    defer billboard_buffer.deinit();

    var prerendered_enemy_names = try PrerenderedEnemyNames.create(self.allocator, spritesheet);
    defer prerendered_enemy_names.destroy(self.allocator);

    while (self.keep_running.load(.unordered)) {
        performance_measurements.begin(.frame_total);

        const lap_result = timer.lap();
        if (lap_result.elapsed_ticks > 0) {
            performance_measurements.begin(.frame_wait_for_data);
            self.swapSnapshots();
            performance_measurements.end(.frame_wait_for_data);
        }

        gl.clearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);

        gl.enable(gl.DEPTH_TEST);
        const camera = self.current.main_character.getCamera(lap_result.next_tick_progress);

        billboard_buffer.clearRetainingCapacity();
        performance_measurements.begin(.aggregate_enemy_billboards);
        for (self.current.enemies.items) |snapshot| {
            try snapshot.appendBillboardData(
                spritesheet,
                prerendered_enemy_names,
                camera,
                lap_result.next_tick_progress,
                &billboard_buffer,
            );
        }
        performance_measurements.end(.aggregate_enemy_billboards);

        performance_measurements.begin(.aggregate_gem_billboards);
        for (self.current.gems.items) |snapshot| {
            try billboard_buffer.append(
                snapshot.makeBillboardData(
                    spritesheet,
                    lap_result.next_tick_progress.convertTo(f32),
                ),
            );
        }
        performance_measurements.end(.aggregate_gem_billboards);

        try billboard_buffer.append(self.current.main_character.getBillboardData(
            spritesheet,
            lap_result.next_tick_progress,
        ));
        billboard_renderer.uploadBillboards(billboard_buffer.items);

        const extra_data = blk: {
            self.extra_data.mutex.lock();
            defer self.extra_data.mutex.unlock();

            const copy = self.extra_data;
            self.extra_data.screen_dimensions_changed = false;
            break :blk copy;
        };

        if (extra_data.screen_dimensions_changed) {
            gl.viewport(
                0,
                0,
                extra_data.screen_dimensions.width,
                extra_data.screen_dimensions.height,
            );
        }

        performance_measurements.begin(.render_level_geometry);
        const ray_wall_collision = self.current.geometry
            .cast3DRayToSolidWalls(camera.get3DRayFromTargetToSelf());
        const max_camera_distance = if (ray_wall_collision) |impact_point|
            impact_point.distance_from_start_position
        else
            null;

        const vp_matrix = camera.getViewProjectionMatrix(
            extra_data.screen_dimensions,
            max_camera_distance,
        );
        geometry_renderer.uploadRenderSnapshot(self.current.geometry);
        geometry_renderer.render(
            vp_matrix,
            extra_data.screen_dimensions,
            camera.getDirectionToTarget(),
            tileable_textures,
            spritesheet,
        );
        performance_measurements.end(.render_level_geometry);

        performance_measurements.begin(.draw_billboards);
        billboard_renderer.render(
            vp_matrix,
            extra_data.screen_dimensions,
            camera.getDirectionToTarget().toVector3dF32(),
            spritesheet.id,
        );
        performance_measurements.end(.draw_billboards);

        performance_measurements.begin(.hud);
        gl.disable(gl.DEPTH_TEST);
        try renderHud(
            self.allocator,
            &sprite_renderer,
            extra_data.screen_dimensions,
            spritesheet,
            &billboard_buffer,
            self.current.main_character.gem_count,
            self.current.main_character.character.health.current,
        );
        try dialog_controller.render(
            extra_data.screen_dimensions,
            lap_result.next_tick_progress.convertTo(f32),
        );
        try renderEditMode(
            extra_data.edit_mode_state,
            &sprite_renderer,
            extra_data.screen_dimensions,
            spritesheet,
            &billboard_buffer,
            extra_data.player_is_on_obstacle_tile,
        );
        performance_measurements.end(.hud);
        performance_measurements.end(.frame_total);

        frame_counter += 1;
        if (@mod(frame_counter, refresh_rate * 3) == 0) {
            performance_measurements.updateAverageAndReset();
            performance_measurements.printFrameInfo();
        }

        self.interpolation_interval_used_in_latest_frame
            .store(lap_result.next_tick_progress.convertTo(f32), .unordered);
        sdl.SDL_GL_SwapWindow(window);
    }
}

pub fn getInterpolationIntervalUsedInLatestFrame(self: Loop) f32 {
    return self.interpolation_interval_used_in_latest_frame.load(.unordered);
}

pub fn sendStop(self: *Loop) void {
    self.keep_running.store(false, .unordered);

    self.mutex.lock();
    self.condition.signal();
    self.mutex.unlock();
}

pub fn sendExtraData(
    self: *Loop,
    screen_dimensions: ScreenDimensions,
    edit_mode_state: EditModeState,
    player_is_on_obstacle_tile: bool,
) void {
    self.extra_data.mutex.lock();
    defer self.extra_data.mutex.unlock();

    if (self.extra_data.screen_dimensions.width != screen_dimensions.width or
        self.extra_data.screen_dimensions.height != screen_dimensions.height)
    {
        self.extra_data.screen_dimensions_changed = true;
    }
    self.extra_data.screen_dimensions = screen_dimensions;
    self.extra_data.edit_mode_state = edit_mode_state;
    self.extra_data.player_is_on_obstacle_tile = player_is_on_obstacle_tile;
}

/// Return a snapshot object to be populated with the latest game state. Must be followed by
/// `unlockSnapshotsAfterWriting()`.
pub fn getLockedSnapshotsForWriting(self: *Loop) *Snapshots {
    self.mutex.lock();
    self.secondary.reset();
    return &self.secondary;
}

/// Must be preceded by `getLockedSnapshotsForWriting()`.
pub fn releaseSnapshotsAfterWriting(self: *Loop) void {
    self.secondary_is_populated = true;
    self.condition.signal();
    self.mutex.unlock();
}

pub const Snapshots = struct {
    main_character: Player,
    geometry: GeometrySnapshot,
    enemies: std.ArrayList(EnemySnapshot),
    gems: std.ArrayList(GemSnapshot),

    fn create(allocator: std.mem.Allocator) Snapshots {
        return .{
            .main_character = Player.create(fp(0), fp(0), fp(1)),
            .geometry = GeometrySnapshot.create(allocator),
            .enemies = std.ArrayList(EnemySnapshot).init(allocator),
            .gems = std.ArrayList(GemSnapshot).init(allocator),
        };
    }

    fn destroy(self: *Snapshots) void {
        self.gems.deinit();
        self.enemies.deinit();
        self.geometry.destroy();
    }

    fn reset(self: *Snapshots) void {
        self.enemies.clearRetainingCapacity();
        self.gems.clearRetainingCapacity();
    }
};

fn getRefreshRate() ?u32 {
    var display_mode: sdl.SDL_DisplayMode = undefined;
    if (sdl.SDL_GetCurrentDisplayMode(0, &display_mode) != 0) {
        std.log.warn("unable to retrieve display refresh rate: {s}", .{
            sdl.SDL_GetError(),
        });
        return null;
    }
    if (display_mode.refresh_rate == 0) {
        return null;
    }
    return @intCast(display_mode.refresh_rate);
}

fn swapSnapshots(self: *Loop) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.keep_running.load(.unordered) and !self.secondary_is_populated) {
        self.condition.wait(&self.mutex);
    }
    if (self.secondary_is_populated) {
        std.mem.swap(Snapshots, &self.current, &self.secondary);
        self.secondary_is_populated = false;
    }
}

fn renderHud(
    allocator: std.mem.Allocator,
    renderer: *rendering.SpriteRenderer,
    screen_dimensions: ScreenDimensions,
    spritesheet: textures.SpriteSheetTexture,
    sprite_buffer: *std.ArrayList(rendering.SpriteData),
    gem_count: u64,
    player_health: u32,
) !void {
    var segments = try allocator.alloc(text_rendering.TextSegment, 1);
    defer allocator.free(segments);
    var buffer: [64]u8 = undefined;
    segments[0] = .{
        .color = Color.fromRgb8(0, 0, 0),
        .text = try std.fmt.bufPrint(&buffer, "Gems: {}\nHP: {}", .{ gem_count, player_health }),
    };

    var widget = try allocator.create(ui.Widget);
    defer allocator.destroy(widget);
    widget.* = .{ .text = ui.Text.wrap(segments, &spritesheet, 3) };

    try sprite_buffer.resize(widget.getSpriteCount());
    widget.populateSpriteData(
        0,
        screen_dimensions.height - widget.getDimensionsInPixels().height,
        sprite_buffer.items,
    );
    renderer.uploadSprites(sprite_buffer.items);
    renderer.render(screen_dimensions, spritesheet.id);
}

fn renderEditMode(
    state: EditModeState,
    renderer: *rendering.SpriteRenderer,
    screen_dimensions: ScreenDimensions,
    spritesheet: textures.SpriteSheetTexture,
    sprite_buffer: *std.ArrayList(rendering.SpriteData),
    player_is_on_obstacle_tile: bool,
) !void {
    var text_buffer: [64]u8 = undefined;
    const description = try state.describe(&text_buffer);

    const text_color = Color.fromRgb8(0, 0, 0);
    const segments = [_]text_rendering.TextSegment{
        .{ .color = text_color, .text = description[0] },
        .{ .color = text_color, .text = "\n" },
        .{ .color = text_color, .text = description[1] },
        .{ .color = text_color, .text = if (player_is_on_obstacle_tile)
            "\nFlowField: Unreachable"
        else
            "" },
    };

    try sprite_buffer.resize(text_rendering.getSpriteCount(&segments));
    text_rendering.populateSpriteData(
        &segments,
        0,
        0,
        spritesheet.getFontSizeMultiple(2),
        spritesheet,
        sprite_buffer.items,
    );
    renderer.uploadSprites(sprite_buffer.items);
    renderer.render(screen_dimensions, spritesheet.id);
}
