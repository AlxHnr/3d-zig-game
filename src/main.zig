const animation = @import("animation.zig");
const collision = @import("collision.zig");
const edit_mode = @import("edit_mode.zig");
const gems = @import("gems.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const textures = @import("textures.zig");
const util = @import("util.zig");
const glad = @cImport(@cInclude("external/glad.h"));
const rendering = @import("rendering.zig");
const math = @import("math.zig");

const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const loadGenericShader = @import("generic_shader.zig").load;

const Character = struct {
    boundaries: collision.Circle,
    looking_direction: math.FlatVector,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: f32,
    acceleration_direction: math.FlatVector,
    velocity: math.FlatVector,
    height: f32,

    fn create(
        position: math.FlatVector,
        looking_direction: math.FlatVector,
        radius: f32,
        height: f32,
    ) Character {
        return Character{
            .boundaries = collision.Circle{ .position = position, .radius = radius },
            .looking_direction = looking_direction.normalize(),
            .turning_direction = 0,
            .acceleration_direction = .{ .x = 0, .z = 0 },
            .velocity = .{ .x = 0, .z = 0 },
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
            .turning_direction = math.lerp(self.turning_direction, other.turning_direction, i),
            .acceleration_direction = self.acceleration_direction.lerp(other.acceleration_direction, i),
            .velocity = self.velocity.lerp(other.velocity, i),
            .height = math.lerp(self.height, other.height, i),
        };
    }

    /// Given direction values will be normalized.
    fn setAcceleration(self: *Character, direction: math.FlatVector) void {
        self.acceleration_direction = direction.normalize();
    }

    /// Value from -1 (left) to 1 (right). Will be clamped into this range.
    fn setTurningDirection(self: *Character, turning_direction: f32) void {
        self.turning_direction = std.math.clamp(turning_direction, -1, 1);
    }

    fn resolveCollision(self: *Character, displacement_vector: math.FlatVector) void {
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

        const is_accelerating = self.acceleration_direction.length() > math.epsilon;
        if (is_accelerating) {
            const max_velocity = 0.15;
            const acceleration = max_velocity / 5.0;
            self.velocity = self.velocity.add(self.acceleration_direction.scale(acceleration));
            if (self.velocity.length() > max_velocity) {
                self.velocity = self.velocity.normalize().scale(max_velocity);
            }
        } else {
            self.velocity = self.velocity.scale(0.7);
        }

        const max_rotation_per_tick = math.degreesToRadians(3.5);
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
            std.math.fabs(starting_position_z) < math.epsilon;
        const direction_towards_center =
            if (position_is_zero)
            math.FlatVector{ .x = 0, .z = -1 }
        else
            math.FlatVector.normalize(.{
                .x = -starting_position_x,
                .z = -starting_position_z,
            });

        const in_game_heigth = 1.8;
        const frame_ratio = getFrameHeight(spritesheet) / getFrameWidth(spritesheet);
        const character = Character.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            direction_towards_center,
            in_game_heigth / frame_ratio / 2.0,
            in_game_heigth,
        );
        const state = State{
            .character = character,
            .camera = ThirdPersonCamera.create(
                character.boundaries.position,
                character.looking_direction,
            ),
            .animation_cycle = animation.FourStepCycle.create(),
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
        const forward_direction = state_rendered_to_screen.camera
            .getDirectionToTarget().toFlatVector();
        const right_direction = forward_direction.rotateRightBy90Degrees();

        var acceleration_direction = math.FlatVector{ .x = 0, .z = 0 };
        var turning_direction: f32 = 0;
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT)) {
            if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
                acceleration_direction = acceleration_direction.subtract(right_direction);
            } else if (rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT_CONTROL)) {
                turning_direction -= 0.05;
            } else {
                turning_direction -= 1;
            }
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT)) {
            if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
                acceleration_direction = acceleration_direction.add(right_direction);
            } else if (rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT_CONTROL)) {
                turning_direction += 0.05;
            } else {
                turning_direction += 1;
            }
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_UP)) {
            acceleration_direction = acceleration_direction.add(forward_direction);
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN)) {
            acceleration_direction = acceleration_direction.subtract(forward_direction);
        }
        self.state_at_next_tick.character.setAcceleration(acceleration_direction);
        self.state_at_next_tick.character.setTurningDirection(turning_direction);
    }

    /// Behaves like letting go of all buttons/keys for this player.
    fn resetInputs(self: *Player) void {
        self.state_at_next_tick.character.setAcceleration(.{ .x = 0, .z = 0 });
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
            Direction.back
        else
            Direction.front;

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

    const Direction = enum { front, back };

    fn getSpritesheetSource(state_to_render: State, spritesheet: rl.Texture, side: Direction) rl.Rectangle {
        const w = getFrameWidth(spritesheet);
        const h = getFrameHeight(spritesheet);
        const min_velocity_for_animation = 0.02;

        const animation_frame =
            if (state_to_render.character.velocity.length() < min_velocity_for_animation)
            1
        else
            state_to_render.animation_cycle.getFrame();

        const x = w * @intToFloat(f32, animation_frame);
        return switch (side) {
            .front => rl.Rectangle{ .x = x, .y = h, .width = w, .height = h },
            .back => rl.Rectangle{ .x = x, .y = 0, .width = w, .height = h },
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
        animation_cycle: animation.FourStepCycle,

        /// Interpolate between this players state and another players state based on the given
        /// interval from 0 to 1.
        fn lerp(self: State, other: State, interval: f32) State {
            return State{
                .character = self.character.lerp(other.character, interval),
                .camera = self.camera.lerp(other.camera, interval),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, interval),
            };
        }

        fn processElapsedTick(self: *State, level_geometry: LevelGeometry) void {
            if (level_geometry.collidesWithCircle(self.character.boundaries)) |displacement_vector| {
                self.character.resolveCollision(displacement_vector);
            }
            self.character.processElapsedTick();
            self.camera.processElapsedTick(
                self.character.boundaries.position,
                self.character.looking_direction,
            );
            self.animation_cycle.processElapsedTick(self.character.velocity.length() * 0.75);
        }
    };
};

