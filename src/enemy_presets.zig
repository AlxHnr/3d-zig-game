const Config = @import("enemy.zig").Config;
const kphToGameUnitsPerTick = @import("simulation.zig").kphToGameUnitsPerTick;

pub const floating_eye = Config{
    .name = "Floating Eye",
    .sprite = .yellow_floating_eye,
    .height = 2,
    .movement_speed = .{
        .idle = kphToGameUnitsPerTick(5),
        .attacking = kphToGameUnitsPerTick(20),
    },
    .max_health = 70,
    .aggro_radius = 20,
};
