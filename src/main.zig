const DialogController = @import("dialog.zig").Controller;
const Error = @import("error.zig").Error;
const GameContext = @import("game_context.zig").Context;
const InputButton = @import("game_unit.zig").InputButton;
const PerformanceMeasurements = @import("performance_measurements.zig").Measurements;
const RenderLoop = @import("render_loop.zig");
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const edit_mode = @import("edit_mode.zig");
const fp = math.Fix32.fp;
const gl = @import("gl");
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const sdl = @import("sdl.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const util = @import("util.zig");

const ProgramContext = struct {
    screen_dimensions: util.ScreenDimensions,
    window: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,
    allocator: std.mem.Allocator,
    render_loop: *RenderLoop,
    render_thread: std.Thread,
    dialog_controller: *DialogController,
    game_context: GameContext,
    edit_mode_state: edit_mode.State,
    edit_mode_view: enum { from_behind, top_down },

    const default_map_path = "maps/default.json";

    /// Returned context will keep a reference to the given allocator for its entire lifetime.
    fn create(allocator: std.mem.Allocator, screen_width: u16, screen_height: u16) !ProgramContext {
        if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) {
            std.log.err("failed to initialize SDL2: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        }
        errdefer sdl.SDL_Quit();

        if (sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 3) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_RED_SIZE, 8) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_GREEN_SIZE, 8) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_BLUE_SIZE, 8) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ALPHA_SIZE, 8) != 0 or
            sdl.SDL_GL_SetAttribute(sdl.SDL_GL_STENCIL_SIZE, 8) != 0)
        {
            std.log.err("failed to set OpenGL attributes: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        }
        const window = sdl.SDL_CreateWindow(
            "3D Zig Game",
            sdl.SDL_WINDOWPOS_UNDEFINED,
            sdl.SDL_WINDOWPOS_UNDEFINED,
            screen_width,
            screen_height,
            sdl.SDL_WINDOW_OPENGL,
        ) orelse {
            std.log.err("failed to create SDL2 window: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        };
        errdefer sdl.SDL_DestroyWindow(window);

        const gl_context = sdl.SDL_GL_CreateContext(window);
        if (gl_context == null) {
            std.log.err("failed to create OpenGL 3.3 context: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        }
        errdefer sdl.SDL_GL_DeleteContext(gl_context);

        try sdl.makeGLContextCurrent(window, gl_context);
        try gl.load(gl_context, getProcAddress);

        gl.enable(gl.CULL_FACE);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.enable(gl.STENCIL_TEST);
        gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);

        const screen_dimensions = .{ .width = screen_width, .height = screen_height };
        const edit_mode_state = edit_mode.State.create();

        var dialog_controller = try allocator.create(DialogController);
        errdefer allocator.destroy(dialog_controller);
        dialog_controller.* = try DialogController.create(allocator);
        errdefer dialog_controller.destroy();

        var render_loop = try allocator.create(RenderLoop);
        errdefer allocator.destroy(render_loop);
        render_loop.* = RenderLoop.create(allocator, screen_dimensions, edit_mode_state);
        errdefer render_loop.destroy();

        var game_context = try GameContext.create(
            allocator,
            default_map_path,
            render_loop,
            dialog_controller,
        );
        errdefer game_context.destroy(allocator);

        try sdl.makeGLContextCurrent(null, null);
        var render_thread = try std.Thread.spawn(
            .{},
            renderThread,
            .{ render_loop, window, gl_context, dialog_controller },
        );
        errdefer render_thread.join();
        errdefer render_loop.sendStop();

        return .{
            .screen_dimensions = screen_dimensions,
            .window = window,
            .gl_context = gl_context,
            .allocator = allocator,
            .render_loop = render_loop,
            .render_thread = render_thread,
            .dialog_controller = dialog_controller,
            .game_context = game_context,
            .edit_mode_state = edit_mode_state,
            .edit_mode_view = .from_behind,
        };
    }

    fn destroy(self: *ProgramContext) void {
        self.render_loop.sendStop();
        self.render_thread.join();
        self.render_loop.destroy();
        self.allocator.destroy(self.render_loop);
        self.dialog_controller.destroy();
        self.allocator.destroy(self.dialog_controller);
        self.game_context.destroy(self.allocator);
        sdl.SDL_GL_DeleteContext(self.gl_context);
        sdl.SDL_DestroyWindow(self.window);
    }

    fn run(self: *ProgramContext) !void {
        var tick_counter: u32 = 0;
        var tick_timer = try simulation.TickTimer.start(simulation.tickrate);
        var performance_measurements = try PerformanceMeasurements.create();

        main_loop: while (true) {
            const lap_result = tick_timer.lap();
            if (lap_result.elapsed_ticks == 0) {
                std.time.sleep(lap_result.time_until_next_tick);
                continue;
            }

            const tick_upper_limit = 4; // Prevent `elapsed_ticks` from over-accumulating.
            for (0..@min(lap_result.elapsed_ticks, tick_upper_limit)) |_| {
                {
                    performance_measurements.begin(.tick_total);
                    defer performance_measurements.end(.tick_total);

                    if (!try self.processInputs()) {
                        break :main_loop;
                    }
                    try self.game_context.handleElapsedTick(&performance_measurements);
                }

                tick_counter += 1;
                if (@mod(tick_counter, simulation.tickrate * 3) == 0) {
                    performance_measurements.updateAverageAndReset();
                    performance_measurements.printTickInfo();
                }
            }
        }
    }

    /// Returns true if the program should keep running.
    fn processInputs(self: *ProgramContext) !bool {
        const mouse_position = self.getMousePosition();
        const ray = self.game_context.castRay(
            mouse_position.x,
            mouse_position.y,
            self.screen_dimensions,
        );
        try self.edit_mode_state.updateCurrentActionTarget(
            self.game_context.getMutableMap(),
            ray,
            self.game_context.getCameraDirection().toFlatVector(),
        );

        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) == 1) {
            if (event.type == sdl.SDL_QUIT) {
                return false;
            }

            if (event.type == sdl.SDL_WINDOWEVENT and
                event.window.event == sdl.SDL_WINDOWEVENT_RESIZED)
            {
                self.screen_dimensions = .{
                    .width = @intCast(event.window.data1),
                    .height = @intCast(event.window.data2),
                };
            } else if (event.type == sdl.SDL_MOUSEBUTTONDOWN) {
                if (event.button.button == sdl.SDL_BUTTON_LEFT) {
                    try self.edit_mode_state.handleActionAtTarget(
                        self.game_context.getMutableObjectIdGenerator(),
                        self.game_context.getMutableMap(),
                        ray,
                        self.game_context.spritesheet,
                    );
                } else if (event.button.button == sdl.SDL_BUTTON_MIDDLE) {
                    try self.edit_mode_state.cycleInsertedObjectType(
                        self.game_context.getMutableMap(),
                    );
                }
            } else if (event.type == sdl.SDL_MOUSEWHEEL) {
                if (sdl.SDL_GetMouseState(null, null) & sdl.SDL_BUTTON_RMASK == 0) {
                    self.game_context.increaseCameraDistance(fp(event.wheel.preciseY * -2.5));
                } else if (event.wheel.preciseY < 0) {
                    self.edit_mode_state.cycleInsertedObjectSubtypeForwards();
                } else {
                    self.edit_mode_state.cycleInsertedObjectSubtypeBackwards();
                }
            } else if (event.type == sdl.SDL_KEYDOWN) {
                if (event.key.keysym.sym == sdl.SDLK_t) {
                    switch (self.edit_mode_view) {
                        .from_behind => {
                            self.edit_mode_view = .top_down;
                            self.game_context.setCameraAngleFromGround(fp(90).toRadians());
                        },
                        .top_down => {
                            self.edit_mode_view = .from_behind;
                            self.game_context.resetCameraAngleFromGround();
                        },
                    }
                } else if (event.key.keysym.sym == sdl.SDLK_F2) {
                    try self.game_context.writeMapToDisk(self.allocator);
                } else if (event.key.keysym.sym == sdl.SDLK_F5) {
                    try self.game_context.reloadMapFromDisk(self.allocator);
                } else if (event.key.keysym.sym == sdl.SDLK_DELETE) {
                    try self.edit_mode_state.cycleMode(self.game_context.getMutableMap());
                } else if (keyToInputButton(event.key.keysym.sym)) |keycode| {
                    self.game_context.markButtonAsPressed(keycode);
                }
            } else if (event.type == sdl.SDL_KEYUP) {
                if (keyToInputButton(event.key.keysym.sym)) |keycode| {
                    self.game_context.markButtonAsReleased(keycode);
                }
            }
        }
        self.render_loop.sendExtraData(
            self.screen_dimensions,
            self.edit_mode_state,
            self.game_context.playerIsOnFlowFieldObstacleTile(),
        );

        return true;
    }

    pub fn keyToInputButton(keycode: sdl.SDL_Keycode) ?InputButton {
        return switch (keycode) {
            sdl.SDLK_UP => .forwards,
            sdl.SDLK_DOWN => .backwards,
            sdl.SDLK_LEFT => .left,
            sdl.SDLK_RIGHT => .right,
            sdl.SDLK_LALT => .strafe,
            sdl.SDLK_RCTRL => .slow_turning,
            sdl.SDLK_SPACE => .confirm,
            sdl.SDLK_ESCAPE => .cancel,
            else => null,
        };
    }

    const Position = struct { x: u16, y: u16 };
    fn getMousePosition(self: ProgramContext) Position {
        var mouse_x: c_int = undefined;
        var mouse_y: c_int = undefined;
        _ = sdl.SDL_GetMouseState(&mouse_x, &mouse_y);
        return .{
            .x = @intCast(std.math.clamp(mouse_x, 0, self.screen_dimensions.width)),
            .y = @intCast(std.math.clamp(mouse_y, 0, self.screen_dimensions.height)),
        };
    }

    fn getProcAddress(_: sdl.SDL_GLContext, extension_name: [:0]const u8) ?gl.FunctionPointer {
        // Usually a check with SDL_GL_ExtensionSupported() is required, but gl.zig only provides the
        // function name instead of the full extension string.
        return sdl.SDL_GL_GetProcAddress(extension_name);
    }

    fn renderThread(
        loop: *RenderLoop,
        window: *sdl.SDL_Window,
        gl_context: sdl.SDL_GLContext,
        dialog_controller: *DialogController,
    ) void {
        loop.run(window, gl_context, dialog_controller) catch |err| {
            std.log.err("thread failed: {}", .{err});
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var program_context = try ProgramContext.create(gpa.allocator(), 1600, 900);
    defer program_context.destroy();
    return program_context.run();
}