fn drawEverything(
    allocator: std.mem.Allocator,
    screen_width: u16,
    screen_height: u16,
    players: []const Player,
    current_player: Player,
    level_geometry: *LevelGeometry,
    texture_collection: textures.Collection,
    shader: rl.Shader,
    edit_mode_state: edit_mode.State,
    billboard_renderer: rendering.BillboardRenderer,
    interval_between_previous_and_current_tick: f32,
) !void {
    const camera = current_player.getCamera(interval_between_previous_and_current_tick);

    const max_distance_from_target =
        if (level_geometry
        .cast3DRayToWalls(camera.get3DRayFromTargetToSelf(), true)) |ray_collision|
        ray_collision.impact_point.distance_from_start_position
    else
        null;
    const raylib_camera = camera.getRaylibCamera(max_distance_from_target);

    rl.BeginDrawing();
    rl.BeginMode3D(raylib_camera);

    glad.glClearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT | glad.GL_DEPTH_BUFFER_BIT | glad.GL_STENCIL_BUFFER_BIT);

    var vp_matrix =
        camera.getViewProjectionMatrix(screen_width, screen_height, max_distance_from_target);

    try level_geometry.prepareRender(allocator);
    level_geometry.render(vp_matrix, camera.getDirectionToTarget(), texture_collection);

    billboard_renderer.render(
        vp_matrix,
        camera.getDirectionToTarget(),
        texture_collection.get(.gem).id,
    );

    rl.BeginShaderMode(shader);
    for (players) |*player| {
        player.draw(
            raylib_camera,
            texture_collection.get(.player),
            player.id == current_player.id,
            interval_between_previous_and_current_tick,
        );
    }
    rl.EndShaderMode();
    rl.EndMode3D();

    drawGemCount(
        screen_height,
        texture_collection.get(.gem),
        current_player.gem_count,
    );

    var string_buffer: [128]u8 = undefined;
    const edit_mode_descripiton = edit_mode_state.describe(string_buffer[0..]) catch "";
    rl.DrawText(edit_mode_descripiton, 5, 5, 20, rl.BLACK);

    const fps_string = std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()}) catch "";
    rl.DrawText(fps_string, 5, 25, 20, rl.BLACK);

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

const ViewMode = enum { from_behind, top_down };

const CurrentlyEditedObject = struct {
    object_id: u64,
    start_position: math.FlatVector,
};

fn reloadDefaultMap(allocator: std.mem.Allocator, level_geometry: *LevelGeometry) !void {
    var json = try std.fs.cwd().readFileAlloc(allocator, "maps/default.json", 20 * 1024 * 1024);
    defer allocator.free(json);

    const geometry = try LevelGeometry.createFromJson(allocator, json);
    level_geometry.destroy();
    level_geometry.* = geometry;
}

