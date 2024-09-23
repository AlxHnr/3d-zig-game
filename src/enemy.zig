const Color = rendering.Color;
const FlowField = @import("flow_field.zig");
const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const SpatialGrid = @import("spatial_partitioning/grid.zig").Grid;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const ThirdPersonCamera = @import("third_person_camera.zig");
const collision = @import("collision.zig");
const enemy_presets = @import("enemy_presets.zig");
const fp = math.Fix32.fp;
const fp64 = math.Fix64.fp;
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
    height: math.Fix32,
    max_health: u32,

    const IdleAndAttackingValues = struct { idle: math.Fix32, attacking: math.Fix32 };
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
    /// For interpolating between two ticks.
    previous_tick_data: TickData,

    const State = union(enum) {
        spawning: void,
        idle: IdleState,
        attacking: AttackingState,
        dead: void,
    };

    const enemy_name_font_scale = 1;
    const health_bar_scale = fp(1);
    const health_bar_height = health_bar_scale.mul(fp(6));
    const offset_to_player_height_factor = fp(1.2);
    const peer_overlap_radius =
        fp(position_grid_cell_size).div(fp(simulation.enemy_peer_overlap_radius_factor));
    const peer_flock_radius = fp(position_grid_cell_size).div(fp(10)).mul(fp(4));

    pub fn create(
        position: math.FlatVector,
        /// Returned object will keep a reference to this config.
        config: *const Config,
        spritesheet: SpriteSheetTexture,
    ) Enemy {
        const character = GameCharacter.create(
            position,
            config.height.div(spritesheet.getSpriteAspectRatio(config.sprite)),
            config.height,
            fp(0),
            config.max_health,
        );
        return .{
            .config = config,
            .character = character,
            .state = .{ .spawning = undefined },
            .previous_tick_data = TickData.create(character),
        };
    }

    pub fn processElapsedTick(self: *Enemy, context: TickContext) void {
        self.previous_tick_data = TickData.create(self.character);
        switch (self.state) {
            .spawning => self.state = .{ .idle = IdleState.create(context) },
            .idle => |*state| state.handleElapsedTick(self, context),
            .attacking => |*state| state.handleElapsedTick(self, context),
            else => {},
        }
        self.character.processElapsedTick(context.map.*);
    }

    pub fn appendBillboardData(
        self: Enemy,
        spritesheet: SpriteSheetTexture,
        cache: PrerenderedNames,
        camera: ThirdPersonCamera,
        previous_tick: u32,
        out: *std.ArrayList(rendering.SpriteData),
    ) !void {
        const y_offset = self.character.height.div(fp(2));
        try out.append(rendering.SpriteData.create(
            self.previous_tick_data.position.addY(y_offset),
            spritesheet.getSpriteSourceRectangle(self.config.sprite),
            self.character.moving_circle.radius.mul(fp(2)),
            self.config.height,
        ).withAnimationStartTick(previous_tick).withAnimationTargetPosition(
            self.character.moving_circle.getPosition().addY(y_offset),
        ));

        const distance = self.character.moving_circle.getPosition().toVector3d()
            .subtract(camera.getPosition()).lengthSquared();
        const max_text_distance = self.character.height.convertTo(math.Fix64).mul(fp64(15));
        const max_health_distance = self.character.height.convertTo(math.Fix64).mul(fp64(35));
        if (distance.lt(max_health_distance.mul(max_health_distance))) {
            try out.ensureUnusedCapacity(2);
            self.populateHealthbarBillboardData(
                spritesheet,
                previous_tick,
                out.unusedCapacitySlice(),
            );
            out.items.len += 2;
        }

        if (distance.lt(max_text_distance.mul(max_text_distance))) {
            const cached_text = cache.get(self.config);
            const text_y_offset = self.character.height.mul(offset_to_player_height_factor);
            const previous_position = self.previous_tick_data.position.addY(text_y_offset);
            const current_position = self.character.moving_circle.getPosition().addY(text_y_offset);
            try out.ensureUnusedCapacity(cached_text.len);
            const out_slice = out.unusedCapacitySlice()[0..cached_text.len];
            out.items.len += cached_text.len;

            @memcpy(out_slice, cached_text);
            for (out_slice) |*billboard_data| {
                billboard_data.* = billboard_data
                    .withPosition(previous_position)
                    .withAnimationStartTick(previous_tick)
                    .withAnimationTargetPosition(current_position);
            }
        }
    }

    pub fn makeSpacingBoundaries(position: math.FlatVector) collision.Circle {
        return .{ .position = position, .radius = peer_flock_radius };
    }

    pub fn makeAttackingEnemyPosition(self: Enemy) AttackingEnemyPosition {
        return .{
            .position = self.character.moving_circle.getPosition(),
            .acceleration_direction = self.character.acceleration_direction,
        };
    }

    const TickData = struct {
        position: math.FlatVector,
        health: GameCharacter.Health,

        fn create(character: GameCharacter) TickData {
            return .{
                .position = character.moving_circle.getPosition(),
                .health = character.health,
            };
        }
    };

    fn populateHealthbarBillboardData(
        self: Enemy,
        spritesheet: SpriteSheetTexture,
        previous_tick: u32,
        out: []rendering.SpriteData,
    ) void {
        const health_percent =
            fp(self.character.health.current).div(fp(self.character.health.max));
        const source = spritesheet.getSpriteSourceRectangle(.white_block);
        // This factor has been determined by trial and error.
        const health_bar_factor =
            fp(std.math.log1p(@as(f32, @floatFromInt(self.character.health.max))) * 8);
        const y_offset = self.character.height.mul(offset_to_player_height_factor);
        const previous_position = self.previous_tick_data.position.addY(y_offset);
        const current_position = self.character.moving_circle.getPosition().addY(y_offset);
        const health_bar_w = health_bar_scale.mul(health_bar_factor);
        const full_health = Color.create(21, 213, 21, 255);
        const empty_health = Color.create(213, 21, 21, 255);
        const background = Color.create(0, 0, 0, 255);
        const current_health = empty_health.lerp(full_health, health_percent);

        const left_half = &out[0];
        const left_health_bar_w = health_bar_w.mul(health_percent);
        left_half.* = rendering.SpriteData.create(
            previous_position,
            source,
            left_health_bar_w,
            health_bar_height,
        ).withOffsetFromOrigin(health_bar_w.sub(left_health_bar_w).neg().div(fp(2)), fp(0))
            .withTint(current_health)
            .withPreserveExactPixelSize(true)
            .withAnimationStartTick(previous_tick).withAnimationTargetPosition(current_position);

        const right_half = &out[1];
        const right_health_bar_w = health_bar_w.mul(fp(1).sub(health_percent));
        right_half.* = rendering.SpriteData.create(
            previous_position,
            source,
            right_health_bar_w,
            health_bar_height,
        ).withOffsetFromOrigin(health_bar_w.sub(right_health_bar_w).div(fp(2)), fp(0))
            .withTint(background)
            .withPreserveExactPixelSize(true)
            .withAnimationStartTick(previous_tick).withAnimationTargetPosition(current_position);
    }
};

