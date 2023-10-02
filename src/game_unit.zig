const Map = @import("map/map.zig").Map;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const std = @import("std");
const textures = @import("textures.zig");

pub const InputButton = enum {
    forwards,
    backwards,
    left,
    right,
    strafe,
    slow_turning,
    cancel,
    confirm,
};

pub const MovingCharacter = struct {
    boundaries: collision.Circle,
    movement_speed: f32,
    acceleration_direction: math.FlatVector,
    current_velocity: math.FlatVector,

    pub fn create(position: math.FlatVector, width: f32, movement_speed: f32) MovingCharacter {
        return .{
            .boundaries = .{ .position = position, .radius = width / 2 },
            .movement_speed = movement_speed,
            .acceleration_direction = .{ .x = 0, .z = 0 },
            .current_velocity = .{ .x = 0, .z = 0 },
        };
    }

    pub fn lerp(self: MovingCharacter, other: MovingCharacter, t: f32) MovingCharacter {
        return MovingCharacter{
            .boundaries = self.boundaries.lerp(other.boundaries, t),
            .movement_speed = math.lerp(self.movement_speed, other.movement_speed, t),
            .acceleration_direction = self.acceleration_direction.lerp(
                other.acceleration_direction,
                t,
            ),
            .current_velocity = self.current_velocity.lerp(other.current_velocity, t),
        };
    }

    pub fn setAcceleration(self: *MovingCharacter, direction: math.FlatVector) void {
        std.debug.assert(direction.lengthSquared() < 1 + math.epsilon);
        self.acceleration_direction = direction;
    }

    pub const RemainingTickVelocity = struct { direction: math.FlatVector, magnitude: f32 };

    /// Returns an object which has to be consumed with processElapsedTickConsume().
    pub fn processElapsedTickInit(self: MovingCharacter) RemainingTickVelocity {
        return .{
            .direction = self.current_velocity.normalize(),
            .magnitude = self.current_velocity.length(),
        };
    }

    /// Returns true if this function needs to be called again. False if there is no velocity left
    /// to consume and the tick has been processed completely.
    pub fn processElapsedTickConsume(
        self: *MovingCharacter,
        remaining_velocity: *RemainingTickVelocity,
        map: Map,
    ) bool {
        if (remaining_velocity.magnitude > math.epsilon) {
            // Determined by trial and error to prevent an object with a radius of 0.05 from passing
            // trough a fence with a thickness of 0.15.
            const max_velocity_substep = 0.1;

            const velocity_step_length = @min(remaining_velocity.magnitude, max_velocity_substep);
            const velocity_step = remaining_velocity.direction.scale(velocity_step_length);
            self.boundaries.position = self.boundaries.position.add(velocity_step);
            remaining_velocity.magnitude -= velocity_step_length;
            if (map.geometry.collidesWithCircle(self.boundaries)) |displacement_vector| {
                self.resolveCollision(displacement_vector);
            }
            return true;
        }

        const is_accelerating = self.acceleration_direction.length() > math.epsilon;
        if (is_accelerating) {
            const acceleration = self.movement_speed / 5.0;
            self.current_velocity =
                self.current_velocity.add(self.acceleration_direction.scale(acceleration));
            if (self.current_velocity.length() > self.movement_speed) {
                self.current_velocity =
                    self.current_velocity.normalize().scale(self.movement_speed);
            }
        } else {
            self.current_velocity = self.current_velocity.scale(0.7);
        }
        return false;
    }

    fn resolveCollision(self: *MovingCharacter, displacement_vector: math.FlatVector) void {
        self.boundaries.position = self.boundaries.position.add(displacement_vector);
        const dot_product = std.math.clamp(self.current_velocity.normalize()
            .dotProduct(displacement_vector.normalize()), -1, 1);
        const moving_against_displacement_vector =
            self.current_velocity.dotProduct(displacement_vector) < 0;
        if (moving_against_displacement_vector) {
            self.current_velocity = self.current_velocity.scale(1 + dot_product);
        }
    }
};

