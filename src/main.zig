const std = @import("std");

const rl = @import("raylib");

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.InitWindow(screenWidth, screenHeight, "3D Zig Game");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();

        rl.ClearBackground(rl.WHITE);

        rl.DrawText("Hello World", 190, 200, 20, rl.LIGHTGRAY);

        rl.EndDrawing();
    }
}
