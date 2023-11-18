const Color = @import("util.zig").Color;
const FlowField = @import("flow_field.zig").Field;
const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const SpatialGrid = @import("spatial_partitioning/grid.zig").Grid;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const ThirdPersonCamera = @import("third_person_camera.zig").Camera;
const collision = @import("collision.zig");
const makeSpriteData = @import("game_unit.zig").makeSpriteData;
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");

/// Used for initializing enemies.
pub const Config = struct {
    /// Non-owning slice. Will be referenced by all enemies created with this configuration.
    name: []const u8,
    sprite: SpriteSheetTexture.SpriteId,
    movement_speed: IdleAndAttackingValues,
    aggro_radius: IdleAndAttackingValues,
    height: f32,
    max_health: u32,

    const IdleAndAttackingValues = struct { idle: f32, attacking: f32 };
};

pub const TickContext = struct {
    rng: std.rand.Random,
    map: *const Map,
    main_character: *const GameCharacter,
    main_character_flow_field: *const FlowField,
    attacking_enemy_positions_at_previous_tick: *const EnemyPositionGrid,
};

pub const EnemyPositionGrid = SpatialGrid(AttackingEnemyPosition, position_grid_cell_size, .insert_only);
pub const AttackingEnemyPosition = struct {
    position: math.FlatVector,
    acceleration_direction: math.FlatVector,
};
const position_grid_cell_size = 3;

