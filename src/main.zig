const std = @import("std");

const rl = @import("raylib");
const rm = @import("raylib-math");

const Constants = struct {
    const up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
};

fn drawFpsCounter() void {
    var string_buffer: [16]u8 = undefined;
    if (std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()})) |slice| {
        rl.DrawText(slice, 5, 5, 20, rl.BLACK);
    } else |_| {
        unreachable;
    }
}

const Character = struct {
    position: rl.Vector3,
    direction: rl.Vector3,
    dimensions: rl.Vector3,

    fn create(position_x: f32, position_z: f32, direction_x: f32, direction_z: f32, dimensions: rl.Vector3) Character {
        return Character{
            .position = rl.Vector3{ .x = position_x, .y = dimensions.y / 2.0, .z = position_z },
            .direction = rl.Vector3{ .x = direction_x, .y = 0.0, .z = direction_z },
            .dimensions = dimensions,
        };
    }

    fn draw(self: Character) void {
        const body_color = rl.Color{ .r = 142.0, .g = 223.0, .b = 255.0, .a = 100.0 };
        const frame_color = rl.Color{ .r = 0.0, .g = 48.0, .b = 143.0, .a = 255.0 };
        rl.DrawCubeV(self.position, self.dimensions, body_color);
        rl.DrawCubeWiresV(self.position, self.dimensions, frame_color);

        const direction_line_target = rm.Vector3Add(self.position, rm.Vector3Scale(self.direction, 1.5));
        rl.DrawLine3D(self.position, direction_line_target, rl.BLUE);
    }
};

// Returns a camera position for looking down on the character from behind.
fn getCameraPositionBehindCharacter(character: Character) rl.Vector3 {
    const back_direction = rm.Vector3Negate(character.direction);
    const right_axis = rm.Vector3CrossProduct(back_direction, Constants.up);
    // TODO: Use std.math.degreesToRadians() after upgrade to zig 0.10.0.
    const unnormalized_direction = rm.Vector3RotateByAxisAngle(back_direction, right_axis, 30.0 * std.math.pi / 180.0);
    return rm.Vector3Scale(rm.Vector3Normalize(unnormalized_direction), 9.0);
}

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

    var character = Character.create(0.0, 0.0, 0.0, 1.0, rl.Vector3{ .x = 0.6, .y = 1.8, .z = 0.25 });

    var camera = std.mem.zeroes(rl.Camera);
    camera.position = getCameraPositionBehindCharacter(character);
    camera.target = character.position;
    camera.up = Constants.up;
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

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
