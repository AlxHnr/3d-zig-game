const EnemySnapshot = @import("enemy.zig").RenderSnapshot;
const GemSnapshot = @import("gem.zig").RenderSnapshot;
const GeometryRenderer = @import("map/geometry.zig").Renderer;
const Player = @import("game_unit.zig").Player;
const PrerenderedEnemyNames = @import("enemy.zig").PrerenderedNames;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const gl = @import("gl");
const rendering = @import("rendering.zig");
const sdl = @import("sdl.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const textures = @import("textures.zig");

const Loop = @This();

allocator: std.mem.Allocator,
keep_running: std.atomic.Atomic(bool),
current: Snapshots,
/// Will be atomically swapped with `current`.
secondary: Snapshots,
secondary_is_populated: bool,
mutex: std.Thread.Mutex,
condition: std.Thread.Condition,

pub fn create(allocator: std.mem.Allocator) !Loop {
    var current = try Snapshots.create(allocator);
    errdefer current.destroy();
    var secondary = try Snapshots.create(allocator);
    errdefer secondary.destroy();

    return .{
        .allocator = allocator,
        .keep_running = std.atomic.Atomic(bool).init(true),
        .current = current,
        .secondary = secondary,
        .secondary_is_populated = false,
        .mutex = .{},
        .condition = .{},
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
    screen_dimensions: ScreenDimensions,
) !void {
    try sdl.makeGLContextCurrent(window, gl_context);

    var timer = try simulation.TickTimer.start(simulation.tickrate);

    var billboard_renderer = try rendering.BillboardRenderer.create();
    defer billboard_renderer.destroy();

    var billboard_buffer = std.ArrayList(rendering.SpriteData).init(self.allocator);
    defer billboard_buffer.deinit();

    var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
    defer spritesheet.destroy();

    var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
    defer tileable_textures.destroy();

    var prerendered_enemy_names = try PrerenderedEnemyNames.create(self.allocator, spritesheet);
    defer prerendered_enemy_names.destroy(self.allocator);

    while (self.keep_running.load(.Unordered)) {
        const lap_result = timer.lap();
        if (lap_result.elapsed_ticks > 0) {
            self.swapSnapshots();
        }

        gl.clearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);

        gl.enable(gl.DEPTH_TEST);
        const camera = self.current.main_character.getCamera(lap_result.next_tick_progress);

        billboard_buffer.clearRetainingCapacity();

        for (self.current.enemies.items) |snapshot| {
            const billboard_count = snapshot.getBillboardCount(
                prerendered_enemy_names,
                camera,
                lap_result.next_tick_progress,
            );
            try billboard_buffer.ensureUnusedCapacity(billboard_count);
            snapshot.populateBillboardData(
                spritesheet,
                prerendered_enemy_names,
                camera,
                lap_result.next_tick_progress,
                billboard_buffer.unusedCapacitySlice()[0..billboard_count],
            );
            billboard_buffer.items.len += billboard_count;
        }

        for (self.current.gems.items) |snapshot| {
            try billboard_buffer.append(
                snapshot.makeBillboardData(spritesheet, lap_result.next_tick_progress),
            );
        }

        try billboard_buffer.append(self.current.main_character.getBillboardData(
            spritesheet,
            lap_result.next_tick_progress,
        ));
        billboard_renderer.uploadBillboards(billboard_buffer.items);

        const vp_matrix = camera.getViewProjectionMatrix(screen_dimensions, null);
        self.current.geometry_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            tileable_textures,
            spritesheet,
        );
        billboard_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            spritesheet.id,
        );

        gl.disable(gl.DEPTH_TEST);
        // HUD

        sdl.SDL_GL_SwapWindow(window);
    }
}

pub fn sendStop(self: *Loop) void {
    self.keep_running.store(false, .Unordered);

    self.mutex.lock();
    self.condition.signal();
    self.mutex.unlock();
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
    geometry_renderer: GeometryRenderer,
    enemies: std.ArrayList(EnemySnapshot),
    gems: std.ArrayList(GemSnapshot),

    fn create(allocator: std.mem.Allocator) !Snapshots {
        return .{
            .main_character = Player.create(0, 0, 0),
            .geometry_renderer = try GeometryRenderer.create(allocator),
            .enemies = std.ArrayList(EnemySnapshot).init(allocator),
            .gems = std.ArrayList(GemSnapshot).init(allocator),
        };
    }

    fn destroy(self: *Snapshots) void {
        self.gems.deinit();
        self.enemies.deinit();
        self.geometry_renderer.destroy();
    }

    fn reset(self: *Snapshots) void {
        self.enemies.clearRetainingCapacity();
        self.gems.clearRetainingCapacity();
    }
};

fn swapSnapshots(self: *Loop) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.keep_running.load(.Unordered) and !self.secondary_is_populated) {
        self.condition.wait(&self.mutex);
    }
    if (self.secondary_is_populated) {
        std.mem.swap(Snapshots, &self.current, &self.secondary);
        self.secondary_is_populated = false;
    }
}
