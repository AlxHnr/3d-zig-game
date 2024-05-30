const Map = @import("map/map.zig").Map;
const MovingCircle = @import("moving_circle.zig").MovingCircle;
const SharedContext = @import("shared_context.zig").SharedContext;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const ThirdPersonCamera = @import("third_person_camera.zig");
const animation = @import("animation.zig");
const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
const math = @import("math.zig");
const simulation = @import("simulation.zig");
const std = @import("std");

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
    moving_circle: MovingCircle,
    acceleration_direction: math.FlatVector,
    height: math.Fix32,
    movement_speed: math.Fix32,
    health: Health,

    pub const Health = struct { current: u32, max: u32 };

    pub fn create(
        position: math.FlatVector,
        width: math.Fix32,
        height: math.Fix32,
        movement_speed: math.Fix32,
        max_health: u32,
    ) GameCharacter {
        return .{
            .moving_circle = MovingCircle.create(
                position,
                width.div(fp(2)),
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

        const is_accelerating = !self.acceleration_direction.equal(math.FlatVector.zero);
        if (is_accelerating) {
            const acceleration =
                self.movement_speed.div(simulation.secondsToTicks(0.084).convertTo(math.Fix32));
            self.moving_circle.velocity = self.moving_circle.velocity.add(
                self.acceleration_direction.multiplyScalar(acceleration),
            );
            const speed64 = self.movement_speed.convertTo(math.Fix64);
            if (self.moving_circle.velocity.lengthSquared().gt(speed64.mul(speed64))) {
                self.moving_circle.velocity = self.moving_circle.velocity
                    .normalizeApproximate().multiplyScalar(self.movement_speed);
            }
        } else {
            self.moving_circle.velocity =
                self.moving_circle.velocity.multiplyScalar(fp(simulation.game_unit_stop_factor));
        }
    }
};

pub const Player = struct {
    character: GameCharacter,
    orientation: math.Fix32,
    /// Values from -1 (turning left) to 1 (turning right).
    turning_direction: math.Fix32,
    camera: ThirdPersonCamera,
    animation_cycle: animation.FourStepCycle,
    gem_count: u64,
    input_state: std.EnumArray(InputButton, bool),
    values_from_previous_tick: ValuesForRendering,

    const full_rotation = fp(360).toRadians();
    const rotation_per_tick =
        full_rotation.div(simulation.secondsToTicks(1.7).convertTo(math.Fix32));
    const min_velocity_for_animation = simulation.kphToGameUnitsPerTick(2).convertTo(math.Fix64);

    pub fn create(
        starting_position_x: math.Fix32,
        starting_position_z: math.Fix32,
        spritesheet_frame_ratio: math.Fix32,
    ) Player {
        const in_game_height = fp(1.8);
        const character = GameCharacter.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_height.div(spritesheet_frame_ratio),
            in_game_height,
            simulation.kphToGameUnitsPerTick(30),
            100,
        );
        const orientation = fp(0);
        const camera =
            ThirdPersonCamera.create(
            character.moving_circle.getPosition(),
            orientation,
        );
        const animation_cycle = animation.FourStepCycle.create();
        return .{
            .character = character,
            .orientation = orientation,
            .turning_direction = fp(0),
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
        interval_between_previous_and_current_tick: math.Fix32,
    ) void {
        // Input is relative to the state currently on screen.
        const state_rendered_to_screen = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        );
        const forward_direction =
            state_rendered_to_screen.camera.getDirectionToTarget().toFlatVector();
        const right_direction = forward_direction.rotateRightBy90Degrees();

        var acceleration_direction = math.FlatVector.zero;
        var turning_direction = fp(0);
        if (self.input_state.get(.left)) {
            if (self.input_state.get(.strafe)) {
                acceleration_direction = acceleration_direction.subtract(right_direction);
            } else if (self.input_state.get(.slow_turning)) {
                turning_direction = turning_direction.sub(fp(0.05));
            } else {
                turning_direction = turning_direction.sub(fp(1));
            }
        }
        if (self.input_state.get(.right)) {
            if (self.input_state.get(.strafe)) {
                acceleration_direction = acceleration_direction.add(right_direction);
            } else if (self.input_state.get(.slow_turning)) {
                turning_direction = turning_direction.add(fp(0.05));
            } else {
                turning_direction = turning_direction.add(fp(1));
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

        self.orientation = self.orientation.sub(self.turning_direction.mul(rotation_per_tick));
        self.camera.processElapsedTick(
            self.character.moving_circle.getPosition(),
            self.orientation,
        );
        self.animation_cycle.processElapsedTick(
            self.character.moving_circle.velocity.length().convertTo(math.Fix32).mul(fp(0.75)),
        );
    }

    pub fn getBillboardData(
        self: Player,
        spritesheet: SpriteSheetTexture,
        interval_between_previous_and_current_tick: math.Fix32,
    ) SpriteData {
        const state_to_render = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        );
        const animation_frame =
            if (state_to_render.velocity.length().lt(min_velocity_for_animation))
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

    pub fn getCamera(
        self: Player,
        interval_between_previous_and_current_tick: math.Fix32,
    ) ThirdPersonCamera {
        return self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        ).camera;
    }

    fn setTurningDirection(self: *Player, turning_direction: math.Fix32) void {
        self.turning_direction = turning_direction.clamp(fp(-1), fp(1));
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
        radius: math.Fix32,
        height: math.Fix32,
        velocity: math.FlatVector,
        camera: ThirdPersonCamera,
        animation_cycle: animation.FourStepCycle,

        pub fn lerp(
            self: ValuesForRendering,
            other: ValuesForRendering,
            t: math.Fix32,
        ) ValuesForRendering {
            return .{
                .position = self.position.lerp(other.position, t),
                .radius = self.radius.lerp(other.radius, t),
                .height = self.height.lerp(other.height, t),
                .velocity = self.velocity.lerp(other.velocity, t),
                .camera = self.camera.lerp(other.camera, t),
                .animation_cycle = self.animation_cycle.lerp(other.animation_cycle, t),
            };
        }
    };
};

pub fn makeSpriteData(
    position: math.FlatVector,
    radius: math.Fix32,
    height: math.Fix32,
    sprite: SpriteSheetTexture.SpriteId,
    spritesheet: SpriteSheetTexture,
) SpriteData {
    const source = spritesheet.getSpriteTexcoords(sprite);
    return .{
        .position = .{
            .x = position.x.convertTo(f32),
            .y = height.convertTo(f32) / 2,
            .z = position.z.convertTo(f32),
        },
        .size = .{ .w = radius.convertTo(f32) * 2, .h = height.convertTo(f32) },
        .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
    };
}
