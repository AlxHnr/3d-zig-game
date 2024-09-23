const Color = rendering.Color;
const DialogController = @import("dialog.zig").Controller;
const EditModeState = @import("edit_mode.zig").State;
const Fix32 = @import("math.zig").Fix32;
const FlowField = @import("flow_field.zig");
const GeometryRenderer = @import("map/geometry.zig").Renderer;
const GeometrySnapshot = @import("map/geometry.zig").RenderSnapshot;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const Player = @import("game_unit.zig").Player;
const ScreenDimensions = rendering.ScreenDimensions;
const UboBindingPointCounter = @import("ubo_binding_point_counter.zig");
const animation = @import("animation.zig");
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
const Fix32Int = @TypeOf(fp(0).internal);

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
    /// Set if the flow field info should be rendered.
    flow_field_font_size: ?u16,
    printable_flow_field_snapshot: FlowField.PrintableSnapshot,
},

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
            .flow_field_font_size = null,
            .printable_flow_field_snapshot = FlowField.PrintableSnapshot.create(allocator),
        },
    };
}

pub fn destroy(self: *Loop) void {
    self.extra_data.printable_flow_field_snapshot.destroy();
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
    var binding_point_counter = UboBindingPointCounter.create();
    const refresh_rate = getRefreshRate() orelse 60;

    var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
    defer spritesheet.destroy();

    var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
    defer tileable_textures.destroy();

    var geometry_renderer = try GeometryRenderer.create(&binding_point_counter);
    defer geometry_renderer.destroy();

    var billboard_animations = try animation.BillboardAnimationCollection.create(self.allocator);
    defer billboard_animations.destroy(self.allocator);

    var billboard_renderer = try rendering.BillboardRenderer.create(&binding_point_counter);
    defer billboard_renderer.destroy();
    billboard_renderer.uploadAnimations(billboard_animations.animation_collection.*);

    var player_renderer = try rendering.BillboardRenderer.create(&binding_point_counter);
    defer player_renderer.destroy();
    player_renderer.uploadAnimations(billboard_animations.animation_collection.*);

    var sprite_renderer = try rendering.SpriteRenderer.create(&binding_point_counter);
    defer sprite_renderer.destroy();

    var billboard_buffer = std.ArrayList(rendering.SpriteData).init(self.allocator);
    defer billboard_buffer.deinit();

    var flow_field_text_buffer = std.ArrayList(u8).init(self.allocator);
    defer flow_field_text_buffer.deinit();

    while (self.keep_running.load(.unordered)) {
        performance_measurements.begin(.frame_total);
        const lap_result = timer.lap();

        const extra_data = blk: {
            self.extra_data.mutex.lock();
            defer self.extra_data.mutex.unlock();

            if (self.extra_data.flow_field_font_size != null) {
                try self.extra_data.printable_flow_field_snapshot.formatIntoBuffer(
                    &flow_field_text_buffer,
                );
            }

            const copy = self.extra_data;
            self.extra_data.screen_dimensions_changed = false;
            break :blk copy;
        };
        if (extra_data.screen_dimensions_changed) {
            gl.viewport(
                0,
                0,
                extra_data.screen_dimensions.w,
                extra_data.screen_dimensions.h,
            );
        }

        if (lap_result.elapsed_ticks > 0) {
            performance_measurements.begin(.frame_wait_for_data);
            self.swapSnapshots();
            performance_measurements.end(.frame_wait_for_data);

            performance_measurements.begin(.aggregate_enemy_billboards);
            billboard_buffer.clearRetainingCapacity();
            try appendRenderHudSpriteData(
                self.allocator,
                spritesheet,
                extra_data.screen_dimensions,
                self.current.main_character.gem_count,
                self.current.main_character.character.health.current,
                &billboard_buffer,
            );
            try dialog_controller.appendSpriteData(extra_data.screen_dimensions, &billboard_buffer);
            try appendEditModeSpritedData(extra_data.edit_mode_state, spritesheet, &billboard_buffer);
            if (extra_data.flow_field_font_size) |font_size| {
                try appendFlowFieldSpritedData(
                    extra_data.screen_dimensions,
                    spritesheet,
                    flow_field_text_buffer.items,
                    font_size,
                    &billboard_buffer,
                );
            }
            performance_measurements.end(.aggregate_enemy_billboards);

            performance_measurements.begin(.aggregate_gem_billboards);
            geometry_renderer.uploadRenderSnapshot(self.current.geometry);
            billboard_renderer.uploadBillboards(self.current.billboard_buffer.items);
            player_renderer.uploadBillboards(&.{
                self.current.main_character.getBillboardData(
                    spritesheet,
                    self.current.previous_tick,
                ),
            });
            sprite_renderer.uploadSprites(billboard_buffer.items);
            performance_measurements.end(.aggregate_gem_billboards);
        }

        gl.clearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);

        gl.enable(gl.DEPTH_TEST);
        const camera = self.current.main_character.getInterpolatedCamera(
            lap_result.next_tick_progress,
        );

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
        geometry_renderer.render(
            vp_matrix,
            extra_data.screen_dimensions,
            camera.getDirectionToTarget(),
            tileable_textures,
            spritesheet,
            self.current.previous_tick,
            lap_result.next_tick_progress,
        );
        performance_measurements.end(.render_level_geometry);

        performance_measurements.begin(.draw_billboards);
        billboard_renderer.render(
            vp_matrix,
            extra_data.screen_dimensions,
            camera.getDirectionToTarget(),
            spritesheet.id,
            self.current.previous_tick,
            lap_result.next_tick_progress,
        );
        player_renderer.render(
            vp_matrix,
            extra_data.screen_dimensions,
            camera.getDirectionToTarget(),
            spritesheet.id,
            self.current.previous_tick,
            lap_result.next_tick_progress,
        );
        performance_measurements.end(.draw_billboards);

        performance_measurements.begin(.hud);
        gl.disable(gl.DEPTH_TEST);
        sprite_renderer.render(
            extra_data.screen_dimensions,
            spritesheet.id,
            self.current.previous_tick,
            lap_result.next_tick_progress,
        );
        performance_measurements.end(.hud);
        performance_measurements.end(.frame_total);

        frame_counter += 1;
        if (@mod(frame_counter, refresh_rate * 3) == 0) {
            performance_measurements.updateAverageAndReset();
            performance_measurements.printFrameInfo();
        }

        sdl.SDL_GL_SwapWindow(window);
    }
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
    /// Null if the flow field should not be rendered.
    player_flow_field: ?FlowField,
    /// Ignored if previous value is null.
    flow_field_font_size: u16,
) !void {
    self.extra_data.mutex.lock();
    defer self.extra_data.mutex.unlock();

    if (player_flow_field) |flow_field| {
        try flow_field.updatePrintableSnapshot(&self.extra_data.printable_flow_field_snapshot);
        self.extra_data.flow_field_font_size = flow_field_font_size;
    } else {
        self.extra_data.flow_field_font_size = null;
    }

    if (self.extra_data.screen_dimensions.w != screen_dimensions.w or
        self.extra_data.screen_dimensions.h != screen_dimensions.h)
    {
        self.extra_data.screen_dimensions_changed = true;
    }
    self.extra_data.screen_dimensions = screen_dimensions;
    self.extra_data.edit_mode_state = edit_mode_state;
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
    /// Tick from which the interpolation of these snapshots should start.
    previous_tick: u32,
    main_character: Player,
    geometry: GeometrySnapshot,
    billboard_buffer: std.ArrayList(rendering.SpriteData),

    fn create(allocator: std.mem.Allocator) Snapshots {
        return .{
            .previous_tick = 0,
            .main_character = Player.create(fp(0), fp(0), fp(1)),
            .geometry = GeometrySnapshot.create(allocator),
            .billboard_buffer = std.ArrayList(rendering.SpriteData).init(allocator),
        };
    }

    fn destroy(self: *Snapshots) void {
        self.billboard_buffer.deinit();
        self.geometry.destroy();
    }

    fn reset(self: *Snapshots) void {
        self.billboard_buffer.clearRetainingCapacity();
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

fn appendRenderHudSpriteData(
    allocator: std.mem.Allocator,
    spritesheet: textures.SpriteSheetTexture,
    screen_dimensions: ScreenDimensions,
    gem_count: u64,
    player_health: u32,
    out: *std.ArrayList(rendering.SpriteData),
) !void {
    var segments = try allocator.alloc(text_rendering.TextSegment, 1);
    defer allocator.free(segments);
    var buffer: [64]u8 = undefined;
    segments[0] = .{
        .color = Color.create(0, 0, 0, 255),
        .text = try std.fmt.bufPrint(&buffer, "Gems: {}\nHP: {}", .{ gem_count, player_health }),
    };

    var widget = try allocator.create(ui.Widget);
    defer allocator.destroy(widget);
    widget.* = .{ .text = ui.Text.wrap(segments, &spritesheet, 3) };

    const sprite_count = widget.getSpriteCount();
    try out.ensureUnusedCapacity(sprite_count);
    widget.populateSpriteData(
        0,
        screen_dimensions.h - widget.getDimensionsInPixels().h,
        out.unusedCapacitySlice(),
    );
    out.items.len += sprite_count;
}

fn appendEditModeSpritedData(
    state: EditModeState,
    spritesheet: textures.SpriteSheetTexture,
    out: *std.ArrayList(rendering.SpriteData),
) !void {
    var text_buffer: [64]u8 = undefined;
    const description = try state.describe(&text_buffer);

    const text_color = Color.create(0, 0, 0, 255);
    const segments = [_]text_rendering.TextSegment{
        .{ .color = text_color, .text = description[0] },
        .{ .color = text_color, .text = "\n" },
        .{ .color = text_color, .text = description[1] },
    };

    const sprite_count = text_rendering.getSpriteCount(&segments);
    try out.ensureUnusedCapacity(sprite_count);
    text_rendering.populateSpriteData(
        &segments,
        fp(0),
        fp(0),
        spritesheet.getFontSizeMultiple(2),
        spritesheet,
        out.unusedCapacitySlice(),
    );
    out.items.len += sprite_count;
}

fn appendFlowFieldSpritedData(
    screen_dimensions: ScreenDimensions,
    spritesheet: textures.SpriteSheetTexture,
    text_block: []const u8,
    font_size: u16,
    out: *std.ArrayList(rendering.SpriteData),
) !void {
    const segments = [_]text_rendering.TextSegment{ui.Highlight.normal(text_block)};
    const dimensions = text_rendering.getTextBlockDimensions(&segments, fp(font_size), spritesheet);
    const background = spritesheet.getSpriteSourceRectangle(.white_block);
    const screen_center = .{
        .x = fp(screen_dimensions.w).div(fp(2)),
        .y = fp(screen_dimensions.h).div(fp(2)),
        .z = fp(0),
    };

    const sprite_count = text_rendering.getSpriteCount(&segments) + 1; // Background sprite.
    try out.ensureUnusedCapacity(sprite_count);
    out.unusedCapacitySlice()[0] = rendering.SpriteData
        .create(screen_center, background, dimensions.width, dimensions.height)
        .withTint(Color.create(0, 0, 0, 255));
    text_rendering.populateSpriteData(
        &segments,
        screen_center.x.sub(dimensions.width.div(fp(2))),
        screen_center.y.sub(dimensions.height.div(fp(2))),
        font_size,
        spritesheet,
        out.unusedCapacitySlice()[1..],
    );
    out.items.len += sprite_count;
}
