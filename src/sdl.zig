pub usingnamespace @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_image.h");
});

pub fn makeGLContextCurrent(window: ?*Self.SDL_Window, gl_context: Self.SDL_GLContext) Error!void {
    if (Self.SDL_GL_MakeCurrent(window, gl_context) != 0) {
        logError("failed to set current OpenGL context: {s}", .{Self.SDL_GetError()});
        return Error.FailedToInitializeSDL2Window;
    }
}

const Self = @This();
const Error = @import("error.zig").Error;
const logError = @import("std").log.err;
