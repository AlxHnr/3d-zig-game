//! Contains various test cases.

const std = @import("std");
const expect = std.testing.expect;
const expectApproxEqRel = std.testing.expectApproxEqRel;

const collision = @import("collision.zig");
const util = @import("util.zig");
const math = @import("math.zig");
const epsilon = math.epsilon;

test "Create collision rectangle" {
    const rectangle = collision.Rectangle.create(
        .{ .x = 12, .z = -3.1 },
        .{ .x = 6.16, .z = 27.945 },
        19.18,
    );
    const expected_angle = std.math.degreesToRadians(10.653624);
    try expectApproxEqRel(@floatCast(f32, 11.220045), rectangle.first_corner.x, epsilon);
    try expectApproxEqRel(@floatCast(f32, 26.3245), rectangle.first_corner.z, epsilon);
    try expectApproxEqRel(@floatCast(f32, 30.400045), rectangle.third_corner.x, epsilon);
    try expectApproxEqRel(@floatCast(f32, -5.265016), rectangle.third_corner.z, epsilon);
    try expectApproxEqRel(std.math.sin(expected_angle), rectangle.rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(expected_angle), rectangle.rotation.cosine, epsilon);
    try expectApproxEqRel(std.math.sin(-expected_angle), rectangle.inverse_rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(-expected_angle), rectangle.inverse_rotation.cosine, epsilon);
}

test "Collisions between lines" {
    try expect(collision.lineCollidesWithLine(
        .{ .x = -1, .z = -3 },
        .{ .x = 2.5, .z = -0.5 },
        .{ .x = 2, .z = -1.5 },
        .{ .x = 0.5, .z = 2 },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = 2.5, .z = -0.5 },
        .{ .x = -1, .z = -3 },
        .{ .x = 2, .z = -1.5 },
        .{ .x = 0.5, .z = 2 },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = 2.5, .z = -0.5 },
        .{ .x = -1, .z = -3 },
        .{ .x = 0.5, .z = 2 },
        .{ .x = 2, .z = -1.5 },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = -1, .z = -3 },
        .{ .x = 2.5, .z = -0.5 },
        .{ .x = 0.5, .z = 2 },
        .{ .x = 2, .z = -1.5 },
    ) != null);

    try expect(collision.lineCollidesWithLine(
        .{ .x = -1, .z = -3 },
        .{ .x = 2.5, .z = -0.5 },
        .{ .x = 0.5, .z = 2 },
        .{ .x = -2, .z = -1.5 },
    ) == null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = -1.5, .z = 7 },
        .{ .x = 1.5, .z = 7 },
        .{ .x = -2.5, .z = 8 },
        .{ .x = 2.5, .z = 8 },
    ) == null);
}

test "Matrix multiplication" {
    const matrix = math.Matrix{ .rows = .{
        .{ 12, 4, 7, 9 },
        .{ 77, 0, 2, 13 },
        .{ 23, 22, 32, 89 },
        .{ 1, 1, 43, 3 },
    } };
    const result = matrix.multiply(math.Matrix.identity);
    try expectApproxEqRel(@floatCast(f32, 12), result.rows[0][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 4), result.rows[0][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, 7), result.rows[0][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 9), result.rows[0][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, 77), result.rows[1][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0), result.rows[1][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, 2), result.rows[1][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 13), result.rows[1][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, 23), result.rows[2][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 22), result.rows[2][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, 32), result.rows[2][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 89), result.rows[2][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, 1), result.rows[3][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 1), result.rows[3][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, 43), result.rows[3][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 3), result.rows[3][3], epsilon);
}

test "Matrix inversion" {
    const matrix = math.Matrix{ .rows = .{
        .{ 12, 4, 7, 9 },
        .{ 77, 0, 2, 13 },
        .{ 23, 22, 32, 89 },
        .{ 1, 1, 43, 3 },
    } };
    const result = matrix.invert();
    try expectApproxEqRel(@floatCast(f32, 0.0199921560), result.rows[0][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0109564653), result.rows[0][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0035851123), result.rows[0][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0010961493), result.rows[0][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.4605939090), result.rows[1][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0603703409), result.rows[1][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0362349451), result.rows[1][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0452069417), result.rows[1][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0029465300), result.rows[2][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0003134250), result.rows[2][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.0005614833), result.rows[2][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0241387505), result.rows[2][3], epsilon);
    try expectApproxEqRel(@floatCast(f32, -0.1179617643), result.rows[3][0], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0119788675), result.rows[3][1], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0213212781), result.rows[3][2], epsilon);
    try expectApproxEqRel(@floatCast(f32, 0.0027789229), result.rows[3][3], epsilon);
}
