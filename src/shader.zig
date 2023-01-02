const Error = @import("error.zig").Error;
const glad = @cImport(@cInclude("external/glad.h"));
const std = @import("std");

pub const Shader = struct {
    program_id: c_uint,
    vertex_shader_id: c_uint,
    fragment_shader_id: c_uint,

    pub fn create(vertex_shader_source: [:0]const u8, fragment_shader_source: [:0]const u8) !Shader {
        const program_id = glad.glCreateProgram();
        if (program_id == 0) {
            return Error.FailedToCompileAndLinkShader;
        }
        errdefer glad.glDeleteProgram(program_id);

        // For allocating error message strings.
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        const vertex_shader_id = try compileShader(
            gpa.allocator(),
            glad.GL_VERTEX_SHADER,
            vertex_shader_source,
        );
        errdefer glad.glDeleteShader(vertex_shader_id);

        const fragment_shader_id = try compileShader(
            gpa.allocator(),
            glad.GL_FRAGMENT_SHADER,
            fragment_shader_source,
        );
        errdefer glad.glDeleteShader(vertex_shader_id);

        glad.glAttachShader(program_id, vertex_shader_id);
        glad.glAttachShader(program_id, fragment_shader_id);
        glad.glLinkProgram(program_id);

        var status: c_int = undefined;
        glad.glGetProgramiv(program_id, glad.GL_LINK_STATUS, &status);
        if (status != glad.GL_FALSE) {
            return Shader{
                .program_id = program_id,
                .vertex_shader_id = vertex_shader_id,
                .fragment_shader_id = fragment_shader_id,
            };
        }

        var buffer_length: c_int = undefined;
        glad.glGetProgramiv(program_id, glad.GL_INFO_LOG_LENGTH, &buffer_length);

        var buffer = try gpa.allocator().alloc(u8, @intCast(usize, buffer_length));
        defer gpa.allocator().free(buffer);

        var string_length: c_int = undefined;
        glad.glGetProgramInfoLog(program_id, buffer_length, &string_length, buffer.ptr);

        std.log.err("Failed to link shader: {s}\n", .{buffer[0..@intCast(usize, string_length)]});

        return Error.FailedToCompileAndLinkShader;
    }

    pub fn destroy(self: *Shader) void {
        glad.glDeleteShader(self.fragment_shader_id);
        glad.glDeleteShader(self.vertex_shader_id);
        glad.glDeleteProgram(self.program_id);
    }

    pub fn enable(self: Shader) void {
        glad.glUseProgram(self.program_id);
    }

    pub fn getAttributeLocation(self: Shader, attribute_name: [:0]const u8) Error!c_uint {
        const location = glad.glGetAttribLocation(self.program_id, attribute_name);
        if (location == -1) {
            std.log.err("Failed to retrieve location of attribute \"{s}\"\n", .{attribute_name});
            return Error.FailedToRetrieveShaderLocation;
        }
        return @intCast(c_uint, location);
    }

    pub fn getUniformLocation(self: Shader, uniform_name: [:0]const u8) Error!c_int {
        const location = glad.glGetUniformLocation(self.program_id, uniform_name);
        if (location == -1) {
            std.log.err("Failed to retrieve location of uniform \"{s}\"\n", .{uniform_name});
            return Error.FailedToRetrieveShaderLocation;
        }
        return location;
    }
};

fn compileShader(allocator: std.mem.Allocator, shader_type: c_uint, source: [*:0]const u8) !c_uint {
    const shader = glad.glCreateShader(shader_type);
    if (shader == 0) {
        return Error.FailedToCompileAndLinkShader;
    }
    errdefer glad.glDeleteShader(shader);
    glad.glShaderSource(shader, 1, &source, null);
    glad.glCompileShader(shader);

    var status: c_int = undefined;
    glad.glGetShaderiv(shader, glad.GL_COMPILE_STATUS, &status);
    if (status != glad.GL_FALSE) {
        return shader;
    }

    var buffer_length: c_int = undefined;
    glad.glGetShaderiv(shader, glad.GL_INFO_LOG_LENGTH, &buffer_length);

    var buffer = try allocator.alloc(u8, @intCast(usize, buffer_length));
    defer allocator.free(buffer);

    var string_length: c_int = undefined;
    glad.glGetShaderInfoLog(shader, @intCast(c_int, buffer.len), &string_length, buffer.ptr);

    std.log.err("Failed to compile shader: {s}\n", .{buffer[0..@intCast(usize, string_length)]});

    return Error.FailedToCompileAndLinkShader;
}
