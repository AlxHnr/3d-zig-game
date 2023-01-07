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

    /// Takes an interval from 0 to 1, where 1 means skipping to the next frame.
    pub fn processStep(self: *FourStepCycle, interval: f32) void {
        self.cycle = self.cycle + std.math.max(0, interval);
        if (self.cycle > 1) {
            self.cycle = 0;
            self.step = self.step +% 1;
        }
    }

    pub fn getFrame(self: FourStepCycle) u2 {
        return if (self.step == 3) 1 else self.step;
    }

    pub fn lerp(self: FourStepCycle, other: FourStepCycle, interval: f32) FourStepCycle {
        return .{
            .cycle = math.lerp(self.cycle, other.cycle, interval),
            .step = if (interval < 0.5) self.step else other.step,
        };
    }
};
