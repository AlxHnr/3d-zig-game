const animation = @import("animation.zig");
const collision = @import("collision.zig");
const dialog = @import("dialog.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const std = @import("std");
const textures = @import("textures.zig");

const Hud = @import("hud.zig").Hud;
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const TickTimer = @import("util.zig").TickTimer;

pub const InputButton = enum {
    forwards,
    backwards,
    left,
    right,
    strafe,
    slow_turning,
    confirm,
    abort,
};

pub const Context = struct {
    tick_timer: TickTimer,
    interval_between_previous_and_current_tick: f32,
    main_character: Player,
    /// Prevents walls from covering the player.
    max_camera_distance: ?f32,

    map_file_path: []const u8,
    level_geometry: LevelGeometry,
    gem_collection: gems.Collection,
    tileable_textures: textures.TileableArrayTexture,
    spritesheet: textures.SpriteSheetTexture,

    billboard_renderer: rendering.BillboardRenderer,
    billboard_buffer: []rendering.BillboardRenderer.BillboardData,

    hud: Hud,
    dialog_controller: dialog.Controller,

    pub fn create(allocator: std.mem.Allocator, map_file_path: []const u8) !Context {
        const map_file_path_buffer = try allocator.dupe(u8, map_file_path);
        errdefer allocator.free(map_file_path_buffer);

        var level_geometry = try loadLevelGeometry(allocator, map_file_path);
        errdefer level_geometry.destroy();

        var gem_collection = gems.Collection.create(allocator);
        errdefer gem_collection.destroy();

        var rng = std.rand.DefaultPrng.init(0);
        var counter: usize = 0;
        while (counter < 3000) : (counter += 1) {
            try gem_collection.addGem(.{
                .x = rng.random().float(f32) * 100 + 100,
                .z = rng.random().float(f32) * 180 - 280,
            });
        }

        var tileable_textures = try textures.TileableArrayTexture.loadFromDisk();
        errdefer tileable_textures.destroy();

        var spritesheet = try textures.SpriteSheetTexture.loadFromDisk();
        errdefer spritesheet.destroy();

        var billboard_renderer = try rendering.BillboardRenderer.create();
        errdefer billboard_renderer.destroy();

        var hud = try Hud.create();
        errdefer hud.destroy(allocator);

        var dialog_controller = try dialog.Controller.create(allocator);
        errdefer dialog_controller.destroy();

        return .{
            .tick_timer = try TickTimer.start(60),
            .interval_between_previous_and_current_tick = 1,
            .main_character = Player.create(
                0,
                0,
                0,
                spritesheet.getSpriteAspectRatio(.player_back_frame_1),
            ),
            .max_camera_distance = null,

            .map_file_path = map_file_path_buffer,
            .level_geometry = level_geometry,
            .gem_collection = gem_collection,
            .tileable_textures = tileable_textures,
            .spritesheet = spritesheet,

            .billboard_renderer = billboard_renderer,
            .billboard_buffer = &.{},

            .hud = hud,
            .dialog_controller = dialog_controller,
        };
    }

    pub fn destroy(self: *Context, allocator: std.mem.Allocator) void {
        self.dialog_controller.destroy();
        self.hud.destroy(allocator);
        allocator.free(self.billboard_buffer);
        self.billboard_renderer.destroy();
        self.spritesheet.destroy();
        self.tileable_textures.destroy();
        self.gem_collection.destroy();
        self.level_geometry.destroy();
        allocator.free(self.map_file_path);
    }

    pub fn markButtonAsPressed(self: *Context, button: InputButton) void {
        self.main_character.markButtonAsPressed(button);

        switch (button) {
            .confirm => self.dialog_controller.sendCommandToCurrentDialog(.confirm),
            .abort => self.dialog_controller.sendCommandToCurrentDialog(.abort),
            else => {},
        }
    }

    pub fn markButtonAsReleased(self: *Context, button: InputButton) void {
        self.main_character.markButtonAsReleased(button);
    }

    pub fn handleElapsedFrame(self: *Context) void {
        if (self.dialog_controller.hasOpenDialogs()) {
            self.main_character.markAllButtonsAsReleased();
        }
        self.main_character.applyCurrentInput(self.interval_between_previous_and_current_tick);

        const lap_result = self.tick_timer.lap();
        var tick_counter: u64 = 0;
        while (tick_counter < lap_result.elapsed_ticks) : (tick_counter += 1) {
            self.level_geometry.processElapsedTick();
            self.main_character.processElapsedTick(self.level_geometry, &self.gem_collection);
            self.gem_collection.processElapsedTick();
        }
        self.interval_between_previous_and_current_tick = lap_result.next_tick_progress;

        const ray_wall_collision = self.level_geometry.cast3DRayToWalls(
            self.main_character.getCamera(self.interval_between_previous_and_current_tick)
                .get3DRayFromTargetToSelf(),
            true,
        );
        self.max_camera_distance = if (ray_wall_collision) |ray_collision|
            ray_collision.impact_point.distance_from_start_position
        else
            null;
    }

    pub fn render(
        self: *Context,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
    ) !void {
        try self.level_geometry.prepareRender(allocator, self.spritesheet);

        const billboards_to_render = self.gem_collection.getBillboardCount();
        if (self.billboard_buffer.len < billboards_to_render) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, billboards_to_render);
        }
        self.gem_collection.populateBillboardData(
            self.billboard_buffer,
            self.spritesheet,
            &[_]gems.CollisionObject{self.main_character
                .getLerpedCollisionObject(self.interval_between_previous_and_current_tick)},
            self.interval_between_previous_and_current_tick,
        );
        self.billboard_renderer.uploadBillboards(self.billboard_buffer[0..billboards_to_render]);

        const camera = self.main_character
            .getCamera(self.interval_between_previous_and_current_tick);
        const vp_matrix = camera.getViewProjectionMatrix(
            screen_dimensions,
            self.max_camera_distance,
        );
        self.level_geometry.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            self.tileable_textures,
            self.spritesheet,
        );
        self.billboard_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            self.spritesheet.id,
        );

        const player_billboard_data = [_]rendering.BillboardRenderer.BillboardData{
            self.main_character.getBillboardData(
                self.spritesheet,
                self.interval_between_previous_and_current_tick,
            ),
        };
        self.billboard_renderer.uploadBillboards(player_billboard_data[0..]);
        self.billboard_renderer.render(
            vp_matrix,
            screen_dimensions,
            camera.getDirectionToTarget(),
            self.spritesheet.id,
        );
    }

    pub fn renderHud(
        self: *Context,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
    ) !void {
        try self.hud.render(
            allocator,
            screen_dimensions,
            self.spritesheet,
            self.main_character.gem_count,
        );
        try self.dialog_controller.render(screen_dimensions);
    }

    pub fn hasOpenDialogs(self: Context) bool {
        return self.dialog_controller.hasOpenDialogs();
    }

    pub fn getMutableLevelGeometry(self: *Context) *LevelGeometry {
        return &self.level_geometry;
    }

    pub fn reloadMapFromDisk(self: *Context, allocator: std.mem.Allocator) !void {
        const level_geometry = try loadLevelGeometry(allocator, self.map_file_path);
        self.level_geometry.destroy();
        self.level_geometry = level_geometry;
    }

    pub fn writeMapToDisk(self: Context, allocator: std.mem.Allocator) !void {
        var file = try std.fs.cwd().createFile(self.map_file_path, .{});
        defer file.close();
        return self.level_geometry.writeAsJson(allocator, file.writer());
    }

    pub fn castRay(
        self: Context,
        mouse_x: u16,
        mouse_y: u16,
        screen_dimensions: ScreenDimensions,
    ) collision.Ray3d {
        return self.main_character
            .getCamera(self.interval_between_previous_and_current_tick)
            .get3DRay(mouse_x, mouse_y, screen_dimensions, self.max_camera_distance);
    }

    pub fn increaseCameraDistance(self: *Context, value: f32) void {
        self.main_character.state_at_next_tick.camera.increaseDistanceToObject(value);
    }

    pub fn setCameraAngleFromGround(self: *Context, angle: f32) void {
        self.main_character.state_at_next_tick.camera.setAngleFromGround(angle);
    }

    pub fn resetCameraAngleFromGround(self: *Context) void {
        self.main_character.state_at_next_tick.camera.resetAngleFromGround();
    }

    pub fn getCameraDirection(self: Context) math.Vector3d {
        return self.main_character
            .getCamera(self.interval_between_previous_and_current_tick)
            .getDirectionToTarget();
    }

    fn loadLevelGeometry(allocator: std.mem.Allocator, file_path: []const u8) !LevelGeometry {
        var json = try std.fs.cwd().readFileAlloc(allocator, file_path, 20 * 1024 * 1024);
        defer allocator.free(json);
        return LevelGeometry.createFromJson(allocator, json);
    }
};

