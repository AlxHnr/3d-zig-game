const edit_mode = @import("edit_mode.zig");
const Error = @import("error.zig").Error;
const std = @import("std");
const gl = @import("gl");
const math = @import("math.zig");
const sdl = @import("sdl.zig");
const GameContext = @import("game_context.zig").Context;

const ProgramContext = struct {
    screen_width: u16,
    screen_height: u16,
    window: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,
    allocator: std.mem.Allocator,
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
        );
        if (window == null) {
            std.log.err("failed to create SDL2 window: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        }
        errdefer sdl.SDL_DestroyWindow(window);

        const gl_context = sdl.SDL_GL_CreateContext(window);
        if (gl_context == null) {
            std.log.err("failed to create OpenGL 3.3 context: {s}", .{sdl.SDL_GetError()});
            return Error.FailedToInitializeSDL2Window;
        }
        errdefer sdl.SDL_GL_DeleteContext(gl_context);

        if (sdl.SDL_GL_MakeCurrent(window, gl_context) != 0) {
            std.log.err("failed to set current OpenGL context: {s}", .{
                sdl.SDL_GetError(),
            });
            return Error.FailedToInitializeSDL2Window;
        }
        try gl.load(gl_context, getProcAddress);

        gl.enable(gl.CULL_FACE);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.enable(gl.STENCIL_TEST);
        gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);

        return .{
            .screen_width = screen_width,
            .screen_height = screen_height,
            .window = window.?,
            .gl_context = gl_context,
            .allocator = allocator,
            .game_context = try GameContext.create(allocator, default_map_path),
            .edit_mode_state = edit_mode.State.create(),
            .edit_mode_view = .from_behind,
        };
    }

    fn destroy(self: *ProgramContext) void {
        self.game_context.destroy(self.allocator);
        sdl.SDL_GL_DeleteContext(self.gl_context);
        sdl.SDL_DestroyWindow(self.window);
    }

    fn run(self: *ProgramContext) !void {
        while (true) {
            const keep_running = try self.processInputs();
            if (!keep_running) {
                break;
            }
            self.processTicks();
            try self.render();
        }
    }

    /// Returns true if the program should keep running.
    fn processInputs(self: *ProgramContext) !bool {
        self.game_context.processKeyboardState(sdl.SDL_GetKeyboardState(null));

        const mouse_position = self.getMousePosition();
        const ray = self.game_context.castRay(
            mouse_position.x,
            mouse_position.y,
            self.screen_width,
            self.screen_height,
        );
        self.edit_mode_state.updateCurrentActionTarget(
            self.game_context.getMutableLevelGeometry(),
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
                self.screen_width = @intCast(u16, event.window.data1);
                self.screen_height = @intCast(u16, event.window.data2);
                gl.viewport(0, 0, event.window.data1, event.window.data2);
            } else if (event.type == sdl.SDL_MOUSEBUTTONDOWN) {
                if (event.button.button == sdl.SDL_BUTTON_LEFT) {
                    try self.edit_mode_state.handleActionAtTarget(
                        self.game_context.getMutableLevelGeometry(),
                        ray,
                    );
                } else if (event.button.button == sdl.SDL_BUTTON_MIDDLE) {
                    self.edit_mode_state.cycleInsertedObjectType(
                        self.game_context.getMutableLevelGeometry(),
                    );
                }
            } else if (event.type == sdl.SDL_MOUSEWHEEL) {
                if (sdl.SDL_GetMouseState(null, null) & sdl.SDL_BUTTON_RMASK == 0) {
                    self.game_context.increaseCameraDistance(event.wheel.preciseY * -2.5);
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
                            self.game_context.setCameraAngleFromGround(math.degreesToRadians(90));
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
                    self.edit_mode_state.cycleMode(self.game_context.getMutableLevelGeometry());
                }
            }
        }
        return true;
    }

    fn processTicks(self: *ProgramContext) void {
        self.game_context.processTicks();
    }

    fn render(self: *ProgramContext) !void {
        gl.clearColor(140.0 / 255.0, 190.0 / 255.0, 214.0 / 255.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
        gl.enable(gl.DEPTH_TEST);

        try self.game_context.render(self.allocator, self.screen_width, self.screen_height);

        gl.disable(gl.DEPTH_TEST);
        sdl.SDL_GL_SwapWindow(self.window);
    }

    const Position = struct { x: u16, y: u16 };
    fn getMousePosition(self: ProgramContext) Position {
        var mouse_x: c_int = undefined;
        var mouse_y: c_int = undefined;
        _ = sdl.SDL_GetMouseState(&mouse_x, &mouse_y);
        return .{
            .x = @intCast(u16, std.math.clamp(mouse_x, 0, self.screen_width)),
            .y = @intCast(u16, std.math.clamp(mouse_y, 0, self.screen_height)),
        };
    }

    fn getProcAddress(_: sdl.SDL_GLContext, extension_name: [:0]const u8) ?gl.FunctionPointer {
        // Usually a check with SDL_GL_ExtensionSupported() is required, but gl.zig only provides the
        // function name instead of the full extension string.
        return sdl.SDL_GL_GetProcAddress(extension_name);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var program_context = try ProgramContext.create(gpa.allocator(), 1600, 900);
    defer program_context.destroy();
    return program_context.run();
}
