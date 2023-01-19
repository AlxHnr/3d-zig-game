const Error = @import("error.zig").Error;
const gl = @import("gl");
const std = @import("std");

pub const Shader = struct {
    program_id: c_uint,
    vertex_shader_id: c_uint,
    fragment_shader_id: c_uint,

    pub fn create(vertex_shader_source: [:0]const u8, fragment_shader_source: [:0]const u8) !Shader {
        const program_id = gl.createProgram();
        if (program_id == 0) {
            return Error.FailedToCompileAndLinkShader;
        }
        errdefer gl.deleteProgram(program_id);

        // For allocating error message strings.
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        const vertex_shader_id = try compileShader(
            gpa.allocator(),
            gl.VERTEX_SHADER,
            vertex_shader_source,
        );
        errdefer gl.deleteShader(vertex_shader_id);

        const fragment_shader_id = try compileShader(
            gpa.allocator(),
            gl.FRAGMENT_SHADER,
            fragment_shader_source,
        );
        errdefer gl.deleteShader(vertex_shader_id);

        gl.attachShader(program_id, vertex_shader_id);
        gl.attachShader(program_id, fragment_shader_id);
        gl.linkProgram(program_id);

        var status: c_int = undefined;
        gl.getProgramiv(program_id, gl.LINK_STATUS, &status);
        if (status != gl.FALSE) {
            return Shader{
                .program_id = program_id,
                .vertex_shader_id = vertex_shader_id,
                .fragment_shader_id = fragment_shader_id,
            };
        }

        var buffer_length: c_int = undefined;
        gl.getProgramiv(program_id, gl.INFO_LOG_LENGTH, &buffer_length);

        var buffer = try gpa.allocator().alloc(u8, @intCast(usize, buffer_length));
        defer gpa.allocator().free(buffer);

        var string_length: c_int = undefined;
        gl.getProgramInfoLog(program_id, buffer_length, &string_length, buffer.ptr);

        std.log.err("failed to link shader: {s}\n", .{buffer[0..@intCast(usize, string_length)]});

        return Error.FailedToCompileAndLinkShader;
    }

    pub fn destroy(self: *Shader) void {
        gl.deleteShader(self.fragment_shader_id);
        gl.deleteShader(self.vertex_shader_id);
        gl.deleteProgram(self.program_id);
    }

    pub fn enable(self: Shader) void {
        gl.useProgram(self.program_id);
    }

    pub fn getAttributeLocation(self: Shader, attribute_name: [:0]const u8) Error!c_uint {
        const location = gl.getAttribLocation(self.program_id, attribute_name);
        if (location == -1) {
            std.log.err("failed to retrieve location of attribute \"{s}\"\n", .{attribute_name});
            return Error.FailedToRetrieveShaderLocation;
        }
        return @intCast(c_uint, location);
    }

    pub fn getUniformLocation(self: Shader, uniform_name: [:0]const u8) Error!c_int {
        const location = gl.getUniformLocation(self.program_id, uniform_name);
        if (location == -1) {
            std.log.err("failed to retrieve location of uniform \"{s}\"\n", .{uniform_name});
            return Error.FailedToRetrieveShaderLocation;
        }
        return location;
    }
};

fn compileShader(allocator: std.mem.Allocator, shader_type: c_uint, source: [*:0]const u8) !c_uint {
    const shader = gl.createShader(shader_type);
    if (shader == 0) {
        return Error.FailedToCompileAndLinkShader;
    }
    errdefer gl.deleteShader(shader);
    gl.shaderSource(shader, 1, &source, null);
    gl.compileShader(shader);

    var status: c_int = undefined;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &status);
    if (status != gl.FALSE) {
        return shader;
    }

    var buffer_length: c_int = undefined;
    gl.getShaderiv(shader, gl.INFO_LOG_LENGTH, &buffer_length);

    var buffer = try allocator.alloc(u8, @intCast(usize, buffer_length));
    defer allocator.free(buffer);

    var string_length: c_int = undefined;
    gl.getShaderInfoLog(shader, @intCast(c_int, buffer.len), &string_length, buffer.ptr);

    std.log.err("failed to compile shader: {s}\n", .{buffer[0..@intCast(usize, string_length)]});

    return Error.FailedToCompileAndLinkShader;
}
