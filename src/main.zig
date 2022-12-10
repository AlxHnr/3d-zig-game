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

    var camera = std.mem.zeroes(rl.Camera);
    camera.position = rl.Vector3{ .x = 5.0, .y = 5.0, .z = 5.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;
    rl.SetCameraMode(camera, rl.CameraMode.CAMERA_THIRD_PERSON);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.WHITE);

        rl.BeginMode3D(camera);
        rl.DrawCube(rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 }, 2.0, 2.0, 2.0, rl.BLUE);
        rl.DrawGrid(20, 1.0);
        rl.EndMode3D();

        drawFpsCounter();
        rl.EndDrawing();
    }
}
