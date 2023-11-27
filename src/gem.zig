const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const math = @import("math.zig");
const simulation = @import("simulation.zig");

position: math.FlatVector,
state: State,
state_at_previous_tick: State,

const Gem = @This();
const animation_speed = simulation.kphToGameUnitsPerTick(10);
const width = 0.4;
const collision_radius = width * 3;

pub fn create(position: math.FlatVector) Gem {
    return .{
        .position = position,
        .state = .{ .spawn_animation_progress = 0 },
        .state_at_previous_tick = .{ .spawn_animation_progress = 0 },
    };
}

pub fn processElapsedTick(self: *Gem, context: TickContext) Result {
    self.state_at_previous_tick = self.state;
    switch (self.state) {
        .spawn_animation_progress => |*progress| {
            progress.* += animation_speed;
            if (progress.* > 1) {
                self.state = .{ .waiting = {} };
            }
        },
        .waiting => blk: {
            const boundaries = .{ .position = self.position, .radius = collision_radius };
            const character_position = context.main_character.moving_circle.hasCollidedWithCircle(
                boundaries,
            ) orelse break :blk;
            if (!context.map.geometry.isSolidWallBetweenPoints(self.position, character_position)) {
                self.state = .{ .pickup_animation_progress = 0 };
                return .picked_up_by_player;
            }
        },
        .pickup_animation_progress => |*progress| {
            progress.* += animation_speed;
            if (progress.* > 1) {
                self.state = .{ .disappeared = {} };
            }
        },
        .disappeared => return .disappeared,
    }
    return .none;
}

pub const TickContext = struct {
    main_character: *const GameCharacter,
    map: *const Map,
};

pub const Result = enum { none, picked_up_by_player, disappeared };

pub fn makeRenderSnapshot(self: Gem) RenderSnapshot {
    return .{
        .position = self.position,
        .current_state = self.state,
        .state_at_previous_tick = self.state_at_previous_tick,
    };
}

pub const RenderSnapshot = struct {
    position: math.FlatVector,
    current_state: State,
    state_at_previous_tick: State,

    pub fn makeBillboardData(
        self: RenderSnapshot,
        spritesheet: SpriteSheetTexture,
        interval_between_previous_and_current_tick: f32,
    ) SpriteData {
        const source = spritesheet.getSpriteTexcoords(.gem);
        const sprite_aspect_ratio = spritesheet.getSpriteAspectRatio(.gem);
        const state = self.interpolate(interval_between_previous_and_current_tick);
        var result = SpriteData{
            .position = .{
                .x = self.position.x,
                .y = width * sprite_aspect_ratio / 2,
                .z = self.position.z,
            },
            .size = .{ .w = width, .h = width * sprite_aspect_ratio },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
        };
        switch (state) {
            .spawn_animation_progress => |progress| {
                const jump_height = 1.5;
                const length = width * progress;
                const t = (progress - 0.5) * 2;
                const y = (1 - t * t + length / 2) * jump_height;
                result.position = .{
                    .x = self.position.x,
                    .y = y,
                    .z = self.position.z,
                };
            },
            .waiting => {},
            .pickup_animation_progress => |progress| {
                result.size.w *= 1 - progress;
                result.size.h *= 1 - progress;
            },
            .disappeared => {
                result.size.w = 0;
                result.size.h = 0;
            },
        }
        return result;
    }

    pub fn interpolate(self: RenderSnapshot, t: f32) State {
        return switch (self.state_at_previous_tick) {
            .spawn_animation_progress => |old| switch (self.current_state) {
                .spawn_animation_progress => |current| .{
                    .spawn_animation_progress = math.lerp(old, current, t),
                },
                .waiting => .{
                    .spawn_animation_progress = math.lerp(old, 1, t),
                },
                else => unreachable,
            },
            .waiting => switch (self.current_state) {
                .waiting => .{ .waiting = {} },
                .pickup_animation_progress => |current| .{
                    .pickup_animation_progress = math.lerp(0, current, t),
                },
                else => unreachable,
            },
            .pickup_animation_progress => |old| switch (self.current_state) {
                .pickup_animation_progress => |current| .{
                    .pickup_animation_progress = math.lerp(old, current, t),
                },
                .disappeared => .{
                    .pickup_animation_progress = math.lerp(old, 1, t),
                },
                else => unreachable,
            },
            .disappeared => .{ .disappeared = {} },
        };
    }
};

const State = union(enum) {
    /// Progresses from 0 to 1.
    spawn_animation_progress: f32,
    waiting: void,
    /// Progresses from 0 to 1.
    pickup_animation_progress: f32,
    disappeared: void,
};
