const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const gems = @import("gems.zig");
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const loadBillboardShader = @import("billboard_shader.zig").load;

fn lerpColor(a: rl.Color, b: rl.Color, interval: f32) rl.Color {
    return rl.Color{
        .r = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.r), @intToFloat(f32, b.r), interval)),
        .g = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.g), @intToFloat(f32, b.g), interval)),
        .b = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.b), @intToFloat(f32, b.b), interval)),
        .a = @floatToInt(u8, rm.Lerp(@intToFloat(f32, a.a), @intToFloat(f32, b.a), interval)),
    };
}

const Character = struct {
    boundaries: collision.Circle,
    looking_direction: util.FlatVector,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: f32,
    acceleration_direction: util.FlatVector,
    velocity: util.FlatVector,
    height: f32,

    fn create(
        position: util.FlatVector,
        looking_direction: util.FlatVector,
        radius: f32,
        height: f32,
    ) Character {
        return Character{
            .boundaries = collision.Circle{ .position = position, .radius = radius },
            .looking_direction = looking_direction.normalize(),
            .turning_direction = 0,
            .acceleration_direction = util.FlatVector{ .x = 0, .z = 0 },
            .velocity = util.FlatVector{ .x = 0, .z = 0 },
            .height = height,
        };
    }

    /// Interpolate between this characters state and another characters state based on the given
    /// interval from 0 to 1.
    fn lerp(self: Character, other: Character, interval: f32) Character {
        const i = std.math.clamp(interval, 0, 1);
        return Character{
            .boundaries = self.boundaries.lerp(other.boundaries, i),
            .looking_direction = self.looking_direction.lerp(other.looking_direction, i),
            .turning_direction = rm.Lerp(self.turning_direction, other.turning_direction, i),
            .acceleration_direction = self.acceleration_direction.lerp(other.acceleration_direction, i),
            .velocity = self.velocity.lerp(other.velocity, i),
            .height = rm.Lerp(self.height, other.height, i),
        };
    }

    /// Given direction values will be normalized.
    fn setAcceleration(self: *Character, direction: util.FlatVector) void {
        self.acceleration_direction = direction.normalize();
    }

    /// Value from -1 (left) to 1 (right). Will be clamped into this range.
    fn setTurningDirection(self: *Character, turning_direction: f32) void {
        self.turning_direction = rm.Clamp(turning_direction, -1, 1);
    }

    fn resolveCollision(self: *Character, displacement_vector: util.FlatVector) void {
        self.boundaries.position = self.boundaries.position.add(displacement_vector);
        const dot_product = std.math.clamp(self.velocity.normalize()
            .dotProduct(displacement_vector.normalize()), -1, 1);
        const moving_against_displacement_vector =
            self.velocity.dotProduct(displacement_vector) < 0;
        if (moving_against_displacement_vector) {
            self.velocity = self.velocity.scale(1 + dot_product);
        }
    }

    fn processElapsedTick(self: *Character) void {
        self.boundaries.position = self.boundaries.position.add(self.velocity);

        const is_accelerating = self.acceleration_direction.length() > util.Constants.epsilon;
        if (is_accelerating) {
            self.velocity = self.velocity.add(self.acceleration_direction.scale(0.03));
            if (self.velocity.length() > 0.2) {
                self.velocity = self.velocity.normalize().scale(0.2);
            }
        } else {
            self.velocity = self.velocity.scale(0.7);
        }

        const max_rotation_per_tick = util.degreesToRadians(3.5);
        const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
        self.looking_direction = self.looking_direction.rotate(rotation_angle);
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
    /// Unique identifier distinct from all other players.
    id: u64,
    state_at_next_tick: State,
    state_at_previous_tick: State,
    gem_count: u64,

    fn create(
        id: u64,
        starting_position_x: f32,
        starting_position_z: f32,
        spritesheet: rl.Texture,
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

        const in_game_heigth = 1.8;
        const frame_ratio = getFrameHeight(spritesheet) / getFrameWidth(spritesheet);
        const character = Character.create(
            util.FlatVector{ .x = starting_position_x, .z = starting_position_z },
            direction_towards_center,
            in_game_heigth / frame_ratio / 2.0,
            in_game_heigth,
        );
        const state = State{
            .character = character,
            .camera = ThirdPersonCamera.create(
                character.boundaries.position.toVector3(),
                character.looking_direction,
            ),
            .animation_cycle = 0,
            .animation_frame = 0,
        };
        return Player{
            .id = id,
            .state_at_next_tick = state,
            .state_at_previous_tick = state,
            .gem_count = 0,
        };
    }

    /// To be called on every frame after rendering but before processing ticks.
    fn pollInputs(self: *Player, interval_between_previous_and_current_tick: f32) void {
        // Input is relative to the state currently on screen.
        const state_rendered_to_screen = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        var acceleration_direction = util.FlatVector{ .x = 0, .z = 0 };
        var turning_direction: f32 = 0;
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT)) {
            if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
                acceleration_direction = acceleration_direction.subtract(
                    state_rendered_to_screen.character.looking_direction.rotateRightBy90Degrees(),
                );
            } else {
                turning_direction -= 1;
            }
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT)) {
            if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
                acceleration_direction = acceleration_direction.add(
                    state_rendered_to_screen.character.looking_direction.rotateRightBy90Degrees(),
                );
            } else {
                turning_direction += 1;
            }
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_UP)) {
            acceleration_direction = acceleration_direction.add(
                state_rendered_to_screen.character.looking_direction,
            );
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN)) {
            acceleration_direction = acceleration_direction.subtract(
                state_rendered_to_screen.character.looking_direction,
            );
        }
        self.state_at_next_tick.character.setAcceleration(acceleration_direction);
        self.state_at_next_tick.character.setTurningDirection(turning_direction);
    }

    /// Behaves like letting go of all buttons/keys for this player.
    fn resetInputs(self: *Player) void {
        self.state_at_next_tick.character.setAcceleration(util.FlatVector{ .x = 0, .z = 0 });
        self.state_at_next_tick.character.setTurningDirection(0);
    }

    fn processElapsedTick(
        self: *Player,
        level_geometry: LevelGeometry,
        gem_collection: *gems.Collection,
    ) void {
        self.state_at_previous_tick = self.state_at_next_tick;
        self.state_at_next_tick.processElapsedTick(level_geometry);
        self.gem_count = self.gem_count + gem_collection.processCollision(gems.CollisionObject{
            .id = self.id,
            .boundaries = self.state_at_next_tick.character.boundaries,
            .height = self.state_at_next_tick.character.height,
        }, level_geometry);
    }

    fn draw(
        self: Player,
        camera: rl.Camera,
        spritesheet: rl.Texture,
        is_main_character: bool,
        interval_between_previous_and_current_tick: f32,
    ) void {
        const state_to_render = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );
        const direction = if (is_main_character)
            Direction.Back
        else
            Direction.Front;

        const render_position_3d = rl.Vector3{
            .x = state_to_render.character.boundaries.position.x,
            .y = state_to_render.character.height / 2,
            .z = state_to_render.character.boundaries.position.z,
        };
        rl.DrawBillboardRec(
            camera,
            spritesheet,
            getSpritesheetSource(state_to_render, spritesheet, direction),
            render_position_3d,
            rl.Vector2{
                .x = state_to_render.character.height, // Render width is derived from source width.
                .y = state_to_render.character.height,
            },
            rl.WHITE,
        );
    }

    fn getCamera(self: Player, interval_between_previous_and_current_tick: f32) ThirdPersonCamera {
        return self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).camera;
    }

    fn getLerpedCollisionObject(
        self: Player,
        interval_between_previous_and_current_tick: f32,
    ) gems.CollisionObject {
        const character = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).character;
        return gems.CollisionObject{
            .id = self.id,
            .boundaries = character.boundaries,
            .height = character.height,
        };
    }

    const Direction = enum { Front, Back };

    fn getSpritesheetSource(state_to_render: State, spritesheet: rl.Texture, side: Direction) rl.Rectangle {
        const w = getFrameWidth(spritesheet);
        const h = getFrameHeight(spritesheet);
        const min_velocity_for_animation = 0.02;

        // Loop from 0 -> 1 -> 2 -> 1 -> 0.
        const animation_frame =
            if (state_to_render.character.velocity.length() < min_velocity_for_animation or
            state_to_render.animation_frame == 3)
            1
        else
            state_to_render.animation_frame;
        const x = w * @intToFloat(f32, animation_frame);
        return switch (side) {
            Direction.Front => rl.Rectangle{ .x = x, .y = h, .width = w, .height = h },
            Direction.Back => rl.Rectangle{ .x = x, .y = 0, .width = w, .height = h },
        };
    }

    fn getFrameWidth(spritesheet: rl.Texture) f32 {
        return @intToFloat(f32, @divTrunc(spritesheet.width, 3));
    }
    fn getFrameHeight(spritesheet: rl.Texture) f32 {
        return @intToFloat(f32, @divTrunc(spritesheet.height, 2));
    }

    const State = struct {
        character: Character,
        camera: ThirdPersonCamera,
        /// Loops from 0 to 1 and wraps around to 0.
        animation_cycle: f32,
        /// Four animation frames.
        animation_frame: u2,

        /// Interpolate between this players state and another players state based on the given
        /// interval from 0 to 1.
        fn lerp(self: State, other: State, interval: f32) State {
            return State{
                .character = self.character.lerp(other.character, interval),
                .camera = self.camera.lerp(other.camera, interval),
                .animation_cycle = rm.Lerp(self.animation_cycle, other.animation_cycle, interval),
                .animation_frame = if (interval < 0.5)
                    self.animation_frame
                else
                    other.animation_frame,
            };
        }

        fn processElapsedTick(self: *State, level_geometry: LevelGeometry) void {
            if (level_geometry.collidesWithCircle(self.character.boundaries)) |displacement_vector| {
                self.character.resolveCollision(displacement_vector);
            }
            self.character.processElapsedTick();
            self.camera.processElapsedTick(
                self.character.boundaries.position.toVector3(),
                self.character.looking_direction,
            );
            self.animation_cycle = self.animation_cycle + self.character.velocity.length() * 0.75;
            if (self.animation_cycle > 1) {
                self.animation_cycle = 0;
                self.animation_frame = self.animation_frame +% 1;
            }
        }
    };
};

