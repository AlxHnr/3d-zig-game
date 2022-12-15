const std = @import("std");

const rl = @import("raylib");
const rm = @import("raylib-math");

const Constants = struct {
    const up = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
};

fn drawFpsCounter() void {
    var string_buffer: [16]u8 = undefined;
    if (std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()})) |slice| {
        rl.DrawText(slice, 5, 5, 20, rl.BLACK);
    } else |_| {
        unreachable;
    }
}

// TODO: Use std.math.degreesToRadians() after upgrade to zig 0.10.0.
fn degreesToRadians(degrees: f32) f32 {
    return degrees * std.math.pi / 180;
}
fn radiansToDegrees(radians: f32) f32 {
    return radians * 180 / std.math.pi;
}

// TODO: rm.Vector2Angle() is broken in raylib 4.2.0.
fn getAngle(a: rl.Vector2, b: rl.Vector2) f32 {
    const dot_product = rm.Vector2DotProduct(a, b);
    return std.math.acos(std.math.clamp(dot_product, -1, 1));
}

fn lerpColor(a: rl.Color, b: rl.Color, interval: f32) rl.Color {
    return rl.Color{
        .r = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.r), @intToFloat(f32, b.r), interval)),
        .g = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.g), @intToFloat(f32, b.g), interval)),
        .b = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.b), @intToFloat(f32, b.b), interval)),
        .a = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.a), @intToFloat(f32, b.a), interval)),
    };
}

fn XzTo3DDirection(direction_x: f32, direction_z: f32) rl.Vector3 {
    return rm.Vector3Normalize(rl.Vector3{ .x = direction_x, .y = 0, .z = direction_z });
}

fn projectVector3OnAnother(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return rm.Vector3Scale(b, rm.Vector3DotProduct(a, b) / rm.Vector3DotProduct(b, b));
}

