const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const simulation = @import("simulation.zig");

position: math.FlatVector,
state: State,
state_at_previous_tick: State,

const Gem = @This();
const movement_speed = simulation.kphToGameUnitsPerTick(10);

pub fn create(position: math.FlatVector, originates_from: math.FlatVector) Gem {
    const state = .{ .spawning = .{ .progress = fp(0), .source_position = originates_from } };
    return .{ .position = position, .state = state, .state_at_previous_tick = state };
}

pub fn processElapsedTick(self: *Gem, context: TickContext) Result {
    self.state_at_previous_tick = self.state;
    switch (self.state) {
        .spawning => |*spawning| {
            spawning.progress = spawning.progress.add(movement_speed);
            if (spawning.progress.gt(fp(1))) {
                self.state = .{ .waiting = {} };
            }
        },
        .waiting => blk: {
            const boundaries = .{ .position = self.position, .radius = fp(10) };
            const character_position = context.main_character.moving_circle.hasCollidedWithCircle(
                boundaries,
            ) orelse break :blk;
            if (!context.map.geometry.isSolidWallBetweenPoints(self.position, character_position)) {
                self.state = .{
                    .pickup = .{ .progress = fp(0), .target_position = character_position },
                };
                return .picked_up_by_player;
            }
        },
        .pickup => |*pickup| {
            pickup.progress = pickup.progress.add(movement_speed);
            if (pickup.progress.gt(fp(1))) {
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
        interval_between_previous_and_current_tick: math.Fix32,
    ) SpriteData {
        const source = spritesheet.getSpriteTexcoords(.gem);
        const sprite_aspect_ratio = spritesheet.getSpriteAspectRatio(.gem).convertTo(f32);
        const state = self.interpolate(interval_between_previous_and_current_tick);
        const height = 1.5;
        var result = SpriteData{
            .position = .{
                .x = self.position.x.convertTo(f32),
                .y = height / 2.0,
                .z = self.position.z.convertTo(f32),
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

    fn interpolate(self: RenderSnapshot, t: math.Fix32) State {
        return switch (self.state_at_previous_tick) {
            .spawning => |old| switch (self.current_state) {
                .spawning => |current| .{
                    .spawning = .{
                        .progress = old.progress.lerp(current.progress, t),
                        .source_position = old.source_position,
                    },
                },
                .waiting => .{
                    .spawning = .{
                        .progress = old.progress.lerp(fp(1), t),
                        .source_position = old.source_position,
                    },
                },
                else => unreachable,
            },
            .waiting => switch (self.current_state) {
                .waiting => .{ .waiting = {} },
                .pickup => |current| .{
                    .pickup = .{
                        .progress = fp(0).lerp(current.progress, t),
                        .target_position = current.target_position,
                    },
                },
                else => unreachable,
            },
            .pickup => |old| switch (self.current_state) {
                .pickup => |current| .{
                    .pickup = .{
                        .progress = old.progress.lerp(current.progress, t),
                        .target_position = old.target_position,
                    },
                },
                .disappeared => .{
                    .pickup = .{
                        .progress = old.progress.lerp(fp(1), t),
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
        start_position: math.FlatVector,
        end_position: math.FlatVector,
        progress: math.Fix32,
        invert_scale: bool,
    ) void {
        const progressf32 = progress.convertTo(f32);
        const scale = if (invert_scale) 1 - progressf32 else progressf32;
        const t = (progressf32 - 0.5) * 2;
        const jump_height = 1.5;
        to_update.size.w *= scale;
        to_update.size.h *= scale;
        to_update.position = .{
            .x = start_position.x.lerp(end_position.x, progress).convertTo(f32),
            .y = to_update.position.y + (1 - t * t) * jump_height,
            .z = start_position.z.lerp(end_position.z, progress).convertTo(f32),
        };
    }
};

const State = union(enum) {
    spawning: struct {
        /// Progresses from 0 to 1.
        progress: math.Fix32,
        source_position: math.FlatVector,
    },
    waiting: void,
    pickup: struct {
        /// Progresses from 0 to 1.
        progress: math.Fix32,
        target_position: math.FlatVector,
    },
    disappeared: void,
};
