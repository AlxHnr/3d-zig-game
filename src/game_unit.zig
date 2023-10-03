const Map = @import("map/map.zig").Map;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");

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

pub const GameCharacter = struct {
    boundaries: collision.Circle,
    acceleration_direction: math.FlatVector,
    velocity: math.FlatVector,
    height: f32,
    movement_speed: f32,
    health: Health,

    pub const Health = struct { current: u32, max: u32 };

    pub fn create(
        position: math.FlatVector,
        width: f32,
        height: f32,
        movement_speed: f32,
        max_health: u32,
    ) GameCharacter {
        return .{
            .boundaries = .{ .position = position, .radius = width / 2 },
            .acceleration_direction = .{ .x = 0, .z = 0 },
            .velocity = .{ .x = 0, .z = 0 },
            .height = height,
            .movement_speed = movement_speed,
            .health = .{ .current = max_health, .max = max_health },
        };
    }

    pub fn setAcceleration(self: *GameCharacter, direction: math.FlatVector) void {
        std.debug.assert(direction.lengthSquared() < 1 + math.epsilon);
        self.acceleration_direction = direction;
    }

    pub const RemainingTickVelocity = struct { direction: math.FlatVector, magnitude: f32 };

    /// Returns an object which has to be consumed with processElapsedTickConsume().
    pub fn processElapsedTickInit(self: GameCharacter) RemainingTickVelocity {
        return .{
            .direction = self.velocity.normalize(),
            .magnitude = self.velocity.length(),
        };
    }

    /// Returns true if this function needs to be called again. False if there is no velocity left
    /// to consume and the tick has been processed completely.
    pub fn processElapsedTickConsume(
        self: *GameCharacter,
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
            self.velocity = self.velocity.add(self.acceleration_direction.scale(acceleration));
            if (self.velocity.length() > self.movement_speed) {
                self.velocity = self.velocity.normalize().scale(self.movement_speed);
            }
        } else {
            self.velocity = self.velocity.scale(0.7);
        }
        return false;
    }

    fn resolveCollision(self: *GameCharacter, displacement_vector: math.FlatVector) void {
        self.boundaries.position = self.boundaries.position.add(displacement_vector);
        const dot_product = std.math.clamp(self.velocity.normalize()
            .dotProduct(displacement_vector.normalize()), -1, 1);
        const moving_against_displacement_vector =
            self.velocity.dotProduct(displacement_vector) < 0;
        if (moving_against_displacement_vector) {
            self.velocity = self.velocity.scale(1 + dot_product);
        }
    }
};

pub const Player = struct {
    /// Unique identifier distinct from all other players.
    id: u64,
    character: GameCharacter,
    orientation: f32,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: f32,
    camera: ThirdPersonCamera,
    animation_cycle: animation.FourStepCycle,
    gem_count: u64,
    input_state: std.EnumArray(InputButton, bool),
    values_from_previous_tick: ValuesForRendering,

    pub fn create(
        id: u64,
        starting_position_x: f32,
        starting_position_z: f32,
        spritesheet_frame_ratio: f32,
    ) Player {
        const in_game_height = 1.8;
        const character = GameCharacter.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_height / spritesheet_frame_ratio,
            in_game_height,
            0.15,
            100,
        );
        const orientation = 0;
        const camera = ThirdPersonCamera.create(
            character.boundaries.position,
            getLookingDirection(orientation),
        );
        const animation_cycle = animation.FourStepCycle.create();
        return .{
            .id = id,
            .character = character,
            .orientation = orientation,
            .turning_direction = 0,
            .camera = camera,
            .animation_cycle = animation_cycle,
            .gem_count = 0,
            .input_state = std.EnumArray(InputButton, bool).initFill(false),
            .values_from_previous_tick = .{
                .boundaries = character.boundaries,
                .height = character.height,
                .velocity = character.velocity,
                .camera = camera,
                .animation_cycle = animation_cycle,
            },
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
        const state_rendered_to_screen = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
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
        self.character.setAcceleration(acceleration_direction.normalize());
        self.setTurningDirection(turning_direction);
    }

    pub fn processElapsedTick(self: *Player, map: Map, gem_collection: *gems.Collection) void {
        self.values_from_previous_tick = self.getValuesForRendering();

        var remaining_velocity = self.character.processElapsedTickInit();
        while (self.character.processElapsedTickConsume(&remaining_velocity, map)) {
            self.gem_count += gem_collection.processCollision(.{
                .id = self.id,
                .boundaries = self.character.boundaries,
                .height = self.character.height,
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
            .processElapsedTick(self.character.velocity.length() * 0.75);
    }

    pub fn getBillboardData(
        self: Player,
        spritesheet: SpriteSheetTexture,
        interval_between_previous_and_current_tick: f32,
    ) rendering.SpriteData {
        const state_to_render = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        );

        const min_velocity_for_animation = 0.02;
        const animation_frame =
            if (state_to_render.velocity.length() < min_velocity_for_animation)
            1
        else
            state_to_render.animation_cycle.getFrame();

        const sprite_id: SpriteSheetTexture.SpriteId = switch (animation_frame) {
            else => .player_back_frame_1,
            0 => .player_back_frame_0,
            2 => .player_back_frame_2,
        };
        return makeSpriteData(
            state_to_render.boundaries,
            state_to_render.height,
            sprite_id,
            spritesheet,
        );
    }

    pub fn getCamera(self: Player, interval_between_previous_and_current_tick: f32) ThirdPersonCamera {
        return self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        ).camera;
    }

    pub fn getLerpedCollisionObject(
        self: Player,
        interval_between_previous_and_current_tick: f32,
    ) gems.CollisionObject {
        const state = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        );
        return .{ .id = self.id, .boundaries = state.boundaries, .height = state.height };
    }

    fn setTurningDirection(self: *Player, turning_direction: f32) void {
        self.turning_direction = std.math.clamp(turning_direction, -1, 1);
    }

    fn getLookingDirection(orientation: f32) math.FlatVector {
        return .{ .x = std.math.sin(orientation), .z = std.math.cos(orientation) };
    }

    fn getValuesForRendering(self: Player) ValuesForRendering {
        return .{
            .boundaries = self.character.boundaries,
            .height = self.character.height,
            .velocity = self.character.velocity,
            .camera = self.camera,
            .animation_cycle = self.animation_cycle,
        };
    }

    const ValuesForRendering = struct {
        boundaries: collision.Circle,
        height: f32,
        velocity: math.FlatVector,
        camera: ThirdPersonCamera,
        animation_cycle: animation.FourStepCycle,

        pub fn lerp(
            self: ValuesForRendering,
            other: ValuesForRendering,
            t: f32,
        ) ValuesForRendering {
            return .{
                .boundaries = self.boundaries.lerp(other.boundaries, t),
                .height = math.lerp(self.height, other.height, t),
                .velocity = self.velocity.lerp(other.velocity, t),
                .camera = self.camera.lerp(other.camera, t),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, t),
            };
        }
    };
};

pub fn makeSpriteData(
    boundaries: collision.Circle,
    height: f32,
    sprite: SpriteSheetTexture.SpriteId,
    spritesheet: SpriteSheetTexture,
) rendering.SpriteData {
    const source = spritesheet.getSpriteTexcoords(sprite);
    return .{
        .position = .{
            .x = boundaries.position.x,
            .y = height / 2,
            .z = boundaries.position.z,
        },
        .size = .{ .w = boundaries.radius * 2, .h = height },
        .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
    };
}