pub const Player = struct {
    /// Unique identifier distinct from all other players.
    id: u64,
    state_at_next_tick: State,
    state_at_previous_tick: State,
    gem_count: u64,
    input_state: std.EnumArray(InputButton, bool),

    pub fn create(
        id: u64,
        starting_position_x: f32,
        starting_position_z: f32,
        spritesheet_frame_ratio: f32,
    ) Player {
        const in_game_height = 1.8;
        const character = MovingCharacter.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_height / spritesheet_frame_ratio,
            0.15,
        );
        const orientation = 0;
        const state = .{
            .character = character,
            .orientation = orientation,
            .turning_direction = 0,
            .height = in_game_height,
            .camera = ThirdPersonCamera.create(
                character.boundaries.position,
                State.getLookingDirection(orientation),
            ),
            .animation_cycle = animation.FourStepCycle.create(),
        };
        return .{
            .id = id,
            .state_at_next_tick = state,
            .state_at_previous_tick = state,
            .gem_count = 0,
            .input_state = std.EnumArray(InputButton, bool).initFill(false),
        };
    }

    pub fn markButtonAsPressed(self: *Player, button: InputButton) void {
        self.input_state.set(button, true);
    }

    pub fn markButtonAsReleased(self: *Player, button: InputButton) void {
        self.input_state.set(button, false);
    }

    pub fn markAllButtonsAsReleased(self: *Player) void {
        self.input_state = std.EnumArray(InputButton, bool).initFill(false);
    }

    pub fn applyCurrentInput(
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
        self.state_at_next_tick.character.setAcceleration(acceleration_direction.normalize());
        self.state_at_next_tick.setTurningDirection(turning_direction);
    }

    pub fn processElapsedTick(self: *Player, map: Map, gem_collection: *gems.Collection) void {
        self.state_at_previous_tick = self.state_at_next_tick;
        self.gem_count +=
            self.state_at_next_tick.processElapsedTick(self.id, map, gem_collection);
    }

    pub fn getBillboardData(
        self: Player,
        spritesheet: textures.SpriteSheetTexture,
        interval_between_previous_and_current_tick: f32,
    ) rendering.SpriteData {
        const state_to_render = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        const min_velocity_for_animation = 0.02;
        const animation_frame =
            if (state_to_render.character.current_velocity.length() < min_velocity_for_animation)
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
                .y = state_to_render.height / 2,
                .z = state_to_render.character.boundaries.position.z,
            },
            .size = .{
                .w = state_to_render.character.boundaries.radius * 2,
                .h = state_to_render.height,
            },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
        };
    }

    pub fn getCamera(self: Player, interval_between_previous_and_current_tick: f32) ThirdPersonCamera {
        return self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        ).camera;
    }

    pub fn getLerpedCollisionObject(
        self: Player,
        interval_between_previous_and_current_tick: f32,
    ) gems.CollisionObject {
        const state = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );
        return .{
            .id = self.id,
            .boundaries = state.character.boundaries,
            .height = state.height,
        };
    }

    const State = struct {
        character: MovingCharacter,
        orientation: f32,
        /// Values from -1 (turning left) to 1 (turning right).
        turning_direction: f32,
        height: f32,

        camera: ThirdPersonCamera,
        animation_cycle: animation.FourStepCycle,

        fn lerp(self: State, other: State, t: f32) State {
            return State{
                .character = self.character.lerp(other.character, t),
                .orientation = math.lerp(self.orientation, other.orientation, t),
                .turning_direction = math.lerp(self.turning_direction, other.turning_direction, t),
                .height = math.lerp(self.height, other.height, t),
                .camera = self.camera.lerp(other.camera, t),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, t),
            };
        }

        /// Return the amount of collected gems.
        fn processElapsedTick(
            self: *State,
            player_id: u64,
            map: Map,
            gem_collection: *gems.Collection,
        ) u64 {
            var gems_collected: u64 = 0;

            var remaining_velocity = self.character.processElapsedTickInit();
            while (self.character.processElapsedTickConsume(&remaining_velocity, map)) {
                gems_collected += gem_collection.processCollision(.{
                    .id = player_id,
                    .boundaries = self.character.boundaries,
                    .height = self.height,
                }, map.geometry);
            }

            const max_rotation_per_tick = std.math.degreesToRadians(f32, 3.5);
            const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
            self.orientation = @mod(
                self.orientation + rotation_angle,
                std.math.degreesToRadians(f32, 360),
            );

            self.camera.processElapsedTick(
                self.character.boundaries.position,
                getLookingDirection(self.orientation),
            );
            self.animation_cycle
                .processElapsedTick(self.character.current_velocity.length() * 0.75);

            return gems_collected;
        }

        fn setTurningDirection(self: *State, turning_direction: f32) void {
            self.turning_direction = std.math.clamp(turning_direction, -1, 1);
        }

        fn getLookingDirection(orientation: f32) math.FlatVector {
            return .{ .x = std.math.sin(orientation), .z = std.math.cos(orientation) };
        }
    };
};
