const Config = @import("enemy.zig").Enemy.Configuration;

pub const floating_eye = Config{
    .name = "Floating Eye",
    .sprite = .yellow_floating_eye,
    .height = 2,
    .movement_speed = 0.1,
    .max_health = 70,
    .aggro_radius = 20,
};
