const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const level_geometry = @import("level_geometry.zig");

fn drawFpsCounter() void {
    var string_buffer: [16]u8 = undefined;
    if (std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()})) |slice| {
        rl.DrawText(slice, 5, 5, 20, rl.BLACK);
    } else |_| {
        unreachable;
    }
}

/// Get the angle needed to rotate vector a to have the same direction as vector b. The given
/// vectors don't need to be normalized.
fn computeYRotationAngle(a: rl.Vector3, b: rl.Vector3) f32 {
    return util.FlatVector.fromVector3(a)
        .computeRotationToOtherVector(util.FlatVector.fromVector3(b));
}

fn lerpColor(a: rl.Color, b: rl.Color, interval: f32) rl.Color {
    return rl.Color{
        .r = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.r), @intToFloat(f32, b.r), interval)),
        .g = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.g), @intToFloat(f32, b.g), interval)),
        .b = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.b), @intToFloat(f32, b.b), interval)),
        .a = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.a), @intToFloat(f32, b.a), interval)),
    };
}

fn clampCameraDistanceFromTarget(camera: rl.Camera, max_distance: f32) rl.Camera {
    const offset = rm.Vector3Subtract(camera.position, camera.target);
    if (rm.Vector3Length(offset) < max_distance) {
        return camera;
    }
    var updated_camera = camera;
    updated_camera.position = rm.Vector3Add(
        camera.target,
        rm.Vector3Scale(rm.Vector3Normalize(offset), max_distance * 0.95),
    );
    return updated_camera;
}

const Character = struct {
    boundaries: collision.Circle,
    /// Y will always be 0.
    looking_direction: rl.Vector3,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: f32,
    /// Y will always be 0.
    acceleration_direction: rl.Vector3,
    /// Y will always be 0.
    velocity: rl.Vector3,
    height: f32,
    color: rl.Color,

    fn create(
        position: util.FlatVector,
        looking_direction: util.FlatVector,
        radius: f32,
        height: f32,
        color: rl.Color,
    ) Character {
        return Character{
            .boundaries = collision.Circle{ .position = position, .radius = radius },
            .looking_direction = looking_direction.normalize().toVector3(),
            .turning_direction = 0,
            .acceleration_direction = std.mem.zeroes(rl.Vector3),
            .velocity = std.mem.zeroes(rl.Vector3),
            .height = height,
            .color = color,
        };
    }

    /// Interpolate between this characters state and another characters state based on the given
    /// interval from 0 to 1.
    fn lerp(self: Character, other: Character, interval: f32) Character {
        const i = std.math.clamp(interval, 0, 1);
        return Character{
            .boundaries = self.boundaries.lerp(other.boundaries, i),
            .looking_direction = rm.Vector3Lerp(self.looking_direction, other.looking_direction, i),
            .turning_direction = rm.Lerp(self.turning_direction, other.turning_direction, i),
            .acceleration_direction = rm.Vector3Lerp(self.acceleration_direction, other.acceleration_direction, i),
            .velocity = rm.Vector3Lerp(self.velocity, other.velocity, i),
            .height = rm.Lerp(self.height, other.height, i),
            .color = lerpColor(self.color, other.color, i),
        };
    }

    fn getRightFromLookingDirection(self: Character) rl.Vector3 {
        return rm.Vector3CrossProduct(self.looking_direction, util.Constants.up);
    }

    /// Given direction values will be normalized.
    fn setAcceleration(self: *Character, direction_x: f32, direction_z: f32) void {
        self.acceleration_direction =
            rm.Vector3Normalize(rl.Vector3{ .x = direction_x, .y = 0, .z = direction_z });
    }

    /// Value from -1 (left) to 1 (right). Will be clamped into this range.
    fn setTurningDirection(self: *Character, turning_direction: f32) void {
        self.turning_direction = rm.Clamp(turning_direction, -1, 1);
    }

    fn getTopOfCharacter(self: Character) rl.Vector3 {
        return rm.Vector3Add(
            self.boundaries.position.toVector3(),
            rl.Vector3{ .x = 0, .y = self.height, .z = 0 },
        );
    }

    fn resolveCollision(self: *Character, displacement_vector: util.FlatVector) void {
        self.boundaries.position = self.boundaries.position.add(displacement_vector);
        const dot_product = std.math.clamp(util.FlatVector.fromVector3(self.velocity).normalize()
            .dotProduct(displacement_vector.normalize()), -1, 1);
        const moving_against_displacement_vector =
            util.FlatVector.fromVector3(self.velocity).dotProduct(displacement_vector) < 0;
        if (moving_against_displacement_vector) {
            self.velocity = rm.Vector3Scale(self.velocity, 1 + dot_product);
        }
    }

    /// To be called once for each tick.
    fn update(self: *Character) void {
        self.boundaries.position =
            self.boundaries.position.add(util.FlatVector.fromVector3(self.velocity));

        const is_accelerating =
            rm.Vector3Length(self.acceleration_direction) > util.Constants.epsilon;
        if (is_accelerating) {
            self.velocity = rm.Vector3Add(self.velocity, rm.Vector3Scale(self.acceleration_direction, 0.03));
            self.velocity = rm.Vector3ClampValue(self.velocity, 0, 0.2);
        } else {
            self.velocity = rm.Vector3Scale(self.velocity, 0.7);
        }

        const max_rotation_per_tick = util.degreesToRadians(5);
        const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
        self.looking_direction =
            rm.Vector3RotateByAxisAngle(self.looking_direction, util.Constants.up, rotation_angle);
    }

    fn draw(self: Character) void {
        rl.DrawCylinder(
            self.boundaries.position.toVector3(),
            0,
            self.boundaries.radius,
            self.height,
            10,
            self.color,
        );
        rl.DrawCylinderWires(
            self.boundaries.position.toVector3(),
            0,
            self.boundaries.radius,
            self.height,
            10,
            rl.GRAY,
        );

        const direction_line_target = rm.Vector3Add(
            self.boundaries.position.toVector3(),
            rm.Vector3Scale(self.looking_direction, 2),
        );
        rl.DrawLine3D(self.boundaries.position.toVector3(), direction_line_target, rl.BLUE);
    }
};

