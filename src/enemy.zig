const Color = @import("util.zig").Color;
const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const SharedContext = @import("shared_context.zig").SharedContext;
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
    height: f32,
    movement_speed: struct { idle: f32, attacking: f32 },
    max_health: u32,
    aggro_radius: struct { idle: f32, attacking: f32 },
};

pub const Enemy = struct {
    config: Config,
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

    pub fn create(
        object_id_generator: *ObjectIdGenerator,
        position: math.FlatVector,
        config: Config,
        spritesheet: SpriteSheetTexture,
    ) Enemy {
        const character = GameCharacter.create(
            object_id_generator,
            position,
            config.height / spritesheet.getSpriteAspectRatio(config.sprite),
            config.height,
            0,
            config.max_health,
        );
        const render_values = .{
            .boundaries = character.boundaries,
            .height = character.height,
            .health = character.health,
        };
        return .{
            .character = character,
            .config = config,
            .state = .{ .spawning = undefined },
            .values_from_previous_tick = render_values,
            .prepared_render_data = .{
                .values = render_values,
                .should_render_name = true,
                .should_render_health_bar = true,
            },
        };
    }

    pub fn processElapsedTick(
        self: *Enemy,
        shared_context: *SharedContext,
        main_character: GameCharacter,
        map: Map,
    ) void {
        self.values_from_previous_tick = self.getValuesForRendering();

        var context = .{
            .shared_context = shared_context,
            .main_character = &main_character,
            .map = &map,
        };
        switch (self.state) {
            .spawning => self.handleSpawningState(context),
            .idle => self.handleIdleState(context),
            .attacking => self.handleAttackingState(context),
            else => {},
        }

        var remaining_velocity = self.character.processElapsedTickInit();
        while (self.character.processElapsedTickConsume(&remaining_velocity, map)) {}
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

        const distance_from_camera = values_to_render.boundaries.position
            .toVector3d().subtract(camera.position).lengthSquared();
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
            self.prepared_render_data.values.boundaries,
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
                self.prepared_render_data.values.boundaries.position.toVector3d()
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

    fn getNameText(self: Enemy) [1]text_rendering.TextSegment {
        return .{.{ .color = Color.white, .text = self.config.name }};
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
                .x = values_to_render.boundaries.position.x,
                .y = values_to_render.height * offset_to_player_height_factor,
                .z = values_to_render.boundaries.position.z,
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

    fn getValuesForRendering(self: Enemy) ValuesForRendering {
        return .{
            .boundaries = self.character.boundaries,
            .height = self.character.height,
            .health = self.character.health,
        };
    }

    /// Return true if the tick was not consumed completely.
    fn consumeTick(tick: *u64) bool {
        if (tick.* == 0) {
            return false;
        }
        tick.* -= 1;
        return true;
    }

    fn isSeeingTarget(self: *Enemy, context: TickContextPointers, aggro_radius: f32) bool {
        const offset_to_main_character = context.main_character.boundaries.position
            .subtract(self.character.boundaries.position);
        return offset_to_main_character.lengthSquared() < aggro_radius * aggro_radius and
            !context.map.geometry.isSolidWallBetweenPoints(
            self.character.boundaries.position,
            context.main_character.boundaries.position,
        );
    }

    const TickContextPointers = struct {
        shared_context: *SharedContext,
        main_character: *const GameCharacter,
        map: *const Map,
    };

    fn handleSpawningState(self: *Enemy, _: TickContextPointers) void {
        self.state = .{ .idle = .{ .ticks_remaining = 0 } };
    }

    fn handleIdleState(self: *Enemy, context: TickContextPointers) void {
        if (self.isSeeingTarget(context, self.config.aggro_radius.idle)) {
            self.state = .{ .attacking = undefined };
            return;
        }
        if (consumeTick(&self.state.idle.ticks_remaining)) {
            return;
        }

        var rng = context.shared_context.rng.random();
        if (rng.boolean()) { // Walk.
            const direction = std.math.degreesToRadians(f32, 360 * rng.float(f32));
            const forward = math.FlatVector{ .x = 0, .z = -1 };
            self.character.setAcceleration(forward.rotate(direction));
            self.character.movement_speed = self.config.movement_speed.idle;
            self.state.idle.ticks_remaining =
                rng.intRangeAtMost(u64, 0, simulation.secondsToTicks(4));
        } else { // Stand still.
            self.character.setAcceleration(.{ .x = 0, .z = 0 });
            self.state.idle.ticks_remaining =
                rng.intRangeAtMost(u64, 0, simulation.secondsToTicks(20));
        }
    }

    fn handleAttackingState(self: *Enemy, context: TickContextPointers) void {
        if (!self.isSeeingTarget(context, self.config.aggro_radius.attacking)) {
            self.state = .{ .idle = .{ .ticks_remaining = 0 } };
            return;
        }

        const offset_to_target = context.main_character.boundaries.position
            .subtract(self.character.boundaries.position);
        const distance_to_target = offset_to_target.lengthSquared();
        const min_distance_to_target =
            self.character.boundaries.radius + context.main_character.boundaries.radius;
        if (distance_to_target > min_distance_to_target * min_distance_to_target) {
            self.character.movement_speed = self.config.movement_speed.attacking;
            self.character.setAcceleration(offset_to_target.normalize());
        } else {
            self.character.setAcceleration(.{ .x = 0, .z = 0 });
        }
    }
};

const State = union(enum) {
    spawning: void,
    idle: struct { ticks_remaining: u64 },
    attacking: void,
    dead: void,
};

const ValuesForRendering = struct {
    boundaries: collision.Circle,
    height: f32,
    health: GameCharacter.Health,

    pub fn lerp(
        self: ValuesForRendering,
        other: ValuesForRendering,
        t: f32,
    ) ValuesForRendering {
        return .{
            .boundaries = self.boundaries.lerp(other.boundaries, t),
            .height = math.lerp(self.height, other.height, t),
            .health = .{
                .current = math.lerpU32(self.health.current, other.health.current, t),
                .max = math.lerpU32(self.health.max, other.health.max, t),
            },
        };
    }
};