pub const PrerenderedNames = struct {
    cache: Cache,

    const Cache = std.AutoHashMap(*const Config, []rendering.SpriteData);

    pub fn create(
        allocator: std.mem.Allocator,
        spritesheet: SpriteSheetTexture,
    ) !PrerenderedNames {
        var cache = Cache.init(allocator);
        errdefer cache.deinit();
        errdefer {
            var iterator = cache.valueIterator();
            while (iterator.next()) |billboard_data| {
                allocator.free(billboard_data.*);
            }
        }
        for (enemy_preset_addresses) |preset_ptr| {
            const text_segment = &[_]text_rendering.TextSegment{
                .{ .color = Color.white, .text = preset_ptr.name },
            };
            const billboard_count = text_rendering.getSpriteCount(text_segment);
            const billboard_data = try allocator.alloc(rendering.SpriteData, billboard_count);
            errdefer allocator.free(billboard_data);

            text_rendering.populateBillboardDataExactPixelSizeWithOffset(
                text_segment,
                .{ .x = fp(0), .y = fp(0), .z = fp(0) },
                0,
                Enemy.health_bar_height.mul(fp(2)).convertTo(i16),
                spritesheet.getFontSizeMultiple(Enemy.enemy_name_font_scale),
                spritesheet,
                billboard_data,
            );
            try cache.put(preset_ptr, billboard_data);
        }
        return .{ .cache = cache };
    }

    pub fn destroy(self: *PrerenderedNames, allocator: std.mem.Allocator) void {
        var iterator = self.cache.valueIterator();
        while (iterator.next()) |billboard_data| {
            allocator.free(billboard_data.*);
        }
        self.cache.deinit();
    }

    fn get(self: PrerenderedNames, config: *const Config) []const rendering.SpriteData {
        const result = self.cache.get(config);
        std.debug.assert(result != null);
        return result.?;
    }

    const enemy_preset_addresses = blk: {
        var addresses: [@typeInfo(enemy_presets).Struct.decls.len]*const Config = undefined;
        for (@typeInfo(enemy_presets).Struct.decls, 0..) |field, index| {
            addresses[index] = &@field(enemy_presets, field.name);
        }
        break :blk addresses;
    };
};