/// Lap timer for measuring elapsed ticks.
const TickTimer = struct {
    timer: std.time.Timer,
    tick_duration: u64,
    leftover_time_from_last_tick: u64,

    /// Create a new tick timer for measuring the specified tick rate. The given value is assumed to
    /// be non-zero. Fails when no clock is available.
    fn start(ticks_per_second: u32) std.time.Timer.Error!TickTimer {
        std.debug.assert(ticks_per_second > 0);
        return TickTimer{
            .timer = try std.time.Timer.start(),
            .tick_duration = std.time.ns_per_s / ticks_per_second,
            .leftover_time_from_last_tick = 0,
        };
    }

    /// Return the amount of elapsed ticks since the last call of this function or since start().
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
        /// Value between 0 and 1 denoting how much percent of the next tick has already passed.
        /// This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

/// Camera which smoothly follows the character and auto-rotates across the Y axis.
const ThirdPersonCamera = struct {
    camera: rl.Camera,
    distance_from_character: f32,
    /// This value will be approached by update().
    target_distance_from_character: f32,
    angle_from_ground: f32,
    /// This value will be approached by update().
    target_angle_from_ground: f32,

    const camera_follow_speed = 0.15;
    const default_angle_from_ground = util.degreesToRadians(15);

    /// Initialize the camera to look down at the given character from behind.
    fn create(character: Character) ThirdPersonCamera {
        var camera = std.mem.zeroes(rl.Camera);
        camera.up = util.Constants.up;
        camera.fovy = 45;
        camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;
        camera.target = character.getTopOfCharacter();

        const distance_from_character = 10;
        const back_direction = rm.Vector3Negate(character.looking_direction);
        const right_axis = rm.Vector3Negate(character.getRightFromLookingDirection());
        const unnormalized_direction =
            rm.Vector3RotateByAxisAngle(back_direction, right_axis, default_angle_from_ground);
        const offset_from_character =
            rm.Vector3Scale(rm.Vector3Normalize(unnormalized_direction), distance_from_character);
        camera.position = rm.Vector3Add(camera.target, offset_from_character);

        return ThirdPersonCamera{
            .camera = camera,
            .distance_from_character = distance_from_character,
            .target_distance_from_character = distance_from_character,
            .angle_from_ground = default_angle_from_ground,
            .target_angle_from_ground = default_angle_from_ground,
        };
    }

    /// Interpolate between this cameras state and another cameras state based on the given interval
    /// from 0 to 1.
    fn lerp(self: ThirdPersonCamera, other: ThirdPersonCamera, interval: f32) ThirdPersonCamera {
        const i = std.math.clamp(interval, 0, 1);

        var camera = self.camera;
        camera.position = rm.Vector3Lerp(self.camera.position, other.camera.position, i);
        camera.target = rm.Vector3Lerp(self.camera.target, other.camera.target, i);

        return ThirdPersonCamera{
            .camera = camera,
            .distance_from_character = rm.Lerp(
                self.distance_from_character,
                other.distance_from_character,
                i,
            ),
            .target_distance_from_character = rm.Lerp(
                self.target_distance_from_character,
                other.target_distance_from_character,
                i,
            ),
            .angle_from_ground = rm.Lerp(self.angle_from_ground, other.angle_from_ground, i),
            .target_angle_from_ground = rm.Lerp(
                self.target_angle_from_ground,
                other.target_angle_from_ground,
                i,
            ),
        };
    }

    fn increaseDistanceToCharacter(self: *ThirdPersonCamera, offset: f32) void {
        self.target_distance_from_character =
            std.math.max(self.target_distance_from_character + offset, 5);
    }

    /// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
    fn setAngleFromGround(self: *ThirdPersonCamera, angle: f32) void {
        self.target_angle_from_ground = std.math.clamp(angle, 0, util.degreesToRadians(89));
    }

    /// To be called once for each tick.
    fn update(self: *ThirdPersonCamera, character_to_follow: Character) void {
        self.updateAngleFromGround();
        const y_rotated_camera_offset = self.computeYRotatedCameraOffset(character_to_follow);
        self.camera.target = rm.Vector3Lerp(
            self.camera.target,
            character_to_follow.getTopOfCharacter(),
            camera_follow_speed,
        );
        self.camera.position = rm.Vector3Add(self.camera.target, y_rotated_camera_offset);
        self.updateCameraDistanceFromCharacter();
    }

    fn updateAngleFromGround(self: *ThirdPersonCamera) void {
        if (util.isEqualFloat(self.angle_from_ground, self.target_angle_from_ground)) {
            return;
        }
        self.angle_from_ground = rm.Lerp(
            self.angle_from_ground,
            self.target_angle_from_ground,
            camera_follow_speed,
        );

        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const flat_camera_direction = rm.Vector3Normalize(
            rl.Vector3{ .x = camera_offset.x, .y = 0, .z = camera_offset.z },
        );
        const rotation_axis =
            rl.Vector3{ .x = flat_camera_direction.z, .y = 0, .z = -flat_camera_direction.x };
        const rotated_camera_direction = rm.Vector3RotateByAxisAngle(
            flat_camera_direction,
            rotation_axis,
            -self.angle_from_ground,
        );
        self.camera.position = rm.Vector3Add(
            self.camera.target,
            rm.Vector3Scale(rotated_camera_direction, self.distance_from_character),
        );
    }

    fn computeYRotatedCameraOffset(self: ThirdPersonCamera, character_to_follow: Character) rl.Vector3 {
        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const character_back_direction = rm.Vector3Negate(character_to_follow.looking_direction);
        const rotation_step = camera_follow_speed *
            computeYRotationAngle(camera_offset, character_back_direction);
        return rm.Vector3RotateByAxisAngle(camera_offset, util.Constants.up, rotation_step);
    }

    fn updateCameraDistanceFromCharacter(self: *ThirdPersonCamera) void {
        if (util.isEqualFloat(self.distance_from_character, self.target_distance_from_character)) {
            return;
        }
        self.distance_from_character = rm.Lerp(
            self.distance_from_character,
            self.target_distance_from_character,
            camera_follow_speed,
        );

        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const rescaled_camera_offset =
            rm.Vector3Scale(rm.Vector3Normalize(camera_offset), self.distance_from_character);
        self.camera.position = rm.Vector3Add(self.camera.target, rescaled_camera_offset);
    }

    fn getRay(self: ThirdPersonCamera, mouse_position_on_screen: rl.Vector2) rl.Ray {
        return rl.GetMouseRay(mouse_position_on_screen, self.camera);
    }
};

const InputConfiguration = struct {
    left: rl.KeyboardKey,
    right: rl.KeyboardKey,
    move_forward: rl.KeyboardKey,
    move_backwards: rl.KeyboardKey,
    strafe: rl.KeyboardKey,
};

const Player = struct {
    const State = struct {
        character: Character,
        camera: ThirdPersonCamera,

        /// Interpolate between this players state and another players state based on the given
        /// interval from 0 to 1.
        fn lerp(self: State, other: State, interval: f32) State {
            return State{
                .character = self.character.lerp(other.character, interval),
                .camera = self.camera.lerp(other.camera, interval),
            };
        }

        /// To be called once for each tick.
        fn update(self: *State, geometry: level_geometry.Collection) void {
            if (geometry.collidesWithCircle(self.character.boundaries)) |displacement_vector| {
                self.character.resolveCollision(displacement_vector);
            }
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
        const position_is_zero = std.math.fabs(starting_position_x) +
            std.math.fabs(starting_position_z) < util.Constants.epsilon;
        const direction_towards_center = if (position_is_zero)
            util.FlatVector{ .x = 0, .z = -1 }
        else
            util.FlatVector.normalize(util.FlatVector{
                .x = -starting_position_x,
                .z = -starting_position_z,
            });
        const character = Character.create(
            util.FlatVector{ .x = starting_position_x, .z = starting_position_z },
            direction_towards_center,
            0.3,
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

    /// To be called on every frame after rendering but before processing ticks.
    fn pollInputs(self: *Player, interval_between_previous_and_current_tick: f32) void {
        // Input is relative to the state currently on screen.
        const state_rendered_to_screen = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        var acceleration_direction = std.mem.zeroes(rl.Vector3);
        var turning_direction: f32 = 0;
        if (rl.IsKeyDown(self.input_configuration.left)) {
            if (rl.IsKeyDown(self.input_configuration.strafe)) {
                acceleration_direction = rm.Vector3Subtract(
                    acceleration_direction,
                    state_rendered_to_screen.character.getRightFromLookingDirection(),
                );
            } else {
                turning_direction -= 1;
            }
        }
        if (rl.IsKeyDown(self.input_configuration.right)) {
            if (rl.IsKeyDown(self.input_configuration.strafe)) {
                acceleration_direction = rm.Vector3Add(
                    acceleration_direction,
                    state_rendered_to_screen.character.getRightFromLookingDirection(),
                );
            } else {
                turning_direction += 1;
            }
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
        self.state_at_next_tick.character.setTurningDirection(turning_direction);
    }

    /// Behaves like letting go of all buttons/keys for this player.
    fn resetInputs(self: *Player) void {
        self.state_at_next_tick.character.setAcceleration(0, 0);
        self.state_at_next_tick.character.setTurningDirection(0);
    }

    /// To be called once for each tick.
    fn update(self: *Player, geometry: level_geometry.Collection) void {
        self.state_at_previous_tick = self.state_at_next_tick;
        self.state_at_next_tick.update(geometry);
    }

    fn draw(self: Player, interval_between_previous_and_current_tick: f32) void {
        self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).character.draw();
    }

    fn getCamera(self: Player, interval_between_previous_and_current_tick: f32) ThirdPersonCamera {
        return self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).camera;
    }
};

const RaylibError = error{
    UnableToCreateRenderTexture,
    FailedToLoadTextureFile,
};

const SplitScreenRenderContext = struct {
    prerendered_scene: rl.RenderTexture,
    destination_on_screen: rl.Rectangle,

    fn create(destination_on_screen: rl.Rectangle) RaylibError!SplitScreenRenderContext {
        const prerendered_scene = rl.LoadRenderTexture(
            @floatToInt(c_int, destination_on_screen.width),
            @floatToInt(c_int, destination_on_screen.height),
        );
        return if (prerendered_scene.id == 0)
            RaylibError.UnableToCreateRenderTexture
        else
            SplitScreenRenderContext{
                .prerendered_scene = prerendered_scene,
                .destination_on_screen = destination_on_screen,
            };
    }

    fn destroy(self: *SplitScreenRenderContext) void {
        rl.UnloadRenderTexture(self.prerendered_scene);
        self.prerendered_scene.id = 0;
    }

    fn prerenderScene(
        self: *SplitScreenRenderContext,
        players: []const Player,
        current_player: Player,
        geometry: level_geometry.Collection,
        interval_between_previous_and_current_tick: f32,
    ) void {
        rl.BeginTextureMode(self.prerendered_scene);

        // Handle walls between character and camera.
        const camera = current_player.getCamera(interval_between_previous_and_current_tick).camera;
        const ray_to_camera = rl.Ray{
            .position = camera.target,
            .direction = rm.Vector3Normalize(rm.Vector3Subtract(camera.position, camera.target)),
        };
        if (geometry.castRayToWalls(ray_to_camera)) |ray_collision| {
            const clamped_camera = clampCameraDistanceFromTarget(camera, ray_collision.distance);
            rl.BeginMode3D(clamped_camera);
        } else {
            rl.BeginMode3D(camera);
        }

        rl.ClearBackground(rl.Color{ .r = 140, .g = 190, .b = 214, .a = 255 });
        geometry.draw();
        for (players) |player| {
            player.draw(interval_between_previous_and_current_tick);
        }
        rl.EndMode3D();
        rl.EndTextureMode();
    }

    fn drawTextureToScreen(self: SplitScreenRenderContext) void {
        const source_rectangle = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = self.destination_on_screen.width,
            .height = -self.destination_on_screen.height,
        };
        rl.DrawTextureRec(
            self.prerendered_scene.texture,
            source_rectangle,
            rl.Vector2{ .x = self.destination_on_screen.x, .y = self.destination_on_screen.y },
            rl.WHITE,
        );
    }
};

const SplitScreenSetup = struct {
    render_contexts: []SplitScreenRenderContext,

    fn create(
        allocator: std.mem.Allocator,
        screen_width: u16,
        screen_height: u16,
        screen_splittings: u3,
    ) !SplitScreenSetup {
        const render_contexts = try allocator.alloc(SplitScreenRenderContext, screen_splittings);
        errdefer allocator.free(render_contexts);

        for (render_contexts) |*context, index| {
            const render_width = screen_width / screen_splittings;
            const destination_on_screen = rl.Rectangle{
                .x = @intToFloat(f32, render_width * index),
                .y = 0,
                .width = @intToFloat(f32, render_width),
                .height = @intToFloat(f32, screen_height),
            };
            context.* = SplitScreenRenderContext.create(destination_on_screen) catch |err| {
                for (render_contexts[0..index]) |*context_to_destroy| {
                    context_to_destroy.destroy();
                }
                return err;
            };
        }
        return SplitScreenSetup{ .render_contexts = render_contexts };
    }

    fn destroy(self: *SplitScreenSetup, allocator: std.mem.Allocator) void {
        for (self.render_contexts) |*context| {
            context.destroy();
        }
        allocator.free(self.render_contexts);
    }

    fn prerenderScenes(
        self: *SplitScreenSetup,
        /// Assumed to be at least as large as screen_splittings passed to create().
        players: []const Player,
        geometry: level_geometry.Collection,
        interval_between_previous_and_current_tick: f32,
    ) void {
        std.debug.assert(players.len >= self.render_contexts.len);
        for (self.render_contexts) |*context, index| {
            context.prerenderScene(
                players,
                players[index],
                geometry,
                interval_between_previous_and_current_tick,
            );
        }
    }

    fn drawToScreen(self: SplitScreenSetup) void {
        for (self.render_contexts) |context| {
            context.drawTextureToScreen();
        }
    }
};

fn loadTexture(path: [*:0]const u8) RaylibError!rl.Texture {
    const texture = rl.LoadTexture(path);
    if (texture.id == 0) {
        return RaylibError.FailedToLoadTextureFile;
    }
    return texture;
}

fn loadKnownTextures() ![2]rl.Texture {
    const wall_texture = try loadTexture("assets/wall.png");
    errdefer rl.UnloadTexture(wall_texture);
    const floor_texture = try loadTexture("assets/floor.png");
    return [_]rl.Texture{ wall_texture, floor_texture };
}

const InputPresets = struct {
    const Wasd = InputConfiguration{
        .left = rl.KeyboardKey.KEY_A,
        .right = rl.KeyboardKey.KEY_D,
        .move_forward = rl.KeyboardKey.KEY_W,
        .move_backwards = rl.KeyboardKey.KEY_S,
        .strafe = rl.KeyboardKey.KEY_LEFT_CONTROL,
    };
    const ArrowKeys = InputConfiguration{
        .left = rl.KeyboardKey.KEY_LEFT,
        .right = rl.KeyboardKey.KEY_RIGHT,
        .move_forward = rl.KeyboardKey.KEY_UP,
        .move_backwards = rl.KeyboardKey.KEY_DOWN,
        .strafe = rl.KeyboardKey.KEY_RIGHT_CONTROL,
    };
};

const ProgramMode = enum {
    TwoPlayerSplitScreen,
    Edit,
};

const EditModeView = enum {
    FromBehind,
    TopDown,
};

const EditMode = enum {
    PlaceWalls,
    DeleteWalls,
};

const CurrentlyEditedWall = struct { id: u64, start_position: rl.Vector3 };

pub fn main() !void {
    var screen_width: u16 = 1200;
    var screen_height: u16 = 850;
    rl.InitWindow(screen_width, screen_height, "3D Zig Game");
    defer rl.CloseWindow();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var available_players = [_]Player{
        // Admin for map editing.
        Player.create(0, 0, rl.Color{ .r = 140, .g = 17, .b = 39, .a = 150 }, InputPresets.ArrowKeys),
        Player.create(28, 28, rl.Color{ .r = 154, .g = 205, .b = 50, .a = 150 }, InputPresets.Wasd),
        Player.create(12, 34, rl.Color{ .r = 142, .g = 223, .b = 255, .a = 150 }, InputPresets.ArrowKeys),
    };

    var program_mode = ProgramMode.TwoPlayerSplitScreen;
    var edit_mode_view = EditModeView.FromBehind;
    var edit_mode = EditMode.PlaceWalls;
    var active_players: []Player = available_players[1..];
    var controllable_players: []Player = active_players;
    var split_screen_setup = try SplitScreenSetup.create(gpa.allocator(), screen_width, screen_height, 2);
    defer split_screen_setup.destroy(gpa.allocator());

    const known_textures = try loadKnownTextures();
    var geometry = try level_geometry.Collection.create(
        gpa.allocator(),
        known_textures[0],
        known_textures[1],
        5.0,
    );
    defer geometry.destroy(gpa.allocator());
    var currently_edited_wall: ?CurrentlyEditedWall = null;

    var tick_timer = try TickTimer.start(60);
    while (!rl.WindowShouldClose()) {
        const lap_result = tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            for (active_players) |*player| {
                player.update(geometry);
            }
        }

        split_screen_setup.prerenderScenes(active_players, geometry, lap_result.next_tick_progress);

        rl.BeginDrawing();
        split_screen_setup.drawToScreen();
        drawFpsCounter();
        rl.EndDrawing();

        for (controllable_players) |*player| {
            player.pollInputs(lap_result.next_tick_progress);
        }

        var reinit_split_screen_setup = false;
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER)) {
            switch (program_mode) {
                ProgramMode.TwoPlayerSplitScreen => {
                    program_mode = ProgramMode.Edit;
                    active_players = available_players[0..];
                    controllable_players = available_players[0..1];
                },
                ProgramMode.Edit => {
                    program_mode = ProgramMode.TwoPlayerSplitScreen;
                    active_players = available_players[1..];
                    controllable_players = active_players;
                },
            }
            reinit_split_screen_setup = true;

            for (available_players) |*player| {
                player.resetInputs();
            }
        }
        if (program_mode == ProgramMode.Edit) {
            if (std.math.fabs(rl.GetMouseWheelMoveV().y) > util.Constants.epsilon) {
                active_players[0].state_at_next_tick.camera
                    .increaseDistanceToCharacter(-rl.GetMouseWheelMoveV().y * 2.5);
            }
            if (rl.IsKeyPressed(rl.KeyboardKey.KEY_T)) {
                switch (edit_mode_view) {
                    EditModeView.FromBehind => {
                        edit_mode_view = EditModeView.TopDown;
                        active_players[0].state_at_next_tick.camera
                            .setAngleFromGround(util.degreesToRadians(90));
                    },
                    EditModeView.TopDown => {
                        edit_mode_view = EditModeView.FromBehind;
                        active_players[0].state_at_next_tick.camera
                            .setAngleFromGround(ThirdPersonCamera.default_angle_from_ground);
                    },
                }
            }
            if (rl.IsKeyPressed(rl.KeyboardKey.KEY_DELETE)) {
                edit_mode = switch (edit_mode) {
                    EditMode.PlaceWalls => EditMode.DeleteWalls,
                    EditMode.DeleteWalls => EditMode.PlaceWalls,
                };
                if (currently_edited_wall) |wall| {
                    geometry.tintWall(wall.id, level_geometry.Tint.Default);
                    currently_edited_wall = null;
                }
            }

            const ray = active_players[0].getCamera(lap_result.next_tick_progress)
                .getRay(rl.GetMousePosition());
            switch (edit_mode) {
                EditMode.PlaceWalls => {
                    if (currently_edited_wall) |*wall| {
                        if (rm.Vector2Length(rl.GetMouseDelta()) > util.Constants.epsilon) {
                            if (geometry.castRayToFloor(ray)) |position_on_grid| {
                                geometry.updateWall(
                                    wall.id,
                                    wall.start_position.x,
                                    wall.start_position.z,
                                    position_on_grid.x,
                                    position_on_grid.z,
                                );
                            }
                        }
                        if (rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                            geometry.tintWall(wall.id, level_geometry.Tint.Default);
                            currently_edited_wall = null;
                        }
                    } else if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                        if (geometry.castRayToFloor(ray)) |position_on_grid| {
                            const wall_id = try geometry.addWall(
                                position_on_grid.x,
                                position_on_grid.z,
                                position_on_grid.x,
                                position_on_grid.z,
                            );
                            geometry.tintWall(wall_id, level_geometry.Tint.Green);
                            currently_edited_wall =
                                CurrentlyEditedWall{ .id = wall_id, .start_position = position_on_grid };
                        }
                    }
                },
                EditMode.DeleteWalls => {
                    if (rm.Vector2Length(rl.GetMouseDelta()) > util.Constants.epsilon) {
                        if (currently_edited_wall) |wall| {
                            geometry.tintWall(wall.id, level_geometry.Tint.Default);
                            currently_edited_wall = null;
                        }
                        if (geometry.castRayToWalls(ray)) |ray_collision| {
                            geometry.tintWall(ray_collision.wall_id, level_geometry.Tint.Red);
                            currently_edited_wall = CurrentlyEditedWall{
                                .id = ray_collision.wall_id,
                                .start_position = std.mem.zeroes(rl.Vector3),
                            };
                        }
                    }
                    if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                        if (currently_edited_wall) |wall| {
                            geometry.removeWall(wall.id);
                            currently_edited_wall = null;
                        }
                    }
                },
            }
        }
        if (rl.IsWindowResized()) {
            screen_width = @intCast(u16, rl.GetScreenWidth());
            screen_height = @intCast(u16, rl.GetScreenHeight());
            reinit_split_screen_setup = true;
        }
        if (reinit_split_screen_setup) {
            const screen_splittings: u3 = switch (program_mode) {
                ProgramMode.TwoPlayerSplitScreen => 2,
                ProgramMode.Edit => 1,
            };
            const new_split_screen_setup =
                try SplitScreenSetup.create(gpa.allocator(), screen_width, screen_height, screen_splittings);
            split_screen_setup.destroy(gpa.allocator());
            split_screen_setup = new_split_screen_setup;
        }
    }
}