const Player = struct {
    /// Unique identifier distinct from all other players.
    id: u64,
    state_at_next_tick: State,
    state_at_previous_tick: State,
    gem_count: u64,
    input_state: std.EnumArray(InputButton, bool),

    fn create(
        id: u64,
        starting_position_x: f32,
        starting_position_z: f32,
        spritesheet_frame_ratio: f32,
    ) Player {
        const in_game_heigth = 1.8;
        const character = Character.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_heigth / spritesheet_frame_ratio / 2.0,
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
            .input_state = std.EnumArray(InputButton, bool).initFill(false),
        };
    }

    fn markButtonAsPressed(self: *Player, button: InputButton) void {
        self.input_state.set(button, true);
    }

    fn markButtonAsReleased(self: *Player, button: InputButton) void {
        self.input_state.set(button, false);
    }

    fn markAllButtonsAsReleased(self: *Player) void {
        self.input_state = std.EnumArray(InputButton, bool).initFill(false);
    }

    fn applyCurrentInput(
        self: *Player,
        interval_between_previous_and_current_tick: f32,
    ) void {
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
        if (self.input_state.get(.left)) {
            if (self.input_state.get(.strafe)) {
                acceleration_direction = acceleration_direction.subtract(right_direction);
            } else if (self.input_state.get(.slow_turning)) {
                turning_direction -= 0.05;
            } else {
                turning_direction -= 1;
            }
        }
        if (self.input_state.get(.right)) {
            if (self.input_state.get(.strafe)) {
                acceleration_direction = acceleration_direction.add(right_direction);
            } else if (self.input_state.get(.slow_turning)) {
                turning_direction += 0.05;
            } else {
                turning_direction += 1;
            }
        }
        if (self.input_state.get(.forwards)) {
            acceleration_direction = acceleration_direction.add(forward_direction);
        }
        if (self.input_state.get(.backwards)) {
            acceleration_direction = acceleration_direction.subtract(forward_direction);
        }
        self.state_at_next_tick.character.setAcceleration(acceleration_direction);
        self.state_at_next_tick.character.setTurningDirection(turning_direction);
    }

    fn processElapsedTick(
        self: *Player,
        level_geometry: LevelGeometry,
        gem_collection: *gems.Collection,
    ) void {
        self.state_at_previous_tick = self.state_at_next_tick;
        self.gem_count +=
            self.state_at_next_tick.processElapsedTick(self.id, level_geometry, gem_collection);
    }

    fn getBillboardData(
        self: Player,
        spritesheet: textures.SpriteSheetTexture,
        interval_between_previous_and_current_tick: f32,
    ) rendering.BillboardRenderer.BillboardData {
        const state_to_render = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        const min_velocity_for_animation = 0.02;
        const animation_frame =
            if (state_to_render.character.velocity.length() < min_velocity_for_animation)
            1
        else
            state_to_render.animation_cycle.getFrame();

        const sprite_id: textures.SpriteSheetTexture.SpriteId = switch (animation_frame) {
            else => .player_back_frame_1,
            0 => .player_back_frame_0,
            2 => .player_back_frame_2,
        };
        const source = spritesheet.getSpriteTexcoords(sprite_id);
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
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
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

        /// Return the amount of collected gems.
        fn processElapsedTick(
            self: *State,
            player_id: u64,
            level_geometry: LevelGeometry,
            gem_collection: *gems.Collection,
        ) u64 {
            var gems_collected: u64 = 0;
            var character = &self.character;

            // Determined by trial and error to prevent an object with a radius of 0.05 from passing
            // trough a fence with a thickness of 0.15.
            const max_velocity_substep = 0.1;

            const velocity_direction = character.velocity.normalize();
            var velocity_remaining = character.velocity.length();
            while (velocity_remaining > math.epsilon) {
                const velocity_to_apply = @min(velocity_remaining, max_velocity_substep);
                character.processVelocitySubstep(velocity_direction.scale(velocity_to_apply));
                velocity_remaining -= velocity_to_apply;

                if (level_geometry.collidesWithCircle(character.boundaries)) |displacement_vector| {
                    character.resolveCollision(displacement_vector);
                }
                gems_collected += gem_collection.processCollision(.{
                    .id = player_id,
                    .boundaries = character.boundaries,
                    .height = character.height,
                }, level_geometry);
            }

            character.processElapsedTick();
            self.camera.processElapsedTick(
                character.boundaries.position,
                character.getLookingDirection(),
            );
            self.animation_cycle.processElapsedTick(character.velocity.length() * 0.75);

            return gems_collected;
        }
    };
};

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

    fn processVelocitySubstep(self: *Character, velocity_step: math.FlatVector) void {
        self.boundaries.position = self.boundaries.position.add(velocity_step);
    }

    fn processElapsedTick(self: *Character) void {
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

        const max_rotation_per_tick = std.math.degreesToRadians(f32, 3.5);
        const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
        self.orientation = @mod(
            self.orientation + rotation_angle,
            std.math.degreesToRadians(f32, 360),
        );
    }
};