const IdleState = struct {
    ticks_until_movement: u32,
    visibility_checker: VisibilityChecker(visibility_check_interval),

    const standing_interval = simulation.secondsToTicks(20).convertTo(u32);
    const visibility_check_interval = simulation.secondsToTicks(0.2).convertTo(u32);

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
            const direction = fp(context.rng.intRangeLessThan(u16, 0, 360)).toRadians();
            const forward = math.FlatVector{ .x = fp(0), .z = fp(-1) };
            enemy.character.acceleration_direction = forward.rotate(direction);
            enemy.character.movement_speed = enemy.config.movement_speed.idle;
            self.ticks_until_movement =
                context.rng.intRangeAtMost(u32, 0, simulation.secondsToTicks(4).convertTo(u32));
        } else {
            enemy.character.acceleration_direction = math.FlatVector.zero;
            self.ticks_until_movement = context.rng.intRangeAtMost(u32, 0, standing_interval);
        }
    }
};

const AttackingState = struct {
    visibility_checker: VisibilityChecker(visibility_check_interval),

    const visibility_check_interval = simulation.secondsToTicks(2).convertTo(u32);
    const enemy_friction_constant = fp(1).sub(fp(1).div(simulation.kphToGameUnitsPerTick(432)));

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

        const circle = collision.Circle{
            .position = position,
            .radius = Enemy.peer_overlap_radius,
        };
        const direction = enemy.character.moving_circle.velocity.normalize();
        var iterator = context.attacking_enemy_positions_at_previous_tick.areaIterator(
            circle.getOuterBoundingBoxInGameCoordinates(),
        );
        var combined_displacement_vector = math.FlatVector.zero;
        var friction_factor = fp(1);
        var collides_with_peer = false;
        var average_velocity = AverageAccumulator.create(enemy.character.moving_circle.velocity);
        var average_acceleration_direction =
            AverageAccumulator.create(enemy.character.acceleration_direction);
        while (iterator.next()) |peer| {
            // Ignore self.
            if (peer.position.equal(enemy.previous_tick_data.position)) {
                continue;
            }

            const peer_circle = .{ .position = peer.position, .radius = Enemy.peer_overlap_radius };
            if (circle.collidesWithCircleDisplacementVector(peer_circle)) |displacement_vector| {
                collides_with_peer = true;
                combined_displacement_vector = combined_displacement_vector.add(displacement_vector);
                friction_factor = friction_factor.mul(fp(1).add(
                    enemy_friction_constant.mul(
                        direction.dotProduct(displacement_vector.normalizeApproximate())
                            .convertTo(math.Fix32).clamp(fp(-1), fp(0)),
                    ),
                ));
            } else if (!collides_with_peer) {
                const offset_to_peer = position.subtract(peer.position);
                const direction_to_peer = offset_to_peer.normalizeApproximate();
                const distance_factor = fp(1).min(
                    offset_to_peer.lengthApproximate()
                        .convertTo(math.Fix32).div(Enemy.peer_flock_radius),
                );
                average_velocity.add(
                    direction_to_peer.multiplyScalar(enemy.character.movement_speed).lerp(
                        enemy.character.moving_circle.velocity,
                        distance_factor,
                    ),
                );
                const slowdown = fp(1).add(direction.dotProduct(direction_to_peer.negate())
                    .convertTo(math.Fix32).clamp(fp(-1), fp(0)));
                average_acceleration_direction.add(
                    peer.acceleration_direction.multiplyScalar(slowdown),
                );
            }
        }

        if (collides_with_peer) {
            enemy.character.moving_circle.velocity =
                enemy.character.moving_circle.velocity.add(combined_displacement_vector);
            const speed64 = enemy.character.movement_speed.convertTo(math.Fix64);
            if (enemy.character.moving_circle.velocity.lengthSquared().gt(speed64.mul(speed64))) {
                enemy.character.moving_circle.velocity = enemy.character.moving_circle.velocity
                    .normalize().multiplyScalar(enemy.character.movement_speed);
            }
            enemy.character.moving_circle.velocity =
                enemy.character.moving_circle.velocity.multiplyScalar(friction_factor);
        } else {
            enemy.character.moving_circle.velocity = average_velocity.compute();
            enemy.character.acceleration_direction = average_acceleration_direction.compute();
        }
    }

    const AverageAccumulator = struct {
        total: math.FlatVector,
        count: math.Fix32,

        fn create(initial_value: math.FlatVector) AverageAccumulator {
            return .{ .total = initial_value, .count = fp(1) };
        }

        fn add(self: *AverageAccumulator, value: math.FlatVector) void {
            self.total = self.total.add(value);
            self.count = self.count.add(fp(1));
        }

        fn compute(self: AverageAccumulator) math.FlatVector {
            return self.total.multiplyScalar(fp(1).div(self.count));
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
            aggro_radius: math.Fix32,
        ) bool {
            if (consumeTick(&self.ticks_remaining)) {
                return self.is_seeing;
            }
            self.ticks_remaining = tick_interval;

            var enemy_boundaries = enemy.character.moving_circle;
            enemy_boundaries.radius = enemy_boundaries.radius.add(aggro_radius);
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