fn drawEverything(
    screen_height: u16,
    players: []const Player,
    current_player: Player,
    player_spritesheet: rl.Texture,
    level_geometry: LevelGeometry,
    gem_collection: gems.Collection,
    gem_texture: rl.Texture,
    billboard_shader: rl.Shader,
    interval_between_previous_and_current_tick: f32,
) void {
    const lerped_camera = current_player.getCamera(interval_between_previous_and_current_tick);

    const max_distance_from_target =
        if (level_geometry.cast3DRayToWalls(lerped_camera.get3DRayFromTargetToSelf())) |ray_collision|
        ray_collision.distance
    else
        null;
    const raylib_camera = lerped_camera.getRaylibCamera(max_distance_from_target);

    rl.BeginDrawing();
    rl.BeginMode3D(raylib_camera);
    rl.ClearBackground(rl.Color{ .r = 140, .g = 190, .b = 214, .a = 255 });
    level_geometry.draw();

    var collision_objects: [4]gems.CollisionObject = undefined;
    std.debug.assert(players.len <= collision_objects.len);
    for (players) |player, index| {
        collision_objects[index] =
            player.getLerpedCollisionObject(interval_between_previous_and_current_tick);
    }

    rl.BeginShaderMode(billboard_shader);
    gem_collection.draw(
        raylib_camera,
        gem_texture,
        collision_objects[0..players.len],
        interval_between_previous_and_current_tick,
    );
    for (players) |*player| {
        player.draw(
            raylib_camera,
            player_spritesheet,
            player.id == current_player.id,
            interval_between_previous_and_current_tick,
        );
    }
    rl.EndShaderMode();
    rl.EndMode3D();

    drawGemCount(screen_height, gem_texture, current_player.gem_count);

    var string_buffer: [16]u8 = undefined;
    const fps_string = std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()}) catch "";
    rl.DrawText(fps_string, 5, 5, 20, rl.BLACK);
    rl.EndDrawing();
}

