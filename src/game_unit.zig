const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const simulation = @import("simulation.zig");
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

pub const MovingCircle = struct {
    radius: f32,
    velocity: math.FlatVector,
    pass_trough_fences: bool,
    /// Contains the position of this object during the substeps of the last tick. The values are
    /// ordered from old to new. The last value contains the current position.
    trace: [4]math.FlatVector,

    pub fn create(
        position: math.FlatVector,
        radius: f32,
        velocity: math.FlatVector,
        pass_trough_fences: bool,
    ) MovingCircle {
        var trace: [4]math.FlatVector = undefined;
        for (&trace) |*point| {
            point.* = position;
        }
        return .{
            .radius = radius,
            .velocity = velocity,
            .trace = trace,
            .pass_trough_fences = pass_trough_fences,
        };
    }

    pub fn getPosition(self: MovingCircle) math.FlatVector {
        return self.trace[self.trace.len - 1];
    }

    pub fn processElapsedTick(self: *MovingCircle, map: Map) void {
        const velocity_length_squared = self.velocity.lengthSquared();
        if (velocity_length_squared < math.epsilon) {
            return;
        }
        const direction = self.velocity.normalize();
        const start_position = self.getPosition();

        // Max applicable velocity (limit) per tick is `radius * self.traces.len`.
        var index: usize = 0;
        var remaining_velocity = std.math.sqrt(velocity_length_squared);
        var boundaries = collision.Circle{ .position = start_position, .radius = self.radius };
        while (remaining_velocity > math.epsilon and index < self.trace.len) : (index += 1) {
            const substep_length = @min(remaining_velocity, self.radius);
            remaining_velocity -= substep_length;

            var substep = direction.scale(substep_length);
            if (map.geometry.collidesWithCircle(boundaries, self.pass_trough_fences)) |displacement_vector| {
                boundaries.position = boundaries.position.add(displacement_vector);
                const friction = 1 + std.math
                    .clamp(direction.dotProduct(displacement_vector.normalize()), -1, 0);
                self.velocity = self.velocity.scale(friction);
                substep = substep.scale(friction);
            }
            boundaries.position = boundaries.position.add(substep);
            self.trace[index] = boundaries.position;
        }

        // Fill trace position array with interpolated values.
        switch (index) {
            0 => self.trace = .{ start_position, start_position, start_position, start_position },
            1 => self.trace = .{ self.trace[0], self.trace[0], self.trace[0], self.trace[0] },
            2 => self.trace = .{
                self.trace[0],
                self.trace[0].lerp(self.trace[1], 1.0 / 3.0),
                self.trace[0].lerp(self.trace[1], 2.0 / 3.0),
                self.trace[1],
            },
            3 => self.trace = .{
                self.trace[0],
                self.trace[0].lerp(self.trace[1], 2.0 / 3.0),
                self.trace[1].lerp(self.trace[2], 1.0 / 3.0),
                self.trace[2],
            },
            4 => {},
            else => unreachable,
        }
    }

    pub const PositionsDuringContact = struct { self: math.FlatVector, other: math.FlatVector };

    pub fn hasCollidedWith(self: MovingCircle, other: MovingCircle) ?PositionsDuringContact {
        for (self.trace, other.trace) |self_position, other_position| {
            const self_boundaries =
                collision.Circle{ .position = self_position, .radius = self.radius };
            const other_boundaries = .{ .position = other_position, .radius = other.radius };
            if (self_boundaries.collidesWithCircle(other_boundaries)) {
                return .{ .self = self_position, .other = other_position };
            }
        }
        return null;
    }

    /// Check if this object has collided with the given circle during `processElapsedTick()`.
    /// Returns the position of `self` during the substep at which the collision occurred.
    pub fn hasCollidedWithCircle(self: MovingCircle, other: collision.Circle) ?math.FlatVector {
        for (self.trace) |position| {
            const boundaries = .{ .position = position, .radius = self.radius };
            if (boundaries.collidesWithCircle(other)) {
                return boundaries;
            }
        }
        return null;
    }
};