pub fn main() !void {
    var screen_width: u16 = 1600;
    var screen_height: u16 = 900;
    rl.InitWindow(screen_width, screen_height, "3D Zig Game");
    defer rl.CloseWindow();

    glad.glEnable(glad.GL_STENCIL_TEST);
    glad.glStencilOp(glad.GL_KEEP, glad.GL_KEEP, glad.GL_REPLACE);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var shader = try loadGenericShader();
    defer rl.UnloadShader(shader);

    var texture_collection = try textures.Collection.loadFromDisk();
    defer texture_collection.destroy();

    var players = [_]Player{
        Player.create(0, 0, -10, texture_collection.get(.player)),
        Player.create(1, 0, 10, texture_collection.get(.player)),
    };
    var controllable_player_index: usize = 0;

    var level_geometry = try LevelGeometry.create(gpa.allocator());
    defer level_geometry.destroy();
    try reloadDefaultMap(gpa.allocator(), &level_geometry);

    var gem_collection = gems.Collection.create(gpa.allocator());
    defer gem_collection.destroy();

    var view_mode = ViewMode.from_behind;
    var edit_mode_state = edit_mode.State.create();

    var billboard_renderer = try rendering.BillboardRenderer.create();
    defer billboard_renderer.destroy();

    var billboard_buffer: []rendering.BillboardRenderer.BillboardData =
        &[0]rendering.BillboardRenderer.BillboardData{};
    defer gpa.allocator().free(billboard_buffer);

    var tick_timer = try util.TickTimer.start(60);
    while (!rl.WindowShouldClose()) {
        const lap_result = tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            for (players) |*player| {
                level_geometry.processElapsedTick();
                player.processElapsedTick(level_geometry, &gem_collection);
                gem_collection.processElapsedTick();
            }
        }

        const billboards_to_render = gem_collection.getBillboardCount();
        if (billboard_buffer.len < billboards_to_render) {
            billboard_buffer = try gpa.allocator().realloc(billboard_buffer, billboards_to_render);
        }

        var collision_objects: [4]gems.CollisionObject = undefined;
        std.debug.assert(players.len <= collision_objects.len);
        for (players) |player, index| {
            collision_objects[index] = player
                .getLerpedCollisionObject(lap_result.next_tick_progress);
        }
        gem_collection.populateBillboardData(
            billboard_buffer,
            collision_objects[0..players.len],
            lap_result.next_tick_progress,
        );
        billboard_renderer.uploadBillboards(billboard_buffer[0..billboards_to_render]);

        try drawEverything(
            gpa.allocator(),
            screen_width,
            screen_height,
            players[0..],
            players[controllable_player_index],
            &level_geometry,
            texture_collection,
            shader,
            edit_mode_state,
            billboard_renderer,
            lap_result.next_tick_progress,
        );

        players[controllable_player_index].pollInputs(lap_result.next_tick_progress);

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER)) {
            for (players) |*player| {
                player.resetInputs();
            }
            controllable_player_index = (controllable_player_index + 1) % players.len;
        }
        if (std.math.fabs(rl.GetMouseWheelMoveV().y) > math.epsilon) {
            if (!rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT)) {
                players[controllable_player_index].state_at_next_tick.camera
                    .increaseDistanceToObject(-rl.GetMouseWheelMoveV().y * 2.5);
            } else if (rl.GetMouseWheelMoveV().y < 0) {
                edit_mode_state.cycleInsertedObjectSubtypeForwards();
            } else {
                edit_mode_state.cycleInsertedObjectSubtypeBackwards();
            }
        }
        if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE)) {
            edit_mode_state.cycleInsertedObjectType(&level_geometry);
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_T)) {
            switch (view_mode) {
                .from_behind => {
                    view_mode = .top_down;
                    players[controllable_player_index].state_at_next_tick.camera
                        .setAngleFromGround(math.degreesToRadians(90));
                },
                .top_down => {
                    view_mode = .from_behind;
                    players[controllable_player_index].state_at_next_tick.camera
                        .resetAngleFromGround();
                },
            }
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F2)) {
            var file = try std.fs.cwd().createFile("maps/default.json", .{});
            defer file.close();
            try level_geometry.toJson(gpa.allocator(), file.writer());
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F5)) {
            try reloadDefaultMap(gpa.allocator(), &level_geometry);
        }

        const camera = players[controllable_player_index].getCamera(lap_result.next_tick_progress);
        const ray = camera.get3DRay(rl.GetMousePosition());
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_DELETE)) {
            edit_mode_state.cycleMode(&level_geometry);
        }
        if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
            try edit_mode_state.handleActionAtTarget(&level_geometry, ray);
        }
        edit_mode_state.updateCurrentActionTarget(
            &level_geometry,
            ray,
            camera.getDirectionToTarget().toFlatVector(),
        );
        if (rl.IsWindowResized()) {
            screen_width = @intCast(u16, rl.GetScreenWidth());
            screen_height = @intCast(u16, rl.GetScreenHeight());
        }
    }
}