fn drawGemCount(
    screen_height: u16,
    gem_texture: rl.Texture,
    gem_count: u64,
) void {
    const scale = 3;
    const on_screen_width = gem_texture.width * scale;
    const on_screen_height = gem_texture.height * scale;
    const margin_from_borders = 8;
    const gem_on_screen_position = rl.Vector2{
        .x = margin_from_borders,
        .y = @intToFloat(f32, screen_height - margin_from_borders - on_screen_height),
    };
    var string_buffer: [16]u8 = undefined;
    const count_string = std.fmt.bufPrintZ(string_buffer[0..], "x{}", .{gem_count}) catch "";

    rl.DrawTextureEx(gem_texture, gem_on_screen_position, 0, scale, rl.WHITE);
    rl.DrawText(
        count_string,
        @floatToInt(c_int, gem_on_screen_position.x) + on_screen_width + margin_from_borders,
        @floatToInt(c_int, gem_on_screen_position.y),
        @floatToInt(c_int, 17.5 * @intToFloat(f32, scale)),
        rl.BLACK,
    );
}

fn loadTexture(path: [*:0]const u8) util.RaylibError!rl.Texture {
    const texture = rl.LoadTexture(path);
    if (texture.id == 0) {
        return util.RaylibError.FailedToLoadTextureFile;
    }
    return texture;
}