const Character = struct {
    position: rl.Vector3, // Y will always be 0.
    looking_direction: rl.Vector3, // Y will always be 0.
    turning_direction: f32, // Values from -1 (turning left) to 1 (turning right).
    acceleration_direction: rl.Vector3, // Y will always be 0.
    velocity: rl.Vector3, // Y will always be 0.
    width: f32,
    height: f32,
    color: rl.Color,

    fn create(
        position_x: f32,
        position_z: f32,
        direction_x: f32,
        direction_z: f32,
        width: f32,
        height: f32,
        color: rl.Color,
    ) Character {
        return Character{
            .position = rl.Vector3{ .x = position_x, .y = 0, .z = position_z },
            .looking_direction = XzTo3DDirection(direction_x, direction_z),
            .turning_direction = 0,
            .acceleration_direction = std.mem.zeroes(rl.Vector3),
            .velocity = std.mem.zeroes(rl.Vector3),
            .width = width,
            .height = height,
            .color = color,
        };
    }

    // Interpolate between this characters state and another characters state based on the given
    // interval from 0 to 1.
    fn lerp(self: Character, other: Character, interval: f32) Character {
        const i = std.math.clamp(interval, 0, 1);
        return Character{
            .position = rm.Vector3Lerp(self.position, other.position, i),
            .looking_direction = rm.Vector3Lerp(self.looking_direction, other.looking_direction, i),
            .turning_direction = rm.Lerp(self.turning_direction, other.turning_direction, i),
            .acceleration_direction = rm.Vector3Lerp(self.acceleration_direction, other.acceleration_direction, i),
            .velocity = rm.Vector3Lerp(self.velocity, other.velocity, i),
            .width = rm.Lerp(self.width, other.width, i),
            .height = rm.Lerp(self.height, other.height, i),
            .color = lerpColor(self.color, other.color, i),
        };
    }

    fn getRightFromLookingDirection(self: Character) rl.Vector3 {
        return rm.Vector3CrossProduct(self.looking_direction, Constants.up);
    }

    // Given direction values will be normalized.
    fn setAcceleration(self: *Character, direction_x: f32, direction_z: f32) void {
        self.acceleration_direction = XzTo3DDirection(direction_x, direction_z);
    }

    // Value from -1 (left) to 1 (right). Will be clamped into this range.
    fn setTurningDirection(self: *Character, turning_direction: f32) void {
        self.turning_direction = rm.Clamp(turning_direction, -1, 1);
    }

    // To be called once for each tick.
    fn update(self: *Character) void {
        const is_accelerating = rm.Vector3Length(self.acceleration_direction) > std.math.f32_epsilon;
        if (is_accelerating) {
            self.velocity = rm.Vector3Add(self.velocity, rm.Vector3Scale(self.acceleration_direction, 0.03));
            self.velocity = rm.Vector3ClampValue(self.velocity, 0, 0.2);
        } else {
            self.velocity = rm.Vector3Scale(self.velocity, 0.7);
        }

        self.position = rm.Vector3Add(self.position, self.velocity);

        const max_rotation_per_tick = degreesToRadians(5);
        const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
        self.looking_direction = rm.Vector3RotateByAxisAngle(self.looking_direction, Constants.up, rotation_angle);
    }

    fn draw(self: Character) void {
        const frame_color = rl.Color{ .r = 127, .g = 127, .b = 127, .a = 255 };
        rl.DrawCylinder(self.position, 0, self.width / 2, self.height, 10, self.color);
        rl.DrawCylinderWires(self.position, 0, self.width / 2, self.height, 10, frame_color);

        const direction_line_target = rm.Vector3Add(self.position, rm.Vector3Scale(self.looking_direction, 2));
        rl.DrawLine3D(self.position, direction_line_target, rl.BLUE);
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
            .next_tick_progress = @floatCast(f32, @intToFloat(
                f64,
                self.leftover_time_from_last_tick,
            ) / @intToFloat(f64, self.tick_duration)),
        };
    }

    const LapResult = struct {
        elapsed_ticks: u64,
        // Value between 0 and 1 denoting how much percent of the next tick has already passed.
        // This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

// Camera which smoothly follows the character and auto-rotates across the Y axis.
const ThirdPersonCamera = struct {
    camera: rl.Camera,

    // Initialize the camera to look down at the given character from behind.
    fn create(character: Character) ThirdPersonCamera {
        var camera = std.mem.zeroes(rl.Camera);
        camera.up = Constants.up;
        camera.fovy = 45;
        camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;
        camera.target = character.position;

        const looking_angle = degreesToRadians(20);
        const distance_from_character = 10;
        const back_direction = rm.Vector3Negate(character.looking_direction);
        const right_axis = rm.Vector3Negate(character.getRightFromLookingDirection());
        const unnormalized_direction = rm.Vector3RotateByAxisAngle(back_direction, right_axis, looking_angle);
        const offset_from_character = rm.Vector3Scale(rm.Vector3Normalize(unnormalized_direction), distance_from_character);
        camera.position = rm.Vector3Add(character.position, offset_from_character);

        return ThirdPersonCamera{ .camera = camera };
    }

    // Interpolate between this cameras state and another cameras state based on the given interval
    // from 0 to 1.
    fn lerp(self: ThirdPersonCamera, other: ThirdPersonCamera, interval: f32) ThirdPersonCamera {
        const i = std.math.clamp(interval, 0, 1);

        var camera = self.camera;
        camera.position = rm.Vector3Lerp(self.camera.position, other.camera.position, i);
        camera.target = rm.Vector3Lerp(self.camera.target, other.camera.target, i);

        return ThirdPersonCamera{ .camera = camera };
    }

    // To be called once for each tick.
    fn update(self: *ThirdPersonCamera, character_to_follow: Character) void {
        const camera_follow_speed = 0.15;

        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const camera_direction_2d = rm.Vector2Normalize(rl.Vector2{
            .x = camera_offset.x,
            .y = camera_offset.z,
        });
        const character_back_direction_2d = rl.Vector2{
            .x = -character_to_follow.looking_direction.x,
            .y = -character_to_follow.looking_direction.z,
        };
        const rotation_angle = getAngle(camera_direction_2d, character_back_direction_2d);
        const camera_right_axis_2d = rl.Vector2{ .x = camera_direction_2d.y, .y = -camera_direction_2d.x };
        const turn_right = rm.Vector2DotProduct(character_back_direction_2d, camera_right_axis_2d) < 0;
        const rotation_step = camera_follow_speed * if (turn_right)
            -rotation_angle
        else
            rotation_angle;
        const updated_camera_offset = rm.Vector3RotateByAxisAngle(camera_offset, Constants.up, rotation_step);
        self.camera.target = rm.Vector3Lerp(self.camera.target, character_to_follow.position, camera_follow_speed);
        self.camera.position = rm.Vector3Add(self.camera.target, updated_camera_offset);
    }
};

const InputConfiguration = struct {
    move_left: rl.KeyboardKey,
    move_right: rl.KeyboardKey,
    move_forward: rl.KeyboardKey,
    move_backwards: rl.KeyboardKey,
    turn_left: rl.KeyboardKey,
    turn_right: rl.KeyboardKey,
};

const Player = struct {
    const State = struct {
        character: Character,
        camera: ThirdPersonCamera,

        // Interpolate between this players state and another players state based on the given
        // interval from 0 to 1.
        fn lerp(self: State, other: State, interval: f32) State {
            return State{
                .character = self.character.lerp(other.character, interval),
                .camera = self.camera.lerp(other.camera, interval),
            };
        }

        // To be called once for each tick.
        fn update(self: *State) void {
            self.character.update();
            self.camera.update(self.character);
        }
    };

    state_at_next_tick: State,
    state_at_previous_tick: State,
    input_configuration: InputConfiguration,

    fn create(
        starting_position_x: f32,
        starting_position_z: f32,
        color: rl.Color,
        input_configuration: InputConfiguration,
    ) Player {
        const direction_towards_center = rm.Vector2Normalize(rl.Vector2{
            .x = -starting_position_x,
            .y = -starting_position_z,
        });
        const character = Character.create(
            starting_position_x,
            starting_position_z,
            direction_towards_center.x,
            direction_towards_center.y,
            0.6,
            1.8,
            color,
        );
        const state = State{
            .character = character,
            .camera = ThirdPersonCamera.create(character),
        };
        return Player{
            .state_at_next_tick = state,
            .state_at_previous_tick = state,
            .input_configuration = input_configuration,
        };
    }

    // To be called on every frame after rendering but before processing ticks.
    fn pollInputs(self: *Player, interval_between_previous_and_current_tick: f32) void {
        // Input is relative to the state currently on screen.
        const state_rendered_to_screen = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        var acceleration_direction = std.mem.zeroes(rl.Vector3);
        if (rl.IsKeyDown(self.input_configuration.move_left)) {
            acceleration_direction = rm.Vector3Subtract(
                acceleration_direction,
                state_rendered_to_screen.character.getRightFromLookingDirection(),
            );
        }
        if (rl.IsKeyDown(self.input_configuration.move_right)) {
            acceleration_direction = rm.Vector3Add(
                acceleration_direction,
                state_rendered_to_screen.character.getRightFromLookingDirection(),
            );
        }
        if (rl.IsKeyDown(self.input_configuration.move_forward)) {
            acceleration_direction = rm.Vector3Add(
                acceleration_direction,
                state_rendered_to_screen.character.looking_direction,
            );
        }
        if (rl.IsKeyDown(self.input_configuration.move_backwards)) {
            acceleration_direction = rm.Vector3Subtract(
                acceleration_direction,
                state_rendered_to_screen.character.looking_direction,
            );
        }
        self.state_at_next_tick.character.setAcceleration(
            acceleration_direction.x,
            acceleration_direction.z,
        );

        var turning_direction: f32 = 0;
        if (rl.IsKeyDown(self.input_configuration.turn_left)) {
            turning_direction -= 1;
        }
        if (rl.IsKeyDown(self.input_configuration.turn_right)) {
            turning_direction += 1;
        }
        self.state_at_next_tick.character.setTurningDirection(turning_direction);
    }

    // To be called once for each tick.
    fn update(self: *Player) void {
        self.state_at_previous_tick = self.state_at_next_tick;
        self.state_at_next_tick.update();
    }

    fn draw(self: Player, interval_between_previous_and_current_tick: f32) void {
        self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).character.draw();
    }

    fn getCamera(self: Player, interval_between_previous_and_current_tick: f32) rl.Camera {
        return self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).camera.camera;
    }
};

