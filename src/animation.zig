const std = @import("std");
const math = @import("math.zig");

/// For cycling between 3 frames in a loop like this: 0 -> 1 -> 2 -> 1 -> 0.
pub const FourStepCycle = struct {
    /// Moves from 0 to 1 and wraps around to 0,
    cycle: f32,
    step: u2,

    pub fn create() FourStepCycle {
        return .{ .cycle = 0, .step = 0 };
    }

    /// Takes a speed value >= 0 where 1 skips a full frame,
    pub fn processElapsedTick(self: *FourStepCycle, speed: f32) void {
        self.cycle = self.cycle + @max(0, speed);
        if (self.cycle > 1) {
            self.cycle = 0;
            self.step = self.step +% 1;
        }
    }

    pub fn getFrame(self: FourStepCycle) u2 {
        return if (self.step == 3) 1 else self.step;
    }

    pub fn lerp(self: FourStepCycle, other: FourStepCycle, t: f32) FourStepCycle {
        return .{
            .cycle = math.lerp(self.cycle, other.cycle, t),
            .step = if (t < 0.5) self.step else other.step,
        };
    }
};
