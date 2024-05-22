const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const simulation = @import("simulation.zig");

position: math.FlatVectorF32,
state: State,
state_at_previous_tick: State,

const Gem = @This();
const height = 1.5;
const jump_height = 1.5;
const animation_speed = simulation.kphToGameUnitsPerTick(10).convertTo(f32);

pub fn create(position: math.FlatVectorF32, originates_from: math.FlatVectorF32) Gem {
    const state = .{ .spawning = .{ .progress = 0, .source_position = originates_from } };
    return .{ .position = position, .state = state, .state_at_previous_tick = state };
}

pub fn processElapsedTick(self: *Gem, context: TickContext) Result {
    self.state_at_previous_tick = self.state;
    switch (self.state) {
        .spawning => |*spawning| {
            spawning.progress += animation_speed;
            if (spawning.progress > 1) {
                self.state = .{ .waiting = {} };
            }
        },
        .waiting => blk: {
            const boundaries = .{ .position = self.position.toFlatVector(), .radius = fp(10) };
            const character_position = context.main_character.moving_circle.hasCollidedWithCircle(
                boundaries,
            ) orelse break :blk;
            if (!context.map.geometry.isSolidWallBetweenPoints(self.position.toFlatVector(), character_position)) {
                self.state = .{
                    .pickup = .{ .progress = 0, .target_position = character_position.toFlatVectorF32() },
                };
                return .picked_up_by_player;
            }
        },
        .pickup => |*pickup| {
            pickup.progress += animation_speed;
            if (pickup.progress > 1) {
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
    position: math.FlatVectorF32,
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
                .y = height / 2.0,
                .z = self.position.z,
            },
            .size = .{ .w = height / sprite_aspect_ratio, .h = height },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
        };
        switch (state) {
            .spawning => |spawning| interpolateJumpAnimation(
                &result,
                spawning.source_position,
                self.position,
                spawning.progress,
                false,
            ),
            .waiting => {},
            .pickup => |pickup| interpolateJumpAnimation(
                &result,
                self.position,
                pickup.target_position,
                pickup.progress,
                true,
            ),
            .disappeared => {
                result.size.w = 0;
                result.size.h = 0;
            },
        }
        return result;
    }

    fn interpolate(self: RenderSnapshot, t: f32) State {
        return switch (self.state_at_previous_tick) {
            .spawning => |old| switch (self.current_state) {
                .spawning => |current| .{
                    .spawning = .{
                        .progress = math.lerp(old.progress, current.progress, t),
                        .source_position = old.source_position,
                    },
                },
                .waiting => .{
                    .spawning = .{
                        .progress = math.lerp(old.progress, 1, t),
                        .source_position = old.source_position,
                    },
                },
                else => unreachable,
            },
            .waiting => switch (self.current_state) {
                .waiting => .{ .waiting = {} },
                .pickup => |current| .{
                    .pickup = .{
                        .progress = math.lerp(0, current.progress, t),
                        .target_position = current.target_position,
                    },
                },
                else => unreachable,
            },
            .pickup => |old| switch (self.current_state) {
                .pickup => |current| .{
                    .pickup = .{
                        .progress = math.lerp(old.progress, current.progress, t),
                        .target_position = old.target_position,
                    },
                },
                .disappeared => .{
                    .pickup = .{
                        .progress = math.lerp(old.progress, 1, t),
                        .target_position = old.target_position,
                    },
                },
                else => unreachable,
            },
            .disappeared => .{ .disappeared = {} },
        };
    }

    fn interpolateJumpAnimation(
        to_update: *SpriteData,
        start_position: math.FlatVectorF32,
        end_position: math.FlatVectorF32,
        progress: f32,
        invert_scale: bool,
    ) void {
        const scale = if (invert_scale) 1 - progress else progress;
        const t = (progress - 0.5) * 2;
        to_update.size.w *= scale;
        to_update.size.h *= scale;
        to_update.position = .{
            .x = math.lerp(start_position.x, end_position.x, progress),
            .y = to_update.position.y + (1 - t * t) * jump_height,
            .z = math.lerp(start_position.z, end_position.z, progress),
        };
    }
};

const State = union(enum) {
    spawning: struct {
        /// Progresses from 0 to 1.
        progress: f32,
        source_position: math.FlatVectorF32,
    },
    waiting: void,
    pickup: struct {
        /// Progresses from 0 to 1.
        progress: f32,
        target_position: math.FlatVectorF32,
    },
    disappeared: void,
};
