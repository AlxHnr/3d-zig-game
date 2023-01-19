const animation = @import("animation.zig");
const collision = @import("collision.zig");
const edit_mode = @import("edit_mode.zig");
const gems = @import("gems.zig");
const rl = @import("raylib");
const std = @import("std");
const textures = @import("textures.zig");
const util = @import("util.zig");
const glad = @cImport(@cInclude("external/glad.h"));
const rendering = @import("rendering.zig");
const math = @import("math.zig");

const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;

const Character = struct {
    boundaries: collision.Circle,
    orientation: f32,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: f32,
    acceleration_direction: math.FlatVector,
    velocity: math.FlatVector,
    height: f32,

    fn create(position: math.FlatVector, radius: f32, height: f32) Character {
        return Character{
            .boundaries = collision.Circle{ .position = position, .radius = radius },
            .orientation = 0,
            .turning_direction = 0,
            .acceleration_direction = .{ .x = 0, .z = 0 },
            .velocity = .{ .x = 0, .z = 0 },
            .height = height,
        };
    }

    fn lerp(self: Character, other: Character, t: f32) Character {
        return Character{
            .boundaries = self.boundaries.lerp(other.boundaries, t),
            .orientation = math.lerp(self.orientation, other.orientation, t),
            .turning_direction = math.lerp(self.turning_direction, other.turning_direction, t),
            .acceleration_direction = self.acceleration_direction.lerp(other.acceleration_direction, t),
            .velocity = self.velocity.lerp(other.velocity, t),
            .height = math.lerp(self.height, other.height, t),
        };
    }

    fn getLookingDirection(self: Character) math.FlatVector {
        return .{ .x = std.math.sin(self.orientation), .z = std.math.cos(self.orientation) };
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
        self.orientation = @mod(
            self.orientation + rotation_angle,
            math.degreesToRadians(360),
        );
    }
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
        spritesheet_width: u16,
        spritesheet_height: u16,
    ) Player {
        const in_game_heigth = 1.8;
        const frame_ratio = getFrameRatio(spritesheet_width, spritesheet_height);
        const character = Character.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_heigth / frame_ratio / 2.0,
            in_game_heigth,
        );
        const state = State{
            .character = character,
            .camera = ThirdPersonCamera.create(
                character.boundaries.position,
                character.getLookingDirection(),
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

    fn getBillboardData(
        self: Player,
        interval_between_previous_and_current_tick: f32,
    ) rendering.BillboardRenderer.BillboardData {
        const state_to_render = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );
        const source_rect = getSpritesheetSource(state_to_render, .back);
        return .{
            .position = .{
                .x = state_to_render.character.boundaries.position.x,
                .y = state_to_render.character.height / 2,
                .z = state_to_render.character.boundaries.position.z,
            },
            .size = .{
                .w = state_to_render.character.boundaries.radius * 2,
                .h = state_to_render.character.height,
            },
            .source_rect = .{
                .x = source_rect[0],
                .y = source_rect[1],
                .w = source_rect[2],
                .h = source_rect[3],
            },
        };
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

    fn getSpritesheetSource(state_to_render: State, side: Direction) [4]f32 {
        const w = getFrameWidth();
        const h = getFrameHeight();
        const min_velocity_for_animation = 0.02;

        const animation_frame =
            if (state_to_render.character.velocity.length() < min_velocity_for_animation)
            1
        else
            state_to_render.animation_cycle.getFrame();

        const x = w * @intToFloat(f32, animation_frame);
        return switch (side) {
            .front => .{ x, h, w, h },
            .back => .{ x, 0, w, h },
        };
    }

    fn getFrameWidth() f32 {
        return 1.0 / 3.0;
    }
    fn getFrameHeight() f32 {
        return 1.0 / 2.0;
    }
    fn getFrameRatio(spritesheet_width: u16, spritesheet_height: u16) f32 {
        return getFrameHeight() * @intToFloat(f32, spritesheet_height) /
            (getFrameWidth() * @intToFloat(f32, spritesheet_width));
    }

    const State = struct {
        character: Character,
        camera: ThirdPersonCamera,
        animation_cycle: animation.FourStepCycle,

        fn lerp(self: State, other: State, t: f32) State {
            return State{
                .character = self.character.lerp(other.character, t),
                .camera = self.camera.lerp(other.camera, t),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, t),
            };
        }

        fn processElapsedTick(self: *State, level_geometry: LevelGeometry) void {
            if (level_geometry.collidesWithCircle(self.character.boundaries)) |displacement_vector| {
                self.character.resolveCollision(displacement_vector);
            }
            self.character.processElapsedTick();
            self.camera.processElapsedTick(
                self.character.boundaries.position,
                self.character.getLookingDirection(),
            );
            self.animation_cycle.processElapsedTick(self.character.velocity.length() * 0.75);
        }
    };
};

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

    var texture_collection = try textures.Collection.loadFromDisk();
    defer texture_collection.destroy();

    var player = Player.create(
        0,
        0,
        0,
        @intCast(u16, texture_collection.get(.player).width),
        @intCast(u16, texture_collection.get(.player).height),
    );

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
            level_geometry.processElapsedTick();
            player.processElapsedTick(level_geometry, &gem_collection);
            gem_collection.processElapsedTick();
        }

        const billboards_to_render = gem_collection.getBillboardCount();
        if (billboard_buffer.len < billboards_to_render) {
            billboard_buffer = try gpa.allocator().realloc(billboard_buffer, billboards_to_render);
        }

        gem_collection.populateBillboardData(
            billboard_buffer,
            &[_]gems.CollisionObject{player.getLerpedCollisionObject(lap_result.next_tick_progress)},
            lap_result.next_tick_progress,
        );
        billboard_renderer.uploadBillboards(billboard_buffer[0..billboards_to_render]);

        const camera = player.getCamera(lap_result.next_tick_progress);
        const max_distance_from_target =
            if (level_geometry
            .cast3DRayToWalls(camera.get3DRayFromTargetToSelf(), true)) |ray_collision|
            ray_collision.impact_point.distance_from_start_position
        else
            null;

        rl.BeginDrawing();

        glad.glClearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
        glad.glClear(glad.GL_COLOR_BUFFER_BIT | glad.GL_DEPTH_BUFFER_BIT | glad.GL_STENCIL_BUFFER_BIT);
        glad.glEnable(glad.GL_DEPTH_TEST);

        var vp_matrix =
            camera.getViewProjectionMatrix(screen_width, screen_height, max_distance_from_target);

        try level_geometry.prepareRender(gpa.allocator());
        level_geometry.render(vp_matrix, camera.getDirectionToTarget(), texture_collection);

        billboard_renderer.render(
            vp_matrix,
            camera.getDirectionToTarget(),
            texture_collection.get(.gem).id,
        );

        const player_billboard_data = [_]rendering.BillboardRenderer.BillboardData{
            player.getBillboardData(lap_result.next_tick_progress),
        };
        billboard_renderer.uploadBillboards(player_billboard_data[0..]);
        billboard_renderer.render(
            vp_matrix,
            camera.getDirectionToTarget(),
            texture_collection.get(.player).id,
        );
        glad.glDisable(glad.GL_DEPTH_TEST);

        rl.EndDrawing();

        player.pollInputs(lap_result.next_tick_progress);

        if (std.math.fabs(rl.GetMouseWheelMoveV().y) > math.epsilon) {
            if (!rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT)) {
                player.state_at_next_tick.camera
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
                    player.state_at_next_tick.camera.setAngleFromGround(math.degreesToRadians(90));
                },
                .top_down => {
                    view_mode = .from_behind;
                    player.state_at_next_tick.camera.resetAngleFromGround();
                },
            }
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F2)) {
            var file = try std.fs.cwd().createFile("maps/default.json", .{});
            defer file.close();
            try level_geometry.writeAsJson(gpa.allocator(), file.writer());
        }
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F5)) {
            try reloadDefaultMap(gpa.allocator(), &level_geometry);
        }

        const ray = camera.get3DRay(
            @floatToInt(u16, rl.GetMousePosition().x),
            @floatToInt(u16, rl.GetMousePosition().y),
            screen_width,
            screen_height,
            max_distance_from_target,
        );
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
