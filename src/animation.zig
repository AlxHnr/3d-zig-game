const SpriteAnimationCollection = @import("rendering.zig").SpriteAnimationCollection;
const fp = math.Fix32.fp;
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

    gem_jump: u8,

    pub fn create(allocator: std.mem.Allocator) !BillboardAnimationCollection {
        var collection = try allocator.create(SpriteAnimationCollection);
        errdefer allocator.destroy(collection);
        collection.* = try SpriteAnimationCollection.create(allocator, fp(1), &.{
            .{ .target_position_interval = fp(0) },
            .{ .target_position_interval = fp(1) },
        });
        errdefer collection.destroy();

        return .{
            .animation_collection = collection,
            .gem_jump = try collection.addAnimation(fp(1), &.{
                .{ .target_position_interval = fp(0) },
                .{ .target_position_interval = fp(1) },
            }),
        };
    }

    pub fn destroy(self: *BillboardAnimationCollection, allocator: std.mem.Allocator) void {
        self.animation_collection.destroy();
        allocator.destroy(self.animation_collection);
    }
};