fn drawScene(players: []const Player, interval_between_previous_and_current_tick: f32) void {
    rl.ClearBackground(rl.WHITE);
    rl.DrawGrid(100, 1);

    for (players) |player| {
        player.draw(interval_between_previous_and_current_tick);
    }
}

const RaylibError = error{
    UnableToCreateRenderTexture,
};

fn createRenderTexture(width: u16, height: u16) RaylibError!rl.RenderTexture {
    const render_texture = rl.LoadRenderTexture(width, height);
    return if (render_texture.id == 0)
        RaylibError.UnableToCreateRenderTexture
    else
        render_texture;
}

fn drawSceneToTexture(
    texture: rl.RenderTexture,
    players: []const Player,
    current_player: Player,
    interval_between_previous_and_current_tick: f32,
) void {
    rl.BeginTextureMode(texture);
    rl.BeginMode3D(current_player.getCamera(interval_between_previous_and_current_tick));
    drawScene(players, interval_between_previous_and_current_tick);
    rl.EndMode3D();
    rl.EndTextureMode();
}

pub fn main() !void {
    var screen_width: u16 = 800;
    var screen_height: u16 = 450;

    rl.InitWindow(screen_width, screen_height, "3D Zig Game");
    defer rl.CloseWindow();

    var players = [_]Player{
        Player.create(28, 28, rl.Color{ .r = 154, .g = 205, .b = 50, .a = 100 }, InputConfiguration{
            .move_left = rl.KeyboardKey.KEY_A,
            .move_right = rl.KeyboardKey.KEY_D,
            .move_forward = rl.KeyboardKey.KEY_W,
            .move_backwards = rl.KeyboardKey.KEY_S,
            .turn_left = rl.KeyboardKey.KEY_Q,
            .turn_right = rl.KeyboardKey.KEY_E,
        }),
        Player.create(12, 34, rl.Color{ .r = 142, .g = 223, .b = 255, .a = 100 }, InputConfiguration{
            .move_left = rl.KeyboardKey.KEY_LEFT,
            .move_right = rl.KeyboardKey.KEY_RIGHT,
            .move_forward = rl.KeyboardKey.KEY_UP,
            .move_backwards = rl.KeyboardKey.KEY_DOWN,
            .turn_left = rl.KeyboardKey.KEY_PAGE_UP,
            .turn_right = rl.KeyboardKey.KEY_PAGE_DOWN,
        }),
    };

    var left_split_screen = try createRenderTexture(@divTrunc(screen_width, 2), screen_height);
    defer rl.UnloadRenderTexture(left_split_screen);
    var right_split_screen = try createRenderTexture(@divTrunc(screen_width, 2), screen_height);
    defer rl.UnloadRenderTexture(right_split_screen);

    var tick_timer = try TickTimer.start(60);
    while (!rl.WindowShouldClose()) {
        const lap_result = tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            for (players) |*player| {
                player.update();
            }
        }

        drawSceneToTexture(left_split_screen, &players, players[0], lap_result.next_tick_progress);
        drawSceneToTexture(right_split_screen, &players, players[1], lap_result.next_tick_progress);

        rl.BeginDrawing();
        const split_rectangle = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @intToFloat(f32, screen_width) / 2,
            .height = -@intToFloat(f32, screen_height),
        };
        rl.DrawTextureRec(left_split_screen.texture, split_rectangle, std.mem.zeroes(rl.Vector2), rl.WHITE);
        rl.DrawTextureRec(right_split_screen.texture, split_rectangle, rl.Vector2{
            .x = @intToFloat(f32, screen_width) / 2,
            .y = 0,
        }, rl.WHITE);
        drawFpsCounter();
        rl.EndDrawing();

        for (players) |*player| {
            player.pollInputs(lap_result.next_tick_progress);
        }
        if (rl.IsWindowResized()) {
            screen_width = @intCast(u16, rl.GetScreenWidth());
            screen_height = @intCast(u16, rl.GetScreenHeight());

            rl.UnloadRenderTexture(left_split_screen);
            left_split_screen.id = 0;

            rl.UnloadRenderTexture(right_split_screen);
            right_split_screen.id = 0;

            left_split_screen = try createRenderTexture(@divTrunc(screen_width, 2), screen_height);
            right_split_screen = try createRenderTexture(@divTrunc(screen_width, 2), screen_height);
        }
    }
}
