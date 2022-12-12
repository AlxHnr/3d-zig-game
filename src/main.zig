const std = @import("std");

const rl = @import("raylib");

fn drawFpsCounter() void {
    var string_buffer: [16]u8 = undefined;
    if (std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()})) |slice| {
        rl.DrawText(slice, 5, 5, 20, rl.BLACK);
    } else |_| {
        unreachable;
    }
}

// The characters position on the map is stored as 2d coordinates. Jumping or climbing is not needed.
const Character = struct {
    position: rl.Vector2,
    direction: rl.Vector2,

    const character_dimensions = rl.Vector3{ .x = 0.6, .y = 1.8, .z = 0.25 };

    fn to3dCoordinates(self: Character) rl.Vector3 {
        return rl.Vector3{
            .x = self.position.x,
            .y = character_dimensions.y / 2.0,
            .z = self.position.y,
        };
    }

    fn draw(self: Character) void {
        const body_color = rl.Color{ .r = 142.0, .g = 223.0, .b = 255.0, .a = 100.0 };
        const frame_color = rl.Color{ .r = 0.0, .g = 48.0, .b = 143.0, .a = 255.0 };
        const render_position = self.to3dCoordinates();
        rl.DrawCubeV(render_position, character_dimensions, body_color);
        rl.DrawCubeWiresV(render_position, character_dimensions, frame_color);
    }
};

// Lap timer for measuring elapsed ticks.
const TickTimer = struct {
    timer: std.time.Timer,
    tick_duration: u64,
    leftover_time_from_last_tick: u64,

    // Create a new tick timer for measuring the specified tick rate. The given value is assumed to
    // be non-zero. Fails when no clock is available.
    fn start(ticks_per_second: u32) std.time.Timer.Error!TickTimer {
        std.debug.assert(ticks_per_second > 0);
        return TickTimer{
            .timer = try std.time.Timer.start(),
            .tick_duration = std.time.ns_per_s / ticks_per_second,
            .leftover_time_from_last_tick = 0,
        };
    }

    // Return the amount of elapsed ticks since the last call of this function or since start().
    fn lap(self: *TickTimer) LapResult {
        const elapsed_time = self.timer.lap() + self.leftover_time_from_last_tick;
        self.leftover_time_from_last_tick = elapsed_time % self.tick_duration;
        return LapResult{
            .elapsed_ticks = elapsed_time / self.tick_duration,
            .next_tick_progress = @intToFloat(f32, self.leftover_time_from_last_tick) / @intToFloat(f32, self.tick_duration),
        };
    }

    const LapResult = struct {
        elapsed_ticks: u64,
        // Value between 0.0 and 1.0 denoting how much percent of the next tick has already passed.
        // This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

pub fn main() !void {
    const screen_width = 800;
    const screen_height = 450;

    rl.InitWindow(screen_width, screen_height, "3D Zig Game");
    defer rl.CloseWindow();

    var camera = std.mem.zeroes(rl.Camera);
    camera.position = rl.Vector3{ .x = 5.0, .y = 5.0, .z = 5.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = 0.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

    var character = Character{
        .position = rl.Vector2{ .x = 0.0, .y = 0.0 },
        .direction = rl.Vector2{ .x = 0.0, .y = 1.0 },
    };

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.WHITE);

        rl.BeginMode3D(camera);
        character.draw();
        rl.DrawGrid(20, 1.0);
        rl.EndMode3D();

        drawFpsCounter();
        rl.EndDrawing();
    }
}