pub const Enemy = struct {
    config: *const Config,
    character: GameCharacter,
    state: State,

    values_from_previous_tick: ValuesForRendering,
    prepared_render_data: struct {
        values: ValuesForRendering,
        should_render_name: bool,
        should_render_health_bar: bool,
    },

    const enemy_name_font_scale = 1;
    const health_bar_scale = 1;
    const health_bar_height = health_bar_scale * 6;
    const peer_overlap_radius = @as(f32, @floatFromInt(position_grid_cell_size)) / 10.0;
    const peer_flock_radius = peer_overlap_radius * 4.0;

    pub fn create(
        position: math.FlatVector,
        /// Returned object will keep a reference to this config.
        config: *const Config,
        spritesheet: SpriteSheetTexture,
    ) Enemy {
        const character = GameCharacter.create(
            position,
            config.height / spritesheet.getSpriteAspectRatio(config.sprite),
            config.height,
            0,
            config.max_health,
        );
        const render_values = .{
            .position = character.moving_circle.getPosition(),
            .radius = character.moving_circle.radius,
            .height = character.height,
            .health = character.health,
        };
        return .{
            .config = config,
            .character = character,
            .state = .{ .spawning = undefined },
            .values_from_previous_tick = render_values,
            .prepared_render_data = .{
                .values = render_values,
                .should_render_name = true,
                .should_render_health_bar = true,
            },
        };
    }

    pub fn processElapsedTick(self: *Enemy, context: TickContext) void {
        self.values_from_previous_tick = self.getValuesForRendering();
        switch (self.state) {
            .spawning => self.state = .{ .idle = IdleState.create(context) },
            .idle => |*state| state.handleElapsedTick(self, context),
            .attacking => |*state| state.handleElapsedTick(self, context),
            else => {},
        }
        self.character.processElapsedTick(context.map.*);
    }

    pub fn prepareRender(
        self: *Enemy,
        camera: ThirdPersonCamera,
        interval_between_previous_and_current_tick: f32,
    ) void {
        const values_to_render = self.values_from_previous_tick.lerp(
            self.getValuesForRendering(),
            interval_between_previous_and_current_tick,
        );

        const distance_from_camera = values_to_render.position
            .toVector3d().subtract(camera.getPosition()).lengthSquared();
        const max_text_render_distance = values_to_render.height * 15;
        const max_health_render_distance = values_to_render.height * 35;
        self.prepared_render_data = .{
            .values = values_to_render,
            .should_render_name = distance_from_camera <
                max_text_render_distance * max_text_render_distance,
            .should_render_health_bar = distance_from_camera <
                max_health_render_distance * max_health_render_distance,
        };
    }

    pub fn getBillboardCount(self: Enemy) usize {
        var billboard_count: usize = 1; // Enemy sprite.
        if (self.prepared_render_data.should_render_name) {
            billboard_count += text_rendering.getSpriteCount(&self.getNameText());
        }
        if (self.prepared_render_data.should_render_health_bar) {
            billboard_count += 2;
        }

        return billboard_count;
    }

    pub fn populateBillboardData(
        self: Enemy,
        spritesheet: SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []rendering.SpriteData,
    ) void {
        const offset_to_player_height_factor = 1.2;
        out[0] = makeSpriteData(
            self.prepared_render_data.values.position,
            self.prepared_render_data.values.radius,
            self.prepared_render_data.values.height,
            self.config.sprite,
            spritesheet,
        );

        var offset_to_name_letters: usize = 1;
        var pixel_offset_for_name_y: i16 = 0;
        if (self.prepared_render_data.should_render_health_bar) {
            populateHealthbarBillboardData(
                self.prepared_render_data.values,
                spritesheet,
                offset_to_player_height_factor,
                out[1..],
            );
            offset_to_name_letters += 2;
            pixel_offset_for_name_y -= health_bar_height * 2;
        }

        if (self.prepared_render_data.should_render_name) {
            const up = math.Vector3d{ .x = 0, .y = 1, .z = 0 };
            text_rendering.populateBillboardDataExactPixelSizeWithOffset(
                &self.getNameText(),
                self.prepared_render_data.values.position.toVector3d()
                    .add(up.scale(self.prepared_render_data.values.height *
                    offset_to_player_height_factor)),
                0,
                pixel_offset_for_name_y,
                spritesheet.getFontSizeMultiple(enemy_name_font_scale),
                spritesheet,
                out[offset_to_name_letters..],
            );
        }
    }

    pub fn makeSpacingBoundaries(position: math.FlatVector) collision.Circle {
        return .{ .position = position, .radius = Enemy.peer_flock_radius };
    }

    pub fn makeAttackingEnemyPosition(self: Enemy) AttackingEnemyPosition {
        return .{
            .position = self.character.moving_circle.getPosition(),
            .acceleration_direction = self.character.acceleration_direction,
        };
    }

    pub fn populateHealthbarBillboardData(
        values_to_render: ValuesForRendering,
        spritesheet: SpriteSheetTexture,
        offset_to_player_height_factor: f32,
        out: []rendering.SpriteData,
    ) void {
        const health_percent =
            @as(f32, @floatFromInt(values_to_render.health.current)) /
            @as(f32, @floatFromInt(values_to_render.health.max));
        const source = spritesheet.getSpriteTexcoords(.white_block);
        const billboard_data = .{
            .position = .{
                .x = values_to_render.position.x,
                .y = values_to_render.height * offset_to_player_height_factor,
                .z = values_to_render.position.z,
            },
            .size = .{
                .w = health_bar_scale *
                    // This factor has been determined by trial and error.
                    std.math.log1p(@as(f32, @floatFromInt(values_to_render.health.max))) * 8,
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

    fn getNameText(self: Enemy) [1]text_rendering.TextSegment {
        return .{.{ .color = Color.white, .text = self.config.name }};
    }

    fn getValuesForRendering(self: Enemy) ValuesForRendering {
        return .{
            .position = self.character.moving_circle.getPosition(),
            .radius = self.character.moving_circle.radius,
            .height = self.character.height,
            .health = self.character.health,
        };
    }
};

const State = union(enum) {
    spawning: void,
    idle: IdleState,
    attacking: AttackingState,
    dead: void,
};

const ValuesForRendering = struct {
    position: math.FlatVector,
    radius: f32,
    height: f32,
    health: GameCharacter.Health,

    pub fn lerp(
        self: ValuesForRendering,
        other: ValuesForRendering,
        t: f32,
    ) ValuesForRendering {
        return .{
            .position = self.position.lerp(other.position, t),
            .radius = math.lerp(self.radius, other.radius, t),
            .height = math.lerp(self.height, other.height, t),
            .health = .{
                .current = math.lerpU32(self.health.current, other.health.current, t),
                .max = math.lerpU32(self.health.max, other.health.max, t),
            },
        };
    }
};

const IdleState = struct {
    ticks_until_movement: u32,
    visibility_checker: VisibilityChecker(visibility_check_interval),

    const standing_interval = simulation.secondsToTicks(u32, 20);
    const visibility_check_interval = simulation.millisecondsToTicks(u32, 200);

    fn create(context: TickContext) IdleState {
        var visibility_checker = VisibilityChecker(visibility_check_interval).create(false);

        // Add some variance in case many monsters spawn at the same time. This prevents them
        // from doing expensive checks during the same tick and evens out CPU load.
        visibility_checker.ticks_remaining =
            context.rng.intRangeAtMost(u32, 0, visibility_check_interval);
        return .{ .ticks_until_movement = 0, .visibility_checker = visibility_checker };
    }

    fn handleElapsedTick(self: *IdleState, enemy: *Enemy, context: TickContext) void {
        const is_seeing_main_character = self.visibility_checker.isSeeingMainCharacter(
            context,
            enemy.*,
            enemy.config.aggro_radius.idle,
        );
        if (is_seeing_main_character) {
            enemy.state = .{ .attacking = AttackingState.create() };
            return;
        }
        if (consumeTick(&self.ticks_until_movement)) {
            return;
        }

        if (context.rng.boolean()) { // Walk.
            const direction = std.math.degreesToRadians(f32, 360 * context.rng.float(f32));
            const forward = math.FlatVector{ .x = 0, .z = -1 };
            enemy.character.acceleration_direction = forward.rotate(direction);
            enemy.character.movement_speed = enemy.config.movement_speed.idle;
            self.ticks_until_movement =
                context.rng.intRangeAtMost(u32, 0, simulation.secondsToTicks(u32, 4));
        } else {
            enemy.character.acceleration_direction = math.FlatVector.zero;
            self.ticks_until_movement = context.rng.intRangeAtMost(u32, 0, standing_interval);
        }
    }
};

const AttackingState = struct {
    visibility_checker: VisibilityChecker(visibility_check_interval),

    const visibility_check_interval = simulation.millisecondsToTicks(u32, 2000);
    const enemy_friction_constant = 1 - 1 / simulation.kphToGameUnitsPerTick(432);

    fn create() AttackingState {
        return .{
            .visibility_checker = VisibilityChecker(visibility_check_interval).create(true),
        };
    }

    fn handleElapsedTick(self: *AttackingState, enemy: *Enemy, context: TickContext) void {
        enemy.character.movement_speed = enemy.config.movement_speed.attacking;

        const position = enemy.character.moving_circle.getPosition();
        const is_seeing_main_character = self.visibility_checker.isSeeingMainCharacter(
            context,
            enemy.*,
            enemy.config.aggro_radius.attacking,
        );
        if (is_seeing_main_character) {
            enemy.character.acceleration_direction =
                context.main_character.moving_circle.getPosition().subtract(position).normalize();
        } else if (context.main_character_flow_field.getDirection(position, context.map.*)) |direction| {
            enemy.character.acceleration_direction = direction;
        } else {
            enemy.state = .{ .idle = IdleState.create(context) };
            return;
        }

        const circle = collision.Circle{ .position = position, .radius = Enemy.peer_overlap_radius };
        const direction = enemy.character.moving_circle.velocity.normalize();
        var iterator = context.attacking_enemy_positions_at_previous_tick.areaIterator(
            circle.getOuterBoundingBoxInGameCoordinates(),
        );
        var combined_displacement_vector = math.FlatVector.zero;
        var friction_factor: f32 = 1;
        var collides_with_peer = false;
        var average_velocity = AverageAccumulator.create(enemy.character.moving_circle.velocity);
        var average_acceleration_direction =
            AverageAccumulator.create(enemy.character.acceleration_direction);
        while (iterator.next()) |peer| {
            // Ignore self.
            if (math.isEqual(enemy.values_from_previous_tick.position.x, peer.position.x) and
                math.isEqual(enemy.values_from_previous_tick.position.z, peer.position.z))
            {
                continue;
            }

            const peer_circle = .{ .position = peer.position, .radius = Enemy.peer_overlap_radius };
            if (circle.collidesWithCircleDisplacementVector(peer_circle)) |displacement_vector| {
                collides_with_peer = true;
                combined_displacement_vector = combined_displacement_vector.add(displacement_vector);
                friction_factor *= 1 + enemy_friction_constant * std.math
                    .clamp(direction.dotProduct(displacement_vector.normalize()), -1, 0);
            } else if (!collides_with_peer) {
                const offset_to_peer = position.subtract(peer.position);
                const direction_to_peer = offset_to_peer.normalize();
                const distance_factor = @min(1, offset_to_peer.length() / Enemy.peer_flock_radius);
                average_velocity.add(
                    direction_to_peer.scale(enemy.character.movement_speed).lerp(
                        enemy.character.moving_circle.velocity,
                        distance_factor,
                    ),
                );
                const slowdown =
                    1 + std.math.clamp(direction.dotProduct(direction_to_peer.negate()), -1, 0);
                average_acceleration_direction.add(peer.acceleration_direction.scale(slowdown));
            }
        }

        if (collides_with_peer) {
            enemy.character.moving_circle.velocity =
                enemy.character.moving_circle.velocity.add(combined_displacement_vector);
            if (enemy.character.moving_circle.velocity.lengthSquared() >
                enemy.character.movement_speed * enemy.character.movement_speed)
            {
                enemy.character.moving_circle.velocity = enemy.character.moving_circle.velocity
                    .normalize().scale(enemy.character.movement_speed);
            }
            enemy.character.moving_circle.velocity =
                enemy.character.moving_circle.velocity.scale(friction_factor);
        } else {
            enemy.character.moving_circle.velocity = average_velocity.compute();
            enemy.character.acceleration_direction = average_acceleration_direction.compute();
        }
    }

    const AverageAccumulator = struct {
        total: math.FlatVector,
        count: f32,

        fn create(initial_value: math.FlatVector) AverageAccumulator {
            return .{ .total = initial_value, .count = 1 };
        }

        fn add(self: *AverageAccumulator, value: math.FlatVector) void {
            self.total = self.total.add(value);
            self.count += 1;
        }

        fn compute(self: AverageAccumulator) math.FlatVector {
            return self.total.scale(1.0 / self.count);
        }
    };
};

/// Return true if the tick was not consumed completely.
fn consumeTick(tick: *u32) bool {
    if (tick.* == 0) {
        return false;
    }
    tick.* -= 1;
    return true;
}

fn VisibilityChecker(comptime tick_interval: u32) type {
    return struct {
        ticks_remaining: u32,
        is_seeing: bool,

        const Self = @This();

        fn create(initial_value: bool) Self {
            return .{ .ticks_remaining = tick_interval, .is_seeing = initial_value };
        }

        fn isSeeingMainCharacter(
            self: *Self,
            context: TickContext,
            enemy: Enemy,
            aggro_radius: f32,
        ) bool {
            if (consumeTick(&self.ticks_remaining)) {
                return self.is_seeing;
            }
            self.ticks_remaining = tick_interval;

            var enemy_boundaries = enemy.character.moving_circle;
            enemy_boundaries.radius += aggro_radius;
            if (enemy_boundaries.hasCollidedWith(context.main_character.moving_circle)) |positions| {
                self.is_seeing =
                    !context.map.geometry.isSolidWallBetweenPoints(positions.self, positions.other);
            } else {
                self.is_seeing = false;
            }
            return self.is_seeing;
        }
    };
}
