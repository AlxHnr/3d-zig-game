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

// The characters position on the map is stored as 2d coordinates. Jumping or climbing is not needed.
const Character = struct {
    position: rl.Vector2,
    direction: rl.Vector2,

    const character_dimensions = rl.Vector3{ .x = 0.4, .y = 1.8, .z = 0.2 };

    fn to3dCoordinates(self: Character) rl.Vector3 {
        return rl.Vector3{
            .x = self.position.x,
            .y = character_dimensions.y / 2.0,
            .z = self.position.y,
        };
    }

    fn draw(self: Character) void {
        const body_color = rl.Color{ .r = 142.0, .g = 223.0, .b = 255.0, .a = 100.0 };
        const frame_color = rl.Color{ .r = 0.0, .g = 48.0, .b = 143.0, .a = 255.0 };
        const render_position = self.to3dCoordinates();
        rl.DrawCubeV(render_position, character_dimensions, body_color);
        rl.DrawCubeWiresV(render_position, character_dimensions, frame_color);
    }
};

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.InitWindow(screenWidth, screenHeight, "3D Zig Game");
    defer rl.CloseWindow();

    var camera = std.mem.zeroes(rl.Camera);
    camera.position = rl.Vector3{ .x = 5.0, .y = 5.0, .z = 5.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = 0.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

    var character = Character{
        .position = rl.Vector2{ .x = 0.0, .y = 0.0 },
        .direction = rl.Vector2{ .x = 0.0, .y = 1.0 },
    };

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.WHITE);

        rl.BeginMode3D(camera);
        character.draw();
        rl.DrawGrid(20, 1.0);
        rl.EndMode3D();

        drawFpsCounter();
        rl.EndDrawing();
    }
}
