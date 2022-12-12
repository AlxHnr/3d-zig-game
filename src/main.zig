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

fn XzTo3DDirection(direction_x: f32, direction_z: f32) rl.Vector3 {
    return rm.Vector3Normalize(rl.Vector3{ .x = direction_x, .y = 0.0, .z = direction_z });
}

fn projectVector3OnAnother(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return rm.Vector3Scale(b, rm.Vector3DotProduct(a, b) / rm.Vector3DotProduct(b, b));
}

const Character = struct {
    position: rl.Vector3,
    looking_direction: rl.Vector3,
    acceleration_direction: rl.Vector3,
    velocity: rl.Vector3,
    dimensions: rl.Vector3,

    fn create(position_x: f32, position_z: f32, direction_x: f32, direction_z: f32, dimensions: rl.Vector3) Character {
        return Character{
            .position = rl.Vector3{ .x = position_x, .y = dimensions.y / 2.0, .z = position_z },
            .looking_direction = XzTo3DDirection(direction_x, direction_z),
            .acceleration_direction = std.mem.zeroes(rl.Vector3),
            .velocity = std.mem.zeroes(rl.Vector3),
            .dimensions = dimensions,
        };
    }

    fn getRightFromLookingDirection(self: Character) rl.Vector3 {
        return rm.Vector3CrossProduct(self.looking_direction, Constants.up);
    }

    // Given direction values will be normalized.
    fn setAcceleration(self: *Character, direction_x: f32, direction_z: f32) void {
        self.acceleration_direction = XzTo3DDirection(direction_x, direction_z);
    }

    // To be called once for each tick.
    fn update(self: *Character) void {
        const is_accelerating = rm.Vector3Length(self.acceleration_direction) > std.math.f32_epsilon;
        if (is_accelerating) {
            self.velocity = rm.Vector3Add(self.velocity, rm.Vector3Scale(self.acceleration_direction, 0.03));
            self.velocity = rm.Vector3ClampValue(self.velocity, 0.0, 0.2);
        } else {
            self.velocity = rm.Vector3Scale(self.velocity, 0.7);
        }

        self.position = rm.Vector3Add(self.position, self.velocity);
    }

    fn draw(self: Character) void {
        const body_color = rl.Color{ .r = 142.0, .g = 223.0, .b = 255.0, .a = 100.0 };
        const frame_color = rl.Color{ .r = 0.0, .g = 48.0, .b = 143.0, .a = 255.0 };
        rl.DrawCubeV(self.position, self.dimensions, body_color);
        rl.DrawCubeWiresV(self.position, self.dimensions, frame_color);

        const direction_line_target = rm.Vector3Add(self.position, rm.Vector3Scale(self.looking_direction, 1.5));
        rl.DrawLine3D(self.position, direction_line_target, rl.BLUE);
    }
};

// Returns a camera position for looking down on the character from behind.
fn getCameraPositionBehindCharacter(character: Character) rl.Vector3 {
    const back_direction = rm.Vector3Negate(character.looking_direction);
    const right_axis = rm.Vector3Negate(character.getRightFromLookingDirection());
    // TODO: Use std.math.degreesToRadians() after upgrade to zig 0.10.0.
    const unnormalized_direction = rm.Vector3RotateByAxisAngle(back_direction, right_axis, 30.0 * std.math.pi / 180.0);
    const offset_from_character = rm.Vector3Scale(rm.Vector3Normalize(unnormalized_direction), 9.0);
    return rm.Vector3Add(character.position, offset_from_character);
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
    camera.up = Constants.up;
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

    var tick_timer = try TickTimer.start(60);

    while (!rl.WindowShouldClose()) {
        var acceleration_direction = std.mem.zeroes(rl.Vector3);
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT)) {
            acceleration_direction = rm.Vector3Subtract(acceleration_direction, character.getRightFromLookingDirection());
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT)) {
            acceleration_direction = rm.Vector3Add(acceleration_direction, character.getRightFromLookingDirection());
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_UP)) {
            acceleration_direction = rm.Vector3Add(acceleration_direction, character.looking_direction);
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN)) {
            acceleration_direction = rm.Vector3Subtract(acceleration_direction, character.looking_direction);
        }
        character.setAcceleration(acceleration_direction.x, acceleration_direction.z);

        const lap_result = tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            character.update();
        }

        camera.target = character.position;
        camera.position = getCameraPositionBehindCharacter(character);

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
