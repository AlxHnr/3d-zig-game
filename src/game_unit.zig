const Color = @import("util.zig").Color;
const Map = @import("map/map.zig").Map;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const gems = @import("gems.zig");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
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

pub const Stats = struct {
    height: f32,
    movement_speed: f32,
    health: struct { current: u32, max: u32 },

    pub fn create(height: f32, movement_speed: f32, max_health: u32) Stats {
        return .{
            .height = height,
            .movement_speed = movement_speed,
            .health = .{ .current = max_health, .max = max_health },
        };
    }

    pub fn lerp(self: Stats, other: Stats, t: f32) Stats {
        return .{
            .height = math.lerp(self.height, other.height, t),
            .movement_speed = math.lerp(self.movement_speed, other.movement_speed, t),
            .health = .{
                .current = math.lerpU32(self.health.current, other.health.current, t),
                .max = math.lerpU32(self.health.max, other.health.max, t),
            },
        };
    }
};

pub const GameCharacter = struct {
    boundaries: collision.Circle,
    acceleration_direction: math.FlatVector,
    current_velocity: math.FlatVector,
    stats: Stats,

    pub fn create(position: math.FlatVector, width: f32, stats: Stats) GameCharacter {
        return .{
            .boundaries = .{ .position = position, .radius = width / 2 },
            .acceleration_direction = .{ .x = 0, .z = 0 },
            .current_velocity = .{ .x = 0, .z = 0 },
            .stats = stats,
        };
    }

    pub fn lerp(self: GameCharacter, other: GameCharacter, t: f32) GameCharacter {
        return GameCharacter{
            .boundaries = self.boundaries.lerp(other.boundaries, t),
            .acceleration_direction = self.acceleration_direction.lerp(
                other.acceleration_direction,
                t,
            ),
            .current_velocity = self.current_velocity.lerp(other.current_velocity, t),
            .stats = self.stats.lerp(other.stats, t),
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
            .direction = self.current_velocity.normalize(),
            .magnitude = self.current_velocity.length(),
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
            const acceleration = self.stats.movement_speed / 5.0;
            self.current_velocity =
                self.current_velocity.add(self.acceleration_direction.scale(acceleration));
            if (self.current_velocity.length() > self.stats.movement_speed) {
                self.current_velocity =
                    self.current_velocity.normalize().scale(self.stats.movement_speed);
            }
        } else {
            self.current_velocity = self.current_velocity.scale(0.7);
        }
        return false;
    }

    fn resolveCollision(self: *GameCharacter, displacement_vector: math.FlatVector) void {
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
        const character = GameCharacter.create(
            .{ .x = starting_position_x, .z = starting_position_z },
            in_game_height / spritesheet_frame_ratio,
            Stats.create(in_game_height, 0.15, 100),
        );
        const orientation = 0;
        const state = .{
            .character = character,
            .orientation = orientation,
            .turning_direction = 0,
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
        return makeSpriteData(state_to_render.character, sprite_id, spritesheet);
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
            .height = state.character.stats.height,
        };
    }

    const State = struct {
        character: GameCharacter,
        orientation: f32,
        /// Values from -1 (turning left) to 1 (turning right).
        turning_direction: f32,

        camera: ThirdPersonCamera,
        animation_cycle: animation.FourStepCycle,

        fn lerp(self: State, other: State, t: f32) State {
            return State{
                .character = self.character.lerp(other.character, t),
                .orientation = math.lerp(self.orientation, other.orientation, t),
                .turning_direction = math.lerp(self.turning_direction, other.turning_direction, t),
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
                    .height = self.character.stats.height,
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

pub const Enemy = struct {
    /// Non-owning slice.
    name: []const u8,
    sprite: textures.SpriteSheetTexture.SpriteId,
    state_at_previous_tick: GameCharacter,
    state_at_next_tick: GameCharacter,

    data_to_render: struct {
        state: GameCharacter,
        should_render_name: bool,
        should_render_health_bar: bool,
    },

    const enemy_name_font_scale = 1;
    const health_bar_scale = 1;
    const health_bar_height = health_bar_scale * 6;

    pub fn create(
        /// Will be referenced by the returned object.
        name: []const u8,
        sprite: textures.SpriteSheetTexture.SpriteId,
        spritesheet: textures.SpriteSheetTexture,
        position: math.FlatVector,
        stats: Stats,
    ) Enemy {
        const character = GameCharacter.create(
            position,
            stats.height / spritesheet.getSpriteAspectRatio(sprite),
            stats,
        );
        return .{
            .name = name,
            .sprite = sprite,
            .state_at_previous_tick = character,
            .state_at_next_tick = character,
            .data_to_render = .{
                .state = character,
                .should_render_name = true,
                .should_render_health_bar = true,
            },
        };
    }

    pub fn processElapsedTick(self: *Enemy, map: Map) void {
        self.state_at_previous_tick = self.state_at_next_tick;

        var remaining_velocity = self.state_at_next_tick.processElapsedTickInit();
        while (self.state_at_next_tick.processElapsedTickConsume(&remaining_velocity, map)) {}
    }

    pub fn prepareRender(
        self: *Enemy,
        camera: ThirdPersonCamera,
        interval_between_previous_and_current_tick: f32,
    ) void {
        const state = self.state_at_previous_tick.lerp(
            self.state_at_next_tick,
            interval_between_previous_and_current_tick,
        );

        const distance_from_camera = self.data_to_render.state.boundaries.position
            .toVector3d().subtract(camera.position).lengthSquared();
        const max_text_render_distance = state.stats.height * 25;
        const max_health_render_distance = state.stats.height * 35;
        self.data_to_render = .{
            .state = state,
            .should_render_name = distance_from_camera <
                max_text_render_distance * max_text_render_distance,
            .should_render_health_bar = distance_from_camera <
                max_health_render_distance * max_health_render_distance,
        };
    }

    pub fn getBillboardCount(self: Enemy) usize {
        var billboard_count: usize = 1; // Enemy sprite.
        if (self.data_to_render.should_render_name) {
            billboard_count += text_rendering.getSpriteCount(&self.getNameText());
        }
        if (self.data_to_render.should_render_health_bar) {
            billboard_count += 2;
        }

        return billboard_count;
    }

    pub fn populateBillboardData(
        self: Enemy,
        spritesheet: textures.SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []rendering.SpriteData,
    ) void {
        const state = self.data_to_render.state;
        const offset_to_player_height_factor = 1.2;
        out[0] = makeSpriteData(state, self.sprite, spritesheet);

        var offset_to_name_letters: usize = 1;
        var pixel_offset_for_name_y: i16 = 0;
        if (self.data_to_render.should_render_health_bar) {
            populateHealthbarBillboardData(
                state,
                spritesheet,
                offset_to_player_height_factor,
                out[1..],
            );
            offset_to_name_letters += 2;
            pixel_offset_for_name_y -= health_bar_height * 2;
        }

        if (self.data_to_render.should_render_name) {
            const up = math.Vector3d{ .x = 0, .y = 1, .z = 0 };
            text_rendering.populateBillboardDataExactPixelSizeWithOffset(
                &self.getNameText(),
                state.boundaries.position.toVector3d()
                    .add(up.scale(state.stats.height * offset_to_player_height_factor)),
                0,
                pixel_offset_for_name_y,
                spritesheet.getFontSizeMultiple(enemy_name_font_scale),
                spritesheet,
                out[offset_to_name_letters..],
            );
        }
    }

    fn getNameText(self: Enemy) [1]text_rendering.TextSegment {
        return .{.{ .color = Color.white, .text = self.name }};
    }

    pub fn populateHealthbarBillboardData(
        state: GameCharacter,
        spritesheet: textures.SpriteSheetTexture,
        offset_to_player_height_factor: f32,
        out: []rendering.SpriteData,
    ) void {
        const health_percent =
            @as(f32, @floatFromInt(state.stats.health.current)) /
            @as(f32, @floatFromInt(state.stats.health.max));
        const source = spritesheet.getSpriteTexcoords(.white_block);
        const billboard_data = .{
            .position = .{
                .x = state.boundaries.position.x,
                .y = state.stats.height * offset_to_player_height_factor,
                .z = state.boundaries.position.z,
            },
            .size = .{
                .w = health_bar_scale *
                    // This factor has been determined by trial and error.
                    std.math.log1p(@as(f32, @floatFromInt(state.stats.health.max))) * 8,
                .h = health_bar_height,
            },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
            .preserve_exact_pixel_size = 1,
        };

        const full_health = Color.fromRgb8(21, 213, 21);
        const empty_health = Color.fromRgb8(213, 21, 21);
        const background = Color.fromRgb8(0, 0, 0);
        const current_health = empty_health.lerp(full_health, health_percent);

        var left_half = &out[0];
        left_half.* = billboard_data;
        left_half.size.w *= health_percent;
        left_half.offset_from_origin.x = -(billboard_data.size.w - left_half.size.w) / 2;
        left_half.tint = .{ .r = current_health.r, .g = current_health.g, .b = current_health.b };

        var right_half = &out[1];
        right_half.* = billboard_data;
        right_half.size.w *= 1 - health_percent;
        right_half.offset_from_origin.x = (billboard_data.size.w - right_half.size.w) / 2;
        right_half.tint = .{ .r = background.r, .g = background.g, .b = background.b };
    }
};

fn makeSpriteData(
    character: GameCharacter,
    sprite: textures.SpriteSheetTexture.SpriteId,
    spritesheet: textures.SpriteSheetTexture,
) rendering.SpriteData {
    const source = spritesheet.getSpriteTexcoords(sprite);
    return .{
        .position = .{
            .x = character.boundaries.position.x,
            .y = character.stats.height / 2,
            .z = character.boundaries.position.z,
        },
        .size = .{
            .w = character.boundaries.radius * 2,
            .h = character.stats.height,
        },
        .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
    };
}