fn loadKnownTextures() ![4]rl.Texture {
    const wall_texture = try loadTexture("assets/wall.png");
    errdefer rl.UnloadTexture(wall_texture);
    const floor_texture = try loadTexture("assets/floor.png");
    errdefer rl.UnloadTexture(floor_texture);
    const player_texture = try loadTexture("assets/player.png");
    errdefer rl.UnloadTexture(player_texture);
    const gem_texture = try loadTexture("assets/gem.png");
    errdefer rl.UnloadTexture(gem_texture);

    return [_]rl.Texture{ wall_texture, floor_texture, player_texture, gem_texture };
}

const EditModeView = enum {
    FromBehind,
    TopDown,
};

const EditMode = enum {
    PlaceWalls,
    DeleteWalls,
};

const CurrentlyEditedWall = struct { id: u64, start_position: util.FlatVector };

pub fn main() !void {
    var screen_width: u16 = 1280;
    var screen_height: u16 = 720;
    rl.InitWindow(screen_width, screen_height, "3D Zig Game");
    defer rl.CloseWindow();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const billboard_shader = try loadBillboardShader();
    defer rl.UnloadShader(billboard_shader);

    const known_textures = try loadKnownTextures();
    defer rl.UnloadTexture(known_textures[2]);
    defer rl.UnloadTexture(known_textures[3]);
    var players = [_]Player{
        Player.create(1, 28, 28, known_textures[2]),
        Player.create(2, 5, 14, known_textures[2]),
    };
    var controllable_player_index: usize = 0;

    var edit_mode_view = EditModeView.FromBehind;
    var edit_mode = EditMode.PlaceWalls;

    var level_geometry = try LevelGeometry.create(
        gpa.allocator(),
        known_textures[0],
        known_textures[1],
        5.0,
    );
    defer level_geometry.destroy(gpa.allocator());
    var currently_edited_wall: ?CurrentlyEditedWall = null;

    var gem_collection = gems.Collection.create(gpa.allocator());
    defer gem_collection.destroy();

    var prng = std.rand.DefaultPrng.init(0);

    var tick_timer = try util.TickTimer.start(60);
    while (!rl.WindowShouldClose()) {
        const lap_result = tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            for (players) |*player| {
                player.processElapsedTick(level_geometry, &gem_collection);
                gem_collection.processElapsedTick();
            }
        }

        drawEverything(
            screen_height,
            players[0..],
            players[controllable_player_index],
            known_textures[2],
            level_geometry,
            gem_collection,
            known_textures[3],
            billboard_shader,
            lap_result.next_tick_progress,
        );

        players[controllable_player_index].pollInputs(lap_result.next_tick_progress);

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER)) {
            for (players) |*player| {
                player.resetInputs();
            }
            controllable_player_index = (controllable_player_index + 1) % players.len;
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_BACKSPACE)) {
            var counter: usize = 0;
            while (counter < 500) : (counter += 1) {
                _ = try gem_collection.addGem(util.FlatVector{
                    .x = (std.rand.Random.float(prng.random(), f32) - 0.5) * 50,
                    .z = (std.rand.Random.float(prng.random(), f32) - 0.5) * 50,
                });
            }
        }
        if (std.math.fabs(rl.GetMouseWheelMoveV().y) > util.Constants.epsilon) {
            players[controllable_player_index].state_at_next_tick.camera
                .increaseDistanceToObject(-rl.GetMouseWheelMoveV().y * 2.5);
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_T)) {
            switch (edit_mode_view) {
                EditModeView.FromBehind => {
                    edit_mode_view = EditModeView.TopDown;
                    players[controllable_player_index].state_at_next_tick.camera
                        .setAngleFromGround(util.degreesToRadians(90));
                },
                EditModeView.TopDown => {
                    edit_mode_view = EditModeView.FromBehind;
                    players[controllable_player_index].state_at_next_tick.camera
                        .resetAngleFromGround();
                },
            }
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_DELETE)) {
            edit_mode = switch (edit_mode) {
                EditMode.PlaceWalls => EditMode.DeleteWalls,
                EditMode.DeleteWalls => EditMode.PlaceWalls,
            };
            if (currently_edited_wall) |wall| {
                level_geometry.tintWall(wall.id, rl.WHITE);
                currently_edited_wall = null;
            }
        }

        const ray = players[controllable_player_index].getCamera(lap_result.next_tick_progress)
            .get3DRay(rl.GetMousePosition());
        switch (edit_mode) {
            EditMode.PlaceWalls => {
                if (currently_edited_wall) |*wall| {
                    if (rm.Vector2Length(rl.GetMouseDelta()) > util.Constants.epsilon) {
                        if (level_geometry.cast3DRayToGround(ray)) |position_on_grid| {
                            level_geometry.updateWall(wall.id, wall.start_position, position_on_grid);
                        }
                    }
                    if (rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                        level_geometry.tintWall(wall.id, rl.WHITE);
                        currently_edited_wall = null;
                    }
                } else if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                    if (level_geometry.cast3DRayToGround(ray)) |position_on_grid| {
                        const wall_id = try level_geometry.addWall(position_on_grid, position_on_grid);
                        level_geometry.tintWall(wall_id, rl.GREEN);
                        currently_edited_wall =
                            CurrentlyEditedWall{ .id = wall_id, .start_position = position_on_grid };
                    }
                }
            },
            EditMode.DeleteWalls => {
                if (rm.Vector2Length(rl.GetMouseDelta()) > util.Constants.epsilon) {
                    if (currently_edited_wall) |wall| {
                        level_geometry.tintWall(wall.id, rl.WHITE);
                        currently_edited_wall = null;
                    }
                    if (level_geometry.cast3DRayToWalls(ray)) |ray_collision| {
                        level_geometry.tintWall(ray_collision.wall_id, rl.RED);
                        currently_edited_wall = CurrentlyEditedWall{
                            .id = ray_collision.wall_id,
                            .start_position = util.FlatVector{ .x = 0, .z = 0 },
                        };
                    }
                }
                if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                    if (currently_edited_wall) |wall| {
                        level_geometry.removeWall(wall.id);
                        currently_edited_wall = null;
                    }
                }
            },
        }
        if (rl.IsWindowResized()) {
            screen_width = @intCast(u16, rl.GetScreenWidth());
            screen_height = @intCast(u16, rl.GetScreenHeight());
        }
    }
}
