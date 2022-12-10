const std = @import("std");

const rl = @import("raylib");

fn drawFpsCounter() void {
    var string_buffer: [16]u8 = undefined;
    if (std.fmt.bufPrintZ(string_buffer[0..], "FPS: {}", .{rl.GetFPS()})) |slice| {
        rl.DrawText(slice, 5, 5, 20, rl.BLACK);
    } else |_| {
        unreachable;
    }
}

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.InitWindow(screenWidth, screenHeight, "3D Zig Game");
    defer rl.CloseWindow();

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();

        rl.ClearBackground(rl.WHITE);

        drawFpsCounter();
        rl.EndDrawing();
    }
}
