const Config = @import("enemy.zig").Configuration;
const kphToGameUnitsPerTick = @import("simulation.zig").kphToGameUnitsPerTick;

pub const floating_eye = Config{
    .name = "Floating Eye",
    .sprite = .yellow_floating_eye,
    .height = 2,
    .movement_speed = kphToGameUnitsPerTick(20),
    .max_health = 70,
    .aggro_radius = 20,
};
