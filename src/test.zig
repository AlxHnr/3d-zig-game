//! Contains various test cases.

const collision = @import("collision.zig");
const std = @import("std");
const expectApproxEqRel = std.testing.expectApproxEqRel;
const util = @import("util.zig");
const epsilon = util.Constants.epsilon;

test "Create collision rectangle" {
    const rectangle = collision.Rectangle.create(
        util.FlatVector{ .x = 12, .z = -3.1 },
        util.FlatVector{ .x = 6.16, .z = 27.945 },
        19.18,
    );
    const expected_angle = util.degreesToRadians(10.653624);
    try expectApproxEqRel(@floatCast(f32, 11.220045), rectangle.bottom_left_corner.x, epsilon);
    try expectApproxEqRel(@floatCast(f32, 26.3245), rectangle.bottom_left_corner.z, epsilon);
    try expectApproxEqRel(@floatCast(f32, 19.18), rectangle.width, epsilon);
    try expectApproxEqRel(@floatCast(f32, 31.589516), rectangle.height, epsilon);
    try expectApproxEqRel(std.math.sin(expected_angle), rectangle.rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(expected_angle), rectangle.rotation.cosine, epsilon);
    try expectApproxEqRel(std.math.sin(-expected_angle), rectangle.inverse_rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(-expected_angle), rectangle.inverse_rotation.cosine, epsilon);
}
