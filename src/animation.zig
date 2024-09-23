const SpriteAnimationCollection = @import("rendering.zig").SpriteAnimationCollection;
const fp = math.Fix32.fp;
const gem_jump_duration_in_ticks = @import("gem.zig").gem_jump_duration_in_ticks;
const gem_jump_height = @import("gem.zig").gem_jump_height;
const math = @import("math.zig");
const std = @import("std");

/// For cycling between 3 frames in a loop like this: 0 -> 1 -> 2 -> 1 -> 0.
pub const FourStepCycle = struct {
    /// Moves from 0 to 1 and wraps around to 0,
    cycle: math.Fix32,
    step: u2,

    pub fn create() FourStepCycle {
        return .{ .cycle = fp(0), .step = 0 };
    }

    /// Takes a speed value >= 0 where 1 skips a full frame,
    pub fn processElapsedTick(self: *FourStepCycle, speed: math.Fix32) void {
        self.cycle = self.cycle.add(speed.max(fp(0)));
        if (self.cycle.gt(fp(1))) {
            self.cycle = fp(0);
            self.step = self.step +% 1;
        }
    }

    pub fn getFrame(self: FourStepCycle) u2 {
        return if (self.step == 3) 1 else self.step;
    }

    pub fn lerp(self: FourStepCycle, other: FourStepCycle, t: math.Fix32) FourStepCycle {
        return .{
            .cycle = self.cycle.lerp(other.cycle, t),
            .step = if (t.lt(fp(0.5))) self.step else other.step,
        };
    }
};

pub const BillboardAnimationCollection = struct {
    animation_collection: *SpriteAnimationCollection,

    gem_spawn: u8,
    gem_pickup: u8,

    pub fn create(allocator: std.mem.Allocator) !BillboardAnimationCollection {
        var collection = try allocator.create(SpriteAnimationCollection);
        errdefer allocator.destroy(collection);
        collection.* = try SpriteAnimationCollection.create(allocator, fp(1), &.{
            .{ .target_position_interval = fp(0) },
            .{ .target_position_interval = fp(1) },
        });
        errdefer collection.destroy();

        const gem_tick_duration = gem_jump_duration_in_ticks.div(fp(3));
        const gem_base = [_]SpriteAnimationCollection.Keyframe{
            .{
                .target_position_interval = fp(0.0),
                .position_offset = .{ .x = fp(0), .y = fp(0), .z = fp(0) },
            },
            .{
                .target_position_interval = fp(0.4),
                .position_offset = .{ .x = fp(0), .y = gem_jump_height, .z = fp(0) },
            },
            .{
                .target_position_interval = fp(0.6),
                .position_offset = .{ .x = fp(0), .y = gem_jump_height, .z = fp(0) },
            },
            .{
                .target_position_interval = fp(1.0),
                .position_offset = .{ .x = fp(0), .y = fp(0), .z = fp(0) },
            },
        };
        var gem_spawn = gem_base;
        gem_spawn[0].scaling_factor = fp(0);
        var gem_pickup = gem_base;
        gem_pickup[3].scaling_factor = fp(0);

        return .{
            .animation_collection = collection,
            .gem_spawn = try collection.addAnimation(gem_tick_duration, &gem_spawn),
            .gem_pickup = try collection.addAnimation(gem_tick_duration, &gem_pickup),
        };
    }

    pub fn destroy(self: *BillboardAnimationCollection, allocator: std.mem.Allocator) void {
        self.animation_collection.destroy();
        allocator.destroy(self.animation_collection);
    }
};
