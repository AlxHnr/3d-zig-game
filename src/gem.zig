const ArrayList = @import("std").ArrayList;
const GameCharacter = @import("game_unit.zig").GameCharacter;
const Map = @import("map/map.zig").Map;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const animation = @import("animation.zig");
const fp = math.Fix32.fp;
const math = @import("math.zig");
const simulation = @import("simulation.zig");

position: math.FlatVector,
state: State,
state_at_previous_tick: State,

const Gem = @This();

pub const gem_jump_height = fp(1.5);
pub const gem_jump_duration_in_ticks = simulation.secondsToTicks(0.6).convertTo(math.Fix32);

pub fn create(position: math.FlatVector, originates_from: math.FlatVector) Gem {
    const state = .{ .spawning = .{ .tick_counter = 0, .source_position = originates_from } };
    return .{ .position = position, .state = state, .state_at_previous_tick = state };
}

pub fn processElapsedTick(self: *Gem, context: TickContext) Result {
    self.state_at_previous_tick = self.state;
    switch (self.state) {
        .spawning => |*spawning| {
            spawning.tick_counter += 1;
            if (fp(spawning.tick_counter).gte(gem_jump_duration_in_ticks)) {
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
                    .pickup = .{ .tick_counter = 0, .target_position = character_position },
                };
                return .picked_up_by_player;
            }
        },
        .pickup => |*pickup| {
            pickup.tick_counter += 1;
            pickup.target_position = context.main_character.moving_circle.getPosition();
            if (fp(pickup.tick_counter).gte(gem_jump_duration_in_ticks)) {
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

pub fn makeBillboardData(
    self: Gem,
    spritesheet: SpriteSheetTexture,
    animation_collection: animation.BillboardAnimationCollection,
    previous_tick: u32,
) SpriteData {
    const source = spritesheet.getSpriteSourceRectangle(.gem);
    const sprite_aspect_ratio = spritesheet.getSpriteAspectRatio(.gem);
    const height = fp(1.5);
    const half_height = fp(1.5).div(fp(2));
    return switch (self.state) {
        .spawning => |spawning| SpriteData.create(
            spawning.source_position.addY(half_height),
            source,
            height.div(sprite_aspect_ratio),
            height,
        ).withAnimationIndex(animation_collection.gem_spawn)
            .withAnimationStartTick(previous_tick + 1 - spawning.tick_counter)
            .withAnimationTargetPosition(self.position.addY(half_height)),
        .waiting => SpriteData.create(
            self.position.addY(half_height),
            source,
            height.div(sprite_aspect_ratio),
            height,
        ),
        .pickup => |pickup| SpriteData.create(
            self.position.addY(half_height),
            source,
            height.div(sprite_aspect_ratio),
            height,
        ).withAnimationIndex(animation_collection.gem_pickup)
            .withAnimationStartTick(previous_tick - pickup.tick_counter)
            .withAnimationTargetPosition(pickup.target_position.addY(half_height)),
        .disappeared => {
            return SpriteData.create(
                self.position.addY(half_height),
                spritesheet.getSpriteSourceRectangle(.gem),
                fp(0),
                fp(0),
            );
        },
    };
}

const State = union(enum) {
    spawning: struct {
        tick_counter: u8,
        source_position: math.FlatVector,
    },
    waiting: void,
    pickup: struct {
        tick_counter: u8,
        target_position: math.FlatVector,
    },
    disappeared: void,
};
