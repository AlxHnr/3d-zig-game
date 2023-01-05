//! Contains various helpers that belong nowhere else.

const std = @import("std");
const math = std.math;
const rl = @import("raylib");
const rm = @import("raylib-math");
const rlgl = @cImport(@cInclude("rlgl.h"));

pub const Constants = struct {
    pub const up = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
    /// Smallest viable number for game-world calculations.
    pub const epsilon = 0.00001;
};

// TODO: Use std.math.degreesToRadians() after upgrade to zig 0.10.0.
pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * math.pi / 180;
}
pub fn radiansToDegrees(radians: f32) f32 {
    return radians * 180 / math.pi;
}

pub fn isEqualFloat(a: f32, b: f32) bool {
    return math.fabs(a - b) < Constants.epsilon;
}

/// Lap timer for measuring elapsed ticks.
pub const TickTimer = struct {
    timer: std.time.Timer,
    tick_duration: u64,
    leftover_time_from_last_tick: u64,

    /// Create a new tick timer for measuring the specified tick rate. The given value is assumed to
    /// be non-zero. Fails when no clock is available.
    pub fn start(ticks_per_second: u32) std.time.Timer.Error!TickTimer {
        std.debug.assert(ticks_per_second > 0);
        return TickTimer{
            .timer = try std.time.Timer.start(),
            .tick_duration = std.time.ns_per_s / ticks_per_second,
            .leftover_time_from_last_tick = 0,
        };
    }

    /// Return the amount of elapsed ticks since the last call of this function or since start().
    pub fn lap(self: *TickTimer) LapResult {
        const elapsed_time = self.timer.lap() + self.leftover_time_from_last_tick;
        self.leftover_time_from_last_tick = elapsed_time % self.tick_duration;
        return LapResult{
            .elapsed_ticks = elapsed_time / self.tick_duration,
            .next_tick_progress = @floatCast(f32, @intToFloat(
                f64,
                self.leftover_time_from_last_tick,
            ) / @intToFloat(f64, self.tick_duration)),
        };
    }

    pub const LapResult = struct {
        elapsed_ticks: u64,
        /// Value between 0 and 1 denoting how much percent of the next tick has already passed.
        /// This can be used for interpolating between two ticks.
        next_tick_progress: f32,
    };
};

pub fn getPreviousEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @intToEnum(@TypeOf(value), if (@enumToInt(value) == 0)
        @typeInfo(@TypeOf(value)).Enum.fields.len - 1
    else
        @enumToInt(value) - 1);
}

pub fn getNextEnumWrapAround(value: anytype) @TypeOf(value) {
    comptime {
        const argument_is_enum = switch (@typeInfo(@TypeOf(value))) {
            .Enum => true,
            else => false,
        };
        std.debug.assert(argument_is_enum);
    }
    return @intToEnum(
        @TypeOf(value),
        @mod(@intCast(usize, @enumToInt(value)) + 1, @typeInfo(@TypeOf(value)).Enum.fields.len),
    );
}

/// Wrapper around raylib.DrawMesh(), which takes a texture and shader.
pub fn drawMesh(
    mesh: rl.Mesh,
    transform_matrix: rl.Matrix,
    texture: rl.Texture,
    tint: rl.Color,
    shader: rl.Shader,
) void {
    var maps = std.mem.zeroes([rl.MAX_MATERIAL_MAPS]rl.MaterialMap);
    var material = std.mem.zeroes(rl.Material);
    material.maps = &maps;

    material.shader.id = shader.id;
    material.shader.locs = rlgl.rlGetShaderLocsDefault();
    material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].texture = texture;
    material.maps[@enumToInt(rl.MATERIAL_MAP_DIFFUSE)].color = tint;

    rl.DrawMesh(mesh, material, transform_matrix);
}

pub fn getCurrentRaylibVpMatrix() rl.Matrix {
    // Cast is necessary because rlgl.h was included per cImport.
    const view_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixModelview());
    const projection_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixProjection());
    const transform_matrix = @bitCast(rl.Matrix, rlgl.rlGetMatrixTransform());
    return rm.MatrixMultiply(rm.MatrixMultiply(transform_matrix, view_matrix), projection_matrix);
}

/// Contains informations about how to scale a piece of a texture onto a quad without breaking the
/// pieces aspect ratio.
pub const TextureQuadMapping = struct {
    /// Values ranging from 0 to 1, where (0, 0) is the top left corner of the texture.
    source_texcoords: rl.Rectangle,
    /// Factor by which the texture should be repeated along each axis to prevent stretching.
    repeat_dimensions: rl.Vector2,
};

pub fn scaleTextureToQuad(
    texture: rl.Texture,
    source_pixels: rl.Rectangle,
    target_quad_size: rl.Vector2,
    scale_factor: f32,
) TextureQuadMapping {
    const texture_width = @intToFloat(f32, texture.width);
    const texture_height = @intToFloat(f32, texture.height);
    const texcoords = .{
        .x = source_pixels.x / texture_width,
        .y = source_pixels.y / texture_height,
        .width = source_pixels.width / texture_width,
        .height = source_pixels.height / texture_height,
    };
    const aspect_ratio = source_pixels.height / source_pixels.width;
    const pixels_per_unit_of_length = 100;
    const repetitions = pixels_per_unit_of_length / source_pixels.width / scale_factor;
    return .{
        .source_texcoords = texcoords,
        .repeat_dimensions = .{
            .x = repetitions * target_quad_size.x,
            .y = repetitions * target_quad_size.y / aspect_ratio,
        },
    };
}