pub const GameCharacter = struct {
    object_id: u64,
    moving_circle: MovingCircle,
    acceleration_direction: math.FlatVector,
    height: f32,
    movement_speed: f32,
    health: Health,

    pub const Health = struct { current: u32, max: u32 };

    pub fn create(
        object_id_generator: *ObjectIdGenerator,
        position: math.FlatVector,
        width: f32,
        height: f32,
        movement_speed: f32,
        max_health: u32,
    ) GameCharacter {
        return .{
            .object_id = object_id_generator.makeNewId(),
            .moving_circle = MovingCircle.create(
                position,
                width / 2,
                math.FlatVector.zero,
                false,
            ),
            .acceleration_direction = math.FlatVector.zero,
            .height = height,
            .movement_speed = movement_speed,
            .health = .{ .current = max_health, .max = max_health },
        };
    }

    pub fn processElapsedTick(self: *GameCharacter, map: Map) void {
        self.moving_circle.processElapsedTick(map);

        const is_accelerating = self.acceleration_direction.length() > math.epsilon;
        if (is_accelerating) {
            const acceleration = self.movement_speed / 5.0;
            self.moving_circle.velocity =
                self.moving_circle.velocity.add(self.acceleration_direction.scale(acceleration));
            if (self.moving_circle.velocity.lengthSquared() >
                self.movement_speed * self.movement_speed)
            {
                self.moving_circle.velocity =
                    self.moving_circle.velocity.normalize().scale(self.movement_speed);
            }
        } else {
            self.moving_circle.velocity = self.moving_circle.velocity.scale(0.7);
        }
    }
};

pub const Player = struct {
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
        object_id_generator: *ObjectIdGenerator,
        starting_position_x: f32,
        starting_position_z: f32,
        spritesheet_frame_ratio: f32,
    ) Player {
        const in_game_height = 1.8;
        const character = GameCharacter.create(
            object_id_generator,
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_height / spritesheet_frame_ratio,
            in_game_height,
            simulation.kphToGameUnitsPerTick(30),
            100,
        );
        const orientation = 0;
        const camera = ThirdPersonCamera.create(
            character.moving_circle.getPosition(),
            getLookingDirection(orientation),
        );
        const animation_cycle = animation.FourStepCycle.create();
        return .{
            .character = character,
            .orientation = orientation,
            .turning_direction = 0,
            .camera = camera,
            .animation_cycle = animation_cycle,
            .gem_count = 0,
            .input_state = std.EnumArray(InputButton, bool).initFill(false),
            .values_from_previous_tick = .{
                .position = character.moving_circle.getPosition(),
                .radius = character.moving_circle.radius,
                .height = character.height,
                .velocity = character.moving_circle.velocity,
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

        var acceleration_direction = math.FlatVector.zero;
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
        self.character.acceleration_direction = acceleration_direction.normalize();
        self.setTurningDirection(turning_direction);
    }

    pub fn processElapsedTick(self: *Player, map: Map) void {
        self.values_from_previous_tick = self.getValuesForRendering();
        self.character.processElapsedTick(map);

        const max_rotation_per_tick = std.math.degreesToRadians(f32, 3.5);
        const rotation_angle = -(self.turning_direction * max_rotation_per_tick);
        self.orientation = @mod(
            self.orientation + rotation_angle,
            std.math.degreesToRadians(f32, 360),
        );
        self.camera.processElapsedTick(
            self.character.moving_circle.getPosition(),
            getLookingDirection(self.orientation),
        );
        self.animation_cycle
            .processElapsedTick(self.character.moving_circle.velocity.length() * 0.75);
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
            state_to_render.position,
            state_to_render.radius,
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
        return .{
            .id = self.character.object_id,
            .moving_circle = self.character.moving_circle,
            .height = state.height,
        };
    }

    fn setTurningDirection(self: *Player, turning_direction: f32) void {
        self.turning_direction = std.math.clamp(turning_direction, -1, 1);
    }

    fn getLookingDirection(orientation: f32) math.FlatVector {
        return .{ .x = std.math.sin(orientation), .z = std.math.cos(orientation) };
    }

    fn getValuesForRendering(self: Player) ValuesForRendering {
        return .{
            .position = self.character.moving_circle.getPosition(),
            .radius = self.character.moving_circle.radius,
            .height = self.character.height,
            .velocity = self.character.moving_circle.velocity,
            .camera = self.camera,
            .animation_cycle = self.animation_cycle,
        };
    }

    const ValuesForRendering = struct {
        position: math.FlatVector,
        radius: f32,
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
                .position = self.position.lerp(other.position, t),
                .radius = math.lerp(self.radius, other.radius, t),
                .height = math.lerp(self.height, other.height, t),
                .velocity = self.velocity.lerp(other.velocity, t),
                .camera = self.camera.lerp(other.camera, t),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, t),
            };
        }
    };
};

pub fn makeSpriteData(
    position: math.FlatVector,
    radius: f32,
    height: f32,
    sprite: SpriteSheetTexture.SpriteId,
    spritesheet: SpriteSheetTexture,
) rendering.SpriteData {
    const source = spritesheet.getSpriteTexcoords(sprite);
    return .{
        .position = .{ .x = position.x, .y = height / 2, .z = position.z },
        .size = .{ .w = radius * 2, .h = height },
        .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
    };
}
