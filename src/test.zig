//! Contains various test cases.

const UnorderedCollection = @import("unordered_collection.zig").UnorderedCollection;
const collision = @import("collision.zig");
const math = @import("math.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const util = @import("util.zig");

const grid_cell_side_length = 7;
const SpatialGrid = @import("spatial_partitioning/grid.zig")
    .Grid(u32, grid_cell_side_length, .insert_remove);
const SpatialCollection = @import("spatial_partitioning/collection.zig")
    .Collection(u32, grid_cell_side_length);
const CellIndexType = @import("spatial_partitioning/cell_index.zig").Index;
const CellIndex = CellIndexType(grid_cell_side_length);
const CellRange = @import("spatial_partitioning/cell_range.zig").Range(grid_cell_side_length);
const CellLineIterator = @import("spatial_partitioning/cell_line_iterator.zig").Iterator;
const Fixedpoint = @import("fixedpoint.zig").Fixedpoint;
const cellLineIterator = @import("spatial_partitioning/cell_line_iterator.zig").iterator;

const epsilon = math.epsilon;
const expect = std.testing.expect;
const expectApproxEqRel = std.testing.expectApproxEqRel;

fn expectXZ(vector: ?math.FlatVector, expected_x: math.Fix32, expected_z: math.Fix32) !void {
    try expect(vector != null);
    try expect(expected_x.eql(vector.?.x));
    try expect(expected_z.eql(vector.?.z));
}

test "Fixedpoint conversion" {
    const F8_24 = Fixedpoint(8, 24);
    const F16_16 = Fixedpoint(16, 16);
    const F28_4 = Fixedpoint(28, 4);
    const F32_32 = Fixedpoint(32, 32);
    const F48_16 = Fixedpoint(48, 16);

    try expect(F16_16.fp(-30000.123).convertTo(i16) == -30000);
    try expect(F16_16.fp(30000.123).convertTo(u16) == 30000);
    try expect(F16_16.fp(30000.123).convertTo(u64) == 30000);
    try expect(F32_32.fp(65000.123).convertTo(u16) == 65000);
    try expect(F16_16.fp(-120.123).convertTo(i8) == -120);

    try expectApproxEqRel(F16_16.fp(-30000.123).convertTo(f32), -30000.123, epsilon);
    try expectApproxEqRel(F48_16.fp(3000000.123).convertTo(f32), 3000000.123, epsilon);
    try expectApproxEqRel(F32_32.fp(1.12341234).convertTo(f32), 1.12341234, epsilon);

    try expect(F16_16.fp(120.99).eql(F16_16.fp(120.99)));
    try expect(F16_16.fp(-120.99).eql(F16_16.fp(-120.99)));
    try expect(F16_16.fp(120.99).convertTo(F48_16).eql(F48_16.fp(120.99)));
    try expect(F16_16.fp(-120.99).convertTo(F48_16).eql(F48_16.fp(-120.99)));
    try expect(F48_16.fp(120.99).convertTo(F16_16).eql(F16_16.fp(120.99)));
    try expect(F48_16.fp(-120.99).convertTo(F16_16).eql(F16_16.fp(-120.99)));

    try expect(F16_16.fp(30000.55).convertTo(F32_32).eql(F32_32.fp(30000.54998779296875)));
    try expect(F16_16.fp(-30000.55).convertTo(F32_32).eql(F32_32.fp(-30000.54998779296875)));
    try expect(F16_16.fp(120.55).convertTo(F8_24).eql(F8_24.fp(120.54998779296875)));
    try expect(F16_16.fp(-120.55).convertTo(F8_24).eql(F8_24.fp(-120.54998779296875)));
    try expect(F48_16.fp(120.55).convertTo(F8_24).eql(F8_24.fp(120.54998779296875)));
    try expect(F48_16.fp(-120.55).convertTo(F8_24).eql(F8_24.fp(-120.54998779296875)));

    try expect(F8_24.fp(120.18272).convertTo(F28_4).eql(F28_4.fp(120.125)));
    try expect(F8_24.fp(-120.18272).convertTo(F28_4).eql(F28_4.fp(-120.1875)));
    try expect(F8_24.fp(120.18272).convertTo(F28_4).convertTo(F8_24).eql(F8_24.fp(120.125)));
    try expect(!F8_24.fp(120.18272).convertTo(F28_4).convertTo(F8_24).eql(F8_24.fp(120.18272)));
    try expect(F8_24.fp(120.18272).convertTo(F48_16).eql(F48_16.fp(120.18271)));
    try expect(F8_24.fp(-120.18272).convertTo(F48_16).eql(F48_16.fp(-120.182724)));
    try expect(F32_32.fp(134217727.18272).convertTo(F28_4).eql(F28_4.fp(134217727.125)));
    try expect(F32_32.fp(-134217727.18272).convertTo(F28_4).eql(F28_4.fp(-134217727.1875)));
}

fn testFixedpoint(comptime integer_bits: usize, comptime fractional_bits: usize) !void {
    const Type = Fixedpoint(integer_bits, fractional_bits);
    const fp = Type.fp;

    try expect(fp(@as(u8, 255)).eql(fp(255)));
    try expect(fp(12.9).eql(fp(12.9)));
    try expect(!fp(12.9).eql(fp(12.10)));
    try expect(fp(std.math.pi).eql(fp(@as(f32, 3.1415863))));
    try expect(fp(std.math.e).eql(fp(2.718277)));

    try expect(fp(12.9).add(fp(7)).eql(fp(19.9)));
    try expect(fp(-12.9).add(fp(-7)).eql(fp(-19.9)));
    try expect(fp(30000).add(fp(-30000)).eql(fp(0)));
    try expect(fp(12.9).saturatingAdd(fp(7)).eql(fp(19.9)));
    try expect(fp(-12.9).saturatingAdd(fp(-7)).eql(fp(-19.9)));
    try expect(Type.Limits.max.saturatingAdd(Type.Limits.max).eql(Type.Limits.max));
    try expect(Type.Limits.min.saturatingAdd(Type.Limits.min).eql(Type.Limits.min));
    try expect(fp(12.9).sub(fp(7)).eql(fp(5.9)));
    try expect(fp(-12.9).sub(fp(-7)).eql(fp(-5.9)));
    try expect(fp(30000).sub(fp(30000)).eql(fp(0)));
    try expect(fp(12.5).mul(fp(7)).eql(fp(87.5)));
    try expect(fp(12.9).div(fp(7)).eql(fp(1.842857)));
    try expect(fp(30000).div(fp(10)).eql(fp(3000)));
    try expect(fp(20).mod(fp(7)).eql(fp(6)));

    try expect(fp(12.9).lt(fp(13.1)));
    try expect(!fp(12.9).lt(fp(12.9)));
    try expect(!fp(12.9).lt(fp(1.5)));

    try expect(fp(12.9).lte(fp(13.1)));
    try expect(fp(12.9).lte(fp(12.9)));
    try expect(!fp(92.9).lte(fp(12.9)));

    try expect(fp(92.9).gt(fp(12.9)));
    try expect(!fp(12.9).gt(fp(12.9)));
    try expect(!fp(12.9).gt(fp(92.9)));

    try expect(fp(92.9).gte(fp(12.9)));
    try expect(fp(12.9).gte(fp(12.9)));
    try expect(!fp(12.9).gte(fp(92.9)));

    try expect(fp(12.9).neg().eql(fp(-12.9)));
    try expect(fp(12.9).min(fp(20)).eql(fp(12.9)));
    try expect(fp(12.9).min(fp(4)).eql(fp(4)));
    try expect(fp(12.9).max(fp(20)).eql(fp(20)));
    try expect(fp(12.9).max(fp(4)).eql(fp(12.9)));
    try expect(fp(60).abs().eql(fp(60)));
    try expect(fp(-60).abs().eql(fp(60)));

    try expect(fp(20.123).floor().eql(fp(20)));
    try expect(fp(32767.999).floor().eql(fp(32767)));
    try expect(fp(-32767.999).floor().eql(fp(-32768)));
    try expect(fp(-32768).floor().eql(fp(-32768)));

    try expect(fp(20.123).ceil().eql(fp(21)));
    try expect(fp(-20.123).ceil().eql(fp(-20)));
    try expect(fp(32766.001).ceil().eql(fp(32767)));
    try expect(fp(-32767.999).ceil().eql(fp(-32767)));
    try expect(fp(-32768).ceil().eql(fp(-32767)));

    try expect(fp(200).clamp(fp(170), fp(230)).eql(fp(200)));
    try expect(fp(200).clamp(fp(200), fp(230)).eql(fp(200)));
    try expect(fp(200).clamp(fp(100), fp(200)).eql(fp(200)));
    try expect(fp(20).clamp(fp(170), fp(230)).eql(fp(170)));
    try expect(fp(2000).clamp(fp(170), fp(230)).eql(fp(230)));

    try expect(fp(0).lerp(fp(20), fp(0.5)).eql(fp(10)));
    try expect(fp(70).lerp(fp(90), fp(0)).eql(fp(70)));
    try expect(fp(70).lerp(fp(90), fp(0.5)).eql(fp(80)));
    try expect(fp(70).lerp(fp(90), fp(1)).eql(fp(90)));
    try expect(fp(70).lerp(fp(90), fp(500)).eql(fp(90)));
    try expect(fp(90).lerp(fp(70), fp(0.5)).eql(fp(80)));
    try expect(fp(70).lerp(fp(90), fp(0.75)).eql(fp(85)));
    try expect(fp(70).lerp(fp(90), fp(-2)).eql(fp(70)));

    try expect(fp(180).toRadians().eql(fp(3.1393433)));
    try expect(fp(3.1393433).toDegrees().eql(fp(179.87111)));

    try expect(fp(16).sqrt().eql(fp(4)));
    try expect(fp(16000).sqrt().eql(fp(@as(f32, 126.491104))));
    try expect(fp(0.5).sqrt().eql(fp(0.7070923)));
    try expect(fp(0).sqrt().eql(fp(0)));

    try expect(fp(0).sin().eql(fp(0)));
    try expect(fp(0.22).sin().eql(fp(0.218231)));
    try expect(fp(-0.22).sin().eql(fp(-0.2183075)));
    try expect(fp(12).sin().eql(fp(@as(f32, -0.53678894))));
    try expect(fp(99).sin().eql(fp(@as(f32, -0.99920654))));
    try expect(fp(27.1278).sin().eql(fp(0.9116974)));
    try expect(fp(10).sin().eql(fp(@as(f32, -0.5441284))));
    try expect(fp(-1000).sin().eql(fp(@as(f32, -0.82844543))));
    try expect(fp(-3.9222).sin().eql(fp(@as(f32, 0.7040405))));

    try expect(fp(27.1278).cos().eql(fp(-0.4116974)));
    try expect(fp(-10).cos().eql(fp(@as(f32, -0.8394165))));
    try expect(fp(-3.9222).cos().eql(fp(-0.71073914)));

    try expect(fp(0.22).acos().eql(fp(@as(f32, 1.3483276))));
    try expect(fp(1).acos().eql(fp(0)));
    try expect(fp(-1).acos().eql(fp(@as(f32, 3.1415863))));
    try expect(fp(-0.1209).acos().eql(fp(@as(f32, 1.6936035))));
    try expect(fp(0.9209).acos().eql(fp(0.3991089)));
    try expect(fp(0.99999).acos().eql(fp(@as(f32, 0.005493164))));
}

test "Fixedpoint arithmetic (16.16)" {
    try testFixedpoint(16, 16);

    const fp = Fixedpoint(16, 16).fp;
    try expect(fp(30000).saturatingAdd(fp(30000)).eql(fp(32767.9999999999)));
    try expect(fp(-30000).saturatingAdd(fp(-30000)).eql(fp(-32768)));
}

test "Fixedpoint arithmetic (48.16)" {
    try testFixedpoint(48, 16);
}

test "Fixedpoint arithmetic (32.32)" {
    const fp = Fixedpoint(32, 32).fp;

    try expect(fp(12.9).add(fp(7)).eql(fp(19.9)));
    try expect(fp(-12.9).add(fp(-7)).eql(fp(-19.9)));
    try expect(fp(12.9).sub(fp(7)).eql(fp(5.9)));
    try expect(fp(-2147483648).floor().eql(fp(-2147483648)));
    try expect(fp(20.123).ceil().eql(fp(21)));
    try expect(fp(0).lerp(fp(20), fp(0.5)).eql(fp(10)));
    try expect(fp(16).sqrt().eql(fp(4)));
    try expect(fp(0.22).acos().internal == 5791132792);
}

test "Fixedpoint arithmetic (10.6)" {
    const fp = Fixedpoint(10, 6).fp;

    try expect(fp(12.9).add(fp(7)).eql(fp(19.9)));
    try expect(fp(-12.9).add(fp(-7)).eql(fp(-19.9)));
    try expect(fp(12.9).sub(fp(7)).eql(fp(5.9)));
    try expect(fp(-512).floor().eql(fp(-512)));
    try expect(fp(20.123).ceil().eql(fp(21)));
    try expect(fp(0).lerp(fp(20), fp(0.5)).eql(fp(10)));
    try expect(fp(16).sqrt().eql(fp(4)));
    try expect(fp(0.22).acos().eql(fp(1.3125)));
}

test "FlatVector" {
    const fp = math.Fix32.fp;

    {
        const vector = math.FlatVector.normalize(.{ .x = fp(0), .z = fp(0) });
        try expect(vector.x.eql(fp(0)));
        try expect(vector.z.eql(fp(0)));
    }
    {
        const vector = math.FlatVector.normalize(.{ .x = fp(200.99), .z = fp(63.22) });
        try expect(vector.x.eql(fp(0.95391846)));
        try expect(vector.z.eql(fp(0.30004883)));
    }
}

test "Create collision rectangle" {
    const fp = math.Fix32.fp;

    const rectangle = collision.Rectangle.create(
        .{ .x = fp(12), .z = fp(-3.1) },
        .{ .x = fp(6.16), .z = fp(27.945) },
        fp(19.18),
    );
    try expect(fp(11.1989593506).eql(rectangle.aabb.min.x));
    try expect(fp(-5.2515563965).eql(rectangle.aabb.min.z));
    try expect(fp(30.3789520264).eql(rectangle.aabb.max.x));
    try expect(fp(26.3379364014).eql(rectangle.aabb.max.z));
    try expect(fp(0.1840515137).eql(rectangle.rotation.sine));
    try expect(fp(0.983062744140625).eql(rectangle.rotation.cosine));
    try expect(fp(-0.184173583984375).eql(rectangle.inverse_rotation.sine));
    try expect(fp(0.9830474853515625).eql(rectangle.inverse_rotation.cosine));
}

test "Collision between circle and point" {
    const fp = math.Fix32.fp;

    const circle = collision.Circle{ .position = .{ .x = fp(20), .z = fp(-15) }, .radius = fp(5) };
    try expect(circle.collidesWithPoint(.{ .x = fp(5), .z = fp(-5) }) == null);
    try expect(circle.collidesWithPoint(.{ .x = fp(20), .z = fp(-5) }) == null);
    try expect(circle.collidesWithPoint(.{ .x = fp(5), .z = fp(-15) }) == null);
    try expectXZ(
        circle.collidesWithPoint(.{ .x = fp(22), .z = fp(-16) }),
        fp(-2.472137451171875),
        fp(1.2360382080078125),
    );
}

test "Collision between circle and line" {
    const fp = math.Fix32.fp;

    const circle = collision.Circle{ .position = .{ .x = fp(2), .z = fp(1.5) }, .radius = fp(0.5) };
    try expect(circle.collidesWithLine(.{ .x = fp(2), .z = fp(3) }, .{ .x = fp(3), .z = fp(2) }) == null);
    try expect(circle.collidesWithLine(.{ .x = fp(2.5), .z = fp(2.5) }, .{ .x = fp(3.5), .z = fp(3.5) }) == null);
    try expect(circle.collidesWithLine(.{ .x = fp(0), .z = fp(0) }, .{ .x = fp(0), .z = fp(0) }) == null);

    // Line is partially inside circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(2.2), .z = fp(1.7) },
        .{ .x = fp(3), .z = fp(2) },
    ), fp(-0.153594970703125), fp(-0.153594970703125));
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(3), .z = fp(2) },
        .{ .x = fp(2.2), .z = fp(1.7) },
    ), fp(-0.153594970703125), fp(-0.153594970703125));

    // Line is inside circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(1.6), .z = fp(1.3) },
        .{ .x = fp(2.1), .z = fp(1.6) },
    ), fp(0.241851806640625), fp(-0.402252197265625));
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(2.1), .z = fp(1.6) },
        .{ .x = fp(1.6), .z = fp(1.3) },
    ), fp(0.2410125732421875), fp(-0.4028778076171875));

    // Line is inside circle, but circles center doesn't project onto line.
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(2.1), .z = fp(1.4) },
        .{ .x = fp(2.3), .z = fp(1.4) },
    ), fp(-0.2536468505859375), fp(0.2536773681640625));

    // Line is inside circle and has zero length.
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(1.6), .z = fp(1.3) },
        .{ .x = fp(1.6), .z = fp(1.3) },
    ), fp(0.0472135), fp(0.0236068));

    // Line goes trough circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(1.7), .z = fp(0.3) },
        .{ .x = fp(1.7), .z = fp(2.7) },
    ), fp(0.20001220703125), fp(0));
    try expectXZ(circle.collidesWithLine(
        .{ .x = fp(1), .z = fp(0) },
        .{ .x = fp(3), .z = fp(2) },
    ), fp(-0.1035533), fp(0.1035533));
}

test "Collisions between lines" {
    const fp = math.Fix32.fp;

    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(-1), .z = fp(-3) },
        .{ .x = fp(2.5), .z = fp(-0.5) },
        .{ .x = fp(2), .z = fp(-1.5) },
        .{ .x = fp(0.5), .z = fp(2) },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(2.5), .z = fp(-0.5) },
        .{ .x = fp(-1), .z = fp(-3) },
        .{ .x = fp(2), .z = fp(-1.5) },
        .{ .x = fp(0.5), .z = fp(2) },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(2.5), .z = fp(-0.5) },
        .{ .x = fp(-1), .z = fp(-3) },
        .{ .x = fp(0.5), .z = fp(2) },
        .{ .x = fp(2), .z = fp(-1.5) },
    ) != null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(-1), .z = fp(-3) },
        .{ .x = fp(2.5), .z = fp(-0.5) },
        .{ .x = fp(0.5), .z = fp(2) },
        .{ .x = fp(2), .z = fp(-1.5) },
    ) != null);

    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(-1), .z = fp(-3) },
        .{ .x = fp(2.5), .z = fp(-0.5) },
        .{ .x = fp(0.5), .z = fp(2) },
        .{ .x = fp(-2), .z = fp(-1.5) },
    ) == null);
    try expect(collision.lineCollidesWithLine(
        .{ .x = fp(-1.5), .z = fp(7) },
        .{ .x = fp(1.5), .z = fp(7) },
        .{ .x = fp(-2.5), .z = fp(8) },
        .{ .x = fp(2.5), .z = fp(8) },
    ) == null);
}

test "Collision between line and point" {
    const fp = math.Fix32.fp;

    const line_start = .{ .x = fp(0), .z = fp(0) };
    const line_end = .{ .x = fp(10), .z = fp(10) };
    try expect(!collision.lineCollidesWithPoint(line_start, line_end, .{ .x = fp(2), .z = fp(3) }));
    try expect(!collision.lineCollidesWithPoint(line_start, line_end, .{ .x = fp(11), .z = fp(11) }));
    try expect(!collision.lineCollidesWithPoint(line_start, line_start, .{ .x = fp(11), .z = fp(11) }));
    try expect(collision.lineCollidesWithPoint(line_start, line_end, .{ .x = fp(5), .z = fp(5) }));
    try expect(collision.lineCollidesWithPoint(line_start, line_start, line_start));
}

test "Math: section overlap" {
    try expect(math.getOverlap(0, 20, 30, 40) < 0);
    try expect(math.getOverlap(30, 40, 0, 20) < 0);
    try expect(math.getOverlap(0, 20, 20, 40) == 0);
    try expect(math.getOverlap(20, 40, 0, 20) == 0);
    try expect(math.getOverlap(1, 3, 2, 70) == 1);
    try expect(math.getOverlap(2, 70, 1, 3) == 1);
}

test "Matrix multiplication" {
    const matrix = math.Matrix{ .rows = .{
        .{ 12, 4, 7, 9 },
        .{ 77, 0, 2, 13 },
        .{ 23, 22, 32, 89 },
        .{ 1, 1, 43, 3 },
    } };
    const result = matrix.multiply(math.Matrix.identity);
    try expectApproxEqRel(@as(f32, 12), result.rows[0][0], epsilon);
    try expectApproxEqRel(@as(f32, 4), result.rows[0][1], epsilon);
    try expectApproxEqRel(@as(f32, 7), result.rows[0][2], epsilon);
    try expectApproxEqRel(@as(f32, 9), result.rows[0][3], epsilon);
    try expectApproxEqRel(@as(f32, 77), result.rows[1][0], epsilon);
    try expectApproxEqRel(@as(f32, 0), result.rows[1][1], epsilon);
    try expectApproxEqRel(@as(f32, 2), result.rows[1][2], epsilon);
    try expectApproxEqRel(@as(f32, 13), result.rows[1][3], epsilon);
    try expectApproxEqRel(@as(f32, 23), result.rows[2][0], epsilon);
    try expectApproxEqRel(@as(f32, 22), result.rows[2][1], epsilon);
    try expectApproxEqRel(@as(f32, 32), result.rows[2][2], epsilon);
    try expectApproxEqRel(@as(f32, 89), result.rows[2][3], epsilon);
    try expectApproxEqRel(@as(f32, 1), result.rows[3][0], epsilon);
    try expectApproxEqRel(@as(f32, 1), result.rows[3][1], epsilon);
    try expectApproxEqRel(@as(f32, 43), result.rows[3][2], epsilon);
    try expectApproxEqRel(@as(f32, 3), result.rows[3][3], epsilon);
}

test "Matrix inversion" {
    const matrix = math.Matrix{ .rows = .{
        .{ 12, 4, 7, 9 },
        .{ 77, 0, 2, 13 },
        .{ 23, 22, 32, 89 },
        .{ 1, 1, 43, 3 },
    } };
    const result = matrix.invert();
    try expectApproxEqRel(@as(f32, 0.0199921560), result.rows[0][0], epsilon);
    try expectApproxEqRel(@as(f32, 0.0109564653), result.rows[0][1], epsilon);
    try expectApproxEqRel(@as(f32, -0.0035851123), result.rows[0][2], epsilon);
    try expectApproxEqRel(@as(f32, -0.0010961493), result.rows[0][3], epsilon);
    try expectApproxEqRel(@as(f32, 0.4605939090), result.rows[1][0], epsilon);
    try expectApproxEqRel(@as(f32, -0.0603703409), result.rows[1][1], epsilon);
    try expectApproxEqRel(@as(f32, -0.0362349451), result.rows[1][2], epsilon);
    try expectApproxEqRel(@as(f32, -0.0452069417), result.rows[1][3], epsilon);
    try expectApproxEqRel(@as(f32, -0.0029465300), result.rows[2][0], epsilon);
    try expectApproxEqRel(@as(f32, 0.0003134250), result.rows[2][1], epsilon);
    try expectApproxEqRel(@as(f32, -0.0005614833), result.rows[2][2], epsilon);
    try expectApproxEqRel(@as(f32, 0.0241387505), result.rows[2][3], epsilon);
    try expectApproxEqRel(@as(f32, -0.1179617643), result.rows[3][0], epsilon);
    try expectApproxEqRel(@as(f32, 0.0119788675), result.rows[3][1], epsilon);
    try expectApproxEqRel(@as(f32, 0.0213212781), result.rows[3][2], epsilon);
    try expectApproxEqRel(@as(f32, 0.0027789229), result.rows[3][3], epsilon);
}

test "Text rendering: utility functions" {
    const white = util.Color.white;
    const Segment = text_rendering.TextSegment;
    const getCount = text_rendering.getSpriteCount;
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "" }}) == 0);
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "   " }}) == 0);
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "Hello" }}) == 5);
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "Hello World" }}) == 10);
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "Hello\n \nWorld\n" }}) == 10);
    try expect(getCount(&[_]Segment{.{ .color = white, .text = "ÖÖÖÖ" }}) == 4);

    const text_block =
        [_]Segment{
        .{ .color = white, .text = "This is" },
        .{ .color = white, .text = " a text with potentially" },
        .{ .color = white, .text = "\n\nmultiple colors" },
    };
    try expect(getCount(&text_block) == 40);
}

fn expectSegments(
    segments: []const text_rendering.TextSegment,
    expected_texts: []const []const u8,
) !void {
    try expect(segments.len == expected_texts.len);
    for (segments, 0..) |segment, index| {
        try expect(std.mem.eql(u8, segment.text, expected_texts[index]));
    }
}

fn expectSegmentColors(
    segments: []const text_rendering.TextSegment,
    expected_colors: []const util.Color,
) !void {
    try expect(segments.len == expected_colors.len);
    for (segments, 0..) |segment, index| {
        try expect(segment.color.isEqual(expected_colors[index]));
    }
}

test "Text rendering: reflow text segments" {
    const TextSegment = text_rendering.TextSegment;
    const reflow = text_rendering.reflowTextBlock;
    const white = util.Color.white;

    var reusable_buffer = text_rendering.ReusableBuffer.create(std.testing.allocator);
    defer reusable_buffer.destroy();

    // Empty text block.
    {
        const segments = try reflow(&reusable_buffer, &[_]TextSegment{}, 30);
        try expect(segments.len == 0);
    }

    // Empty lines
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "  \n \n" },
            .{ .color = white, .text = "" },
            .{ .color = white, .text = "  " },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 0);
        try expect(segments.len == 0);
    }

    // Zero line length.
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a long" },
            .{ .color = white, .text = " example text" },
            .{ .color = white, .text = " with words." },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 0);
        try expectSegments(segments, &[_][]const u8{
            "This",   "\n",      "is", "\n",   "a",  "\n",   "long",
            "\n",     "example", "\n", "text", "\n", "with", "\n",
            "words.",
        });
    }

    // Line length == 10.
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a long" },
            .{ .color = white, .text = " example text" },
            .{ .color = white, .text = " with words." },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 10);
        try expectSegments(segments, &[_][]const u8{
            "This",   " ",       "is", " ",    "a", "\n",   "long",
            "\n",     "example", "\n", "text", " ", "with", "\n",
            "words.",
        });
    }

    // Joining newlines.
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a\nlong\n" },
            .{ .color = white, .text = "example\ntext " },
            .{ .color = white, .text = "with words." },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 12);
        try expectSegments(segments, &[_][]const u8{
            "This",   " ",       "is", " ",    "a", "\n",   "long",
            " ",      "example", "\n", "text", " ", "with", "\n",
            "words.",
        });
    }

    // Special treatment for "\n\n" and "\\n".
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a long\n\n" },
            .{ .color = white, .text = "example\\ntext." },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 100);
        try expectSegments(segments, &[_][]const u8{
            "This", " ", "is", " ", "a", " ", "long", "\n", "\n", "example", "\n", "\n", "text.",
        });
    }

    // Don't treat consecutive words as a single token. This test is only here to preserve this
    // simplified behaviour.
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "Progr" },
            .{ .color = white, .text = "amming langu" },
            .{ .color = white, .text = "age progr" },
            .{ .color = white, .text = "amming" },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 3);
        try expectSegments(segments, &[_][]const u8{
            "Progr", "\n", "amming", "\n", "langu",  "\n",
            "age",   "\n", "progr",  "\n", "amming",
        });
    }

    // Preserving colors.
    {
        const green = util.Color.fromRgb8(0, 255, 0);
        const red = util.Color.fromRgb8(255, 0, 0);
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a long" },
            .{ .color = green, .text = " example text" },
            .{ .color = red, .text = " with words." },
        };
        const segments = try reflow(&reusable_buffer, &text_block, 12);
        try expectSegments(segments, &[_][]const u8{
            "This",   " ",       "is", " ",    "a", "\n",   "long",
            " ",      "example", "\n", "text", " ", "with", "\n",
            "words.",
        });
        const expected_colors = [_]util.Color{
            white, white, white, white, white, white, white, green,
            green, green, green, red,   red,   red,   red,
        };
        try expectSegmentColors(segments, &expected_colors);
    }
}

test "Text rendering: truncate text segments" {
    const white = util.Color.white;
    const green = util.Color.fromRgb8(0, 255, 0);
    const red = util.Color.fromRgb8(255, 0, 0);
    const text_block = [_]text_rendering.TextSegment{
        .{ .color = white, .text = "This is a löñg" },
        .{ .color = green, .text = " example\ntext" },
        .{ .color = red, .text = " with words." },
    };

    var reusable_buffer = text_rendering.ReusableBuffer.create(std.testing.allocator);
    defer reusable_buffer.destroy();

    // Length 0.
    {
        const segments = try text_rendering.truncateTextSegments(&reusable_buffer, &text_block, 0);
        try expect(segments.len == 0);
    }

    // Length 20.
    {
        const segments = try text_rendering.truncateTextSegments(&reusable_buffer, &text_block, 20);
        try expectSegments(segments, &[_][]const u8{ "This is a löñg", " examp" });
        try expectSegmentColors(segments, &[_]util.Color{ white, green });
    }

    // Length 32.
    {
        const segments = try text_rendering.truncateTextSegments(&reusable_buffer, &text_block, 32);
        try expectSegments(
            segments,
            &[_][]const u8{ "This is a löñg", " example\ntext", " with" },
        );
        try expectSegmentColors(segments, &[_]util.Color{ white, green, red });
    }

    // Length 1000.
    {
        const segments = try text_rendering.truncateTextSegments(&reusable_buffer, &text_block, 1000);
        try expectSegments(
            segments,
            &[_][]const u8{ "This is a löñg", " example\ntext", " with words." },
        );
        try expectSegmentColors(segments, &[_]util.Color{ white, green, red });
    }
}

test "UnorderedCollection: iterator" {
    var collection = UnorderedCollection(u32).create(std.testing.allocator);
    defer collection.destroy();

    var iterator = collection.iterator();
    try expect(iterator.next() == null);

    try expect(collection.count() == 0);
    try collection.append(1);
    try collection.append(2);
    try collection.append(3);
    try expect(collection.count() == 3);

    // Basic iteration.
    iterator = collection.iterator();
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next() == null);

    // Remove element in the middle.
    iterator = collection.iterator();
    var ptr = iterator.next().?;
    try expect(ptr.* == 1);
    _ = collection.swapRemove(ptr);
    try expect(ptr.* == 3);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next() == null);

    // Remove last element.
    iterator = collection.iterator();
    try expect(iterator.next().?.* == 3);
    ptr = iterator.next().?;
    try expect(ptr.* == 2);
    _ = collection.swapRemove(ptr);
    try expect(iterator.next() == null);

    // Remove only remaining element.
    iterator = collection.iterator();
    ptr = iterator.next().?;
    try expect(ptr.* == 3);
    _ = collection.swapRemove(ptr);
    try expect(iterator.next() == null);

    // Check collection is empty.
    iterator = collection.iterator();
    try expect(iterator.next() == null);

    // Append during iteration.
    iterator = collection.iterator();
    try collection.append(1);
    try expect(iterator.next().?.* == 1);
    try collection.append(2);
    try collection.append(3);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next() == null);
}

test "UnorderedCollection: extra functions" {
    var collection = UnorderedCollection(u32).create(std.testing.allocator);
    defer collection.destroy();

    const value_5 = try collection.appendUninitialized();
    value_5.* = 5;

    var iterator = collection.iterator();
    try expect(iterator.next().?.* == 5);
    try expect(iterator.next() == null);

    collection.removeLastAppendedItem();
    try expect(collection.count() == 0);

    const value_6 = try collection.appendUninitialized();
    value_6.* = 6;
    const value_7 = try collection.appendUninitialized();
    value_7.* = 7;

    try expect(collection.swapRemove(value_6) == value_7);
    try expect(value_6.* == 7);

    try expect(collection.swapRemove(value_6) == null);
    try expect(collection.count() == 0);

    try collection.append(1);
    try collection.append(2);
    try collection.append(3);
    iterator = collection.iterator();
    collection.resetPreservingCapacity();
    try expect(iterator.next() == null);
    try expect(collection.count() == 0);
}

test "CellIndex" {
    const fp = math.Fix32.fp;

    const index = CellIndex.fromPosition(.{ .x = fp(23.89), .z = fp(-34.54) });
    try expect(index.x == 3);
    try expect(index.z == -4);
}

test "CellIndex.compare()" {
    try expect(CellIndex.compare(.{ .x = 10, .z = 9 }, .{ .x = 10, .z = 10 }) == .lt);
    try expect(CellIndex.compare(.{ .x = 100, .z = 9 }, .{ .x = 10, .z = 10 }) == .lt);
    try expect(CellIndex.compare(.{ .x = 1, .z = 11 }, .{ .x = 10, .z = 10 }) == .gt);
    try expect(CellIndex.compare(.{ .x = 100, .z = 10 }, .{ .x = 10, .z = 10 }) == .gt);
    try expect(CellIndex.compare(.{ .x = 1, .z = 10 }, .{ .x = 10, .z = 10 }) == .lt);
    try expect(CellIndex.compare(.{ .x = 10, .z = 10 }, .{ .x = 10, .z = 10 }) == .eq);
}

test "CellRange.countCoveredCells()" {
    try expect(CellRange.countCoveredCells(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } },
    ) == 1);
    try expect(CellRange.countCoveredCells(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 2 } },
    ) == 2);
    try expect(CellRange.countCoveredCells(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 2, .z = 2 } },
    ) == 4);
    try expect(CellRange.countCoveredCells(
        .{ .min = .{ .x = -1, .z = -2 }, .max = .{ .x = 1, .z = 0 } },
    ) == 9);
}

test "CellRange.iterator()" {
    var range =
        CellRange{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } };
    var iterator = range.iterator();
    var result = iterator.next();
    try expect(result != null);
    try expect(result.?.x == 1);
    try expect(result.?.z == 1);
    try expect(iterator.next() == null);

    range = CellRange{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 2, .z = 2 } };
    iterator = range.iterator();
    result = iterator.next();
    try expect(result.?.x == 1);
    try expect(result.?.z == 1);
    result = iterator.next();
    try expect(result.?.x == 2);
    try expect(result.?.z == 1);
    result = iterator.next();
    try expect(result.?.x == 1);
    try expect(result.?.z == 2);
    result = iterator.next();
    try expect(result.?.x == 2);
    try expect(result.?.z == 2);
    try expect(iterator.next() == null);
}

test "CellRange: count touching cells" {
    const range1x1 =
        CellRange{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } };
    try expect(range1x1.countTouchingCells(range1x1) == 1);

    const range100x100 =
        CellRange{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 99, .z = 99 } };
    try expect(range1x1.countTouchingCells(range100x100) == 1);
    try expect(range100x100.countTouchingCells(range100x100) == 10000);

    try expect(range100x100.countTouchingCells(
        .{ .min = .{ .x = -20, .z = -20 }, .max = .{ .x = 0, .z = 0 } },
    ) == 1);
    try expect(range100x100.countTouchingCells(
        .{ .min = .{ .x = -20, .z = -20 }, .max = .{ .x = 1, .z = 1 } },
    ) == 4);
    try expect(range100x100.countTouchingCells(
        .{ .min = .{ .x = 99, .z = 0 }, .max = .{ .x = 99, .z = 99 } },
    ) == 100);
    try expect(range100x100.countTouchingCells(
        .{ .min = .{ .x = 20, .z = 98 }, .max = .{ .x = 25, .z = 200 } },
    ) == 12);
    try expect(range1x1.countTouchingCells(
        .{ .min = .{ .x = -20, .z = -20 }, .max = .{ .x = 0, .z = 0 } },
    ) == 0);
    try expect(range1x1.countTouchingCells(
        .{ .min = .{ .x = -2, .z = 1 }, .max = .{ .x = 0, .z = 20 } },
    ) == 0);
    try expect(range1x1.countTouchingCells(
        .{ .min = .{ .x = 1, .z = -2 }, .max = .{ .x = 20, .z = 0 } },
    ) == 0);
}

test "CellRange.iterator(): overlaps" {
    var iterator = CellRange.iterator(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } },
    );

    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } },
    ));
    try expect(iterator.next() != null);
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 1, .z = 1 } },
    ));

    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 0, .z = 1 }, .max = .{ .x = 2, .z = 1 } },
    ));
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 1, .z = 0 }, .max = .{ .x = 1, .z = 2 } },
    ));
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = -20, .z = -20 }, .max = .{ .x = 20, .z = 20 } },
    ));
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = -20, .z = -20 }, .max = .{ .x = 0, .z = 0 } },
    ));

    iterator = CellRange.iterator(
        .{ .min = .{ .x = 20, .z = 20 }, .max = .{ .x = 23, .z = 22 } },
    );
    var counter: usize = 0;
    while (counter < 8) : (counter += 1) {
        try expect(iterator.next() != null);
        try expect(!iterator.isOverlappingWithOnlyOneCell(
            .{ .min = .{ .x = 19, .z = 22 }, .max = .{ .x = 21, .z = 23 } },
        ));
    }
    try expect(iterator.next() != null);
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 19, .z = 22 }, .max = .{ .x = 21, .z = 23 } },
    ));
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 23, .z = 24 }, .max = .{ .x = 21, .z = 22 } },
    ));
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 22, .z = 22 }, .max = .{ .x = 23, .z = 23 } },
    ));

    try expect(iterator.next() != null);
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 19, .z = 22 }, .max = .{ .x = 21, .z = 23 } },
    ));

    iterator = CellRange.iterator(
        .{ .min = .{ .x = 20, .z = 20 }, .max = .{ .x = 23, .z = 22 } },
    );
    counter = 0;
    while (counter < 8) : (counter += 1) {
        try expect(iterator.next() != null);
    }
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 23, .z = 21 }, .max = .{ .x = 24, .z = 22 } },
    ));
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 23, .z = 18 }, .max = .{ .x = 24, .z = 20 } },
    ));
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 22, .z = 18 }, .max = .{ .x = 24, .z = 20 } },
    ));
    try expect(iterator.next() != null);
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 23, .z = 21 }, .max = .{ .x = 24, .z = 22 } },
    ));
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 23, .z = 18 }, .max = .{ .x = 24, .z = 20 } },
    ));

    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 22, .z = 22 }, .max = .{ .x = 23, .z = 23 } },
    ));
    try expect(iterator.next() != null);
    try expect(iterator.next() != null);
    try expect(iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 22, .z = 22 }, .max = .{ .x = 23, .z = 23 } },
    ));
    try expect(iterator.next() != null);
    try expect(!iterator.isOverlappingWithOnlyOneCell(
        .{ .min = .{ .x = 22, .z = 22 }, .max = .{ .x = 23, .z = 23 } },
    ));
}

test "SpatialGrid: insert and destroy" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    _ = try grid.insertIntoArea(19, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(14), .z = fp(84) },
    });
    _ = try grid.insertIntoArea(20, .{
        .min = .{ .x = fp(1), .z = fp(1) },
        .max = .{ .x = fp(20), .z = fp(20) },
    });
}

test "SpatialGrid: insert and remove" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    var handle_12 = try grid.insertIntoArea(99, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(14), .z = fp(14) },
    });
    grid.remove(handle_12);

    const handle_11 = try grid.insertIntoArea(19, .{
        .min = .{ .x = fp(-40), .z = fp(20) },
        .max = .{ .x = fp(14), .z = fp(84) },
    });
    handle_12 = try grid.insertIntoArea(20, .{
        .min = .{ .x = fp(-10), .z = fp(0) },
        .max = .{ .x = fp(-1), .z = fp(3) },
    });
    const handle_34 = try grid.insertIntoArea(21, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(23), .z = fp(32) },
    });
    grid.remove(handle_12);
    grid.remove(handle_34);
    grid.remove(handle_11);
}

test "SpatialGrid: insert and remove: update displaced object ids" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const handle_11 = try grid.insertIntoArea(19, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(100), .z = fp(100) },
    });
    const handle_12 = try grid.insertIntoArea(20, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(100), .z = fp(100) },
    });
    _ = try grid.insertIntoArea(21, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(100), .z = fp(100) },
    });
    grid.remove(handle_12);
    grid.remove(handle_11);
}

fn testAreaIterator(
    iterator: *SpatialGrid.ConstAreaIterator,
    expected_numbers: []const usize,
) !void {
    var index: usize = 0;
    while (iterator.next()) |value| : (index += 1) {
        try expect(value == expected_numbers[index]);
    }
    try expect(index == expected_numbers.len);
}

test "SpatialGrid: const iterator: basic usage" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const range = .{ .min = .{ .x = fp(0), .z = fp(0) }, .max = .{ .x = fp(100), .z = fp(100) } };

    var iterator = grid.areaIterator(range);
    try expect(iterator.next() == null);

    const handle_11 = try grid.insertIntoArea(19, .{
        .min = .{ .x = fp(0), .z = fp(0) },
        .max = .{ .x = fp(14), .z = fp(84) },
    });
    iterator = grid.areaIterator(range);
    try testAreaIterator(&iterator, &[_]usize{
        19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
        19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    });

    grid.remove(handle_11);
    iterator = grid.areaIterator(range);
    try expect(iterator.next() == null);
}

test "SpatialGrid: const iterator: region queries" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const handles = .{
        try grid.insertIntoArea(1, .{ .min = .{ .x = fp(-160), .z = fp(-190) }, .max = .{ .x = fp(-70), .z = fp(-30) } }),
        try grid.insertIntoArea(2, .{ .min = .{ .x = fp(-120), .z = fp(70) }, .max = .{ .x = fp(-10), .z = fp(130) } }),
        try grid.insertIntoArea(3, .{ .min = .{ .x = fp(20), .z = fp(70) }, .max = .{ .x = fp(80), .z = fp(130) } }),
        try grid.insertIntoArea(4, .{ .min = .{ .x = fp(70), .z = fp(20) }, .max = .{ .x = fp(130), .z = fp(70) } }),
        try grid.insertIntoArea(5, .{ .min = .{ .x = fp(80), .z = fp(-130) }, .max = .{ .x = fp(130), .z = fp(-10) } }),
        try grid.insertIntoArea(6, .{ .min = .{ .x = fp(30), .z = fp(-130) }, .max = .{ .x = fp(130), .z = fp(-10) } }),
    };

    const range = .{ .min = .{ .x = fp(-70), .z = fp(-30) }, .max = .{ .x = fp(90), .z = fp(90) } };
    var iterator = grid.areaIterator(range);
    try testAreaIterator(&iterator, &[_]usize{
        1, 6, 6, 6, 6, 6, 6, 6, 5, 6, 5, 6, 6, 6, 6, 6, 6, 6, 6, 5, 6, 5, 6, 6, 6, 6, 6, 6, 6, 6, 5,
        6, 5, 6, 6, 6, 6, 6, 6, 6, 6, 5, 6, 5, 6, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 4, 4, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3,
    });

    grid.remove(handles[4]);
    grid.remove(handles[3]);
    grid.remove(handles[1]);
    iterator = grid.areaIterator(range);
    try testAreaIterator(&iterator, &[_]usize{
        1, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3,
    });

    iterator = grid.areaIterator(
        .{ .min = .{ .x = fp(0), .z = fp(0) }, .max = .{ .x = fp(0), .z = fp(0) } },
    );
    try expect(iterator.next() == null);

    grid.remove(handles[0]);
    iterator = grid.areaIterator(range);
    try testAreaIterator(&iterator, &[_]usize{
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3,
    });
}

test "SpatialCollection: iterator" {
    const fp = math.Fix32.fp;

    var collection = SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    const handles = .{
        try collection.insert(1, .{ .x = fp(-160), .z = fp(-190) }),
        try collection.insert(2, .{ .x = fp(-120), .z = fp(70) }),
        try collection.insert(3, .{ .x = fp(20), .z = fp(70) }),
        try collection.insert(4, .{ .x = fp(70), .z = fp(20) }),
        try collection.insert(5, .{ .x = fp(80), .z = fp(-130) }),
        try collection.insert(6, .{ .x = fp(20), .z = fp(-130) }),
        try collection.insert(7, .{ .x = fp(20), .z = fp(-130) }),
    };

    var iterator = collection.iterator();
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next().?.* == 6);
    try expect(iterator.next().?.* == 7);
    try expect(iterator.next().?.* == 5);
    try expect(iterator.next().?.* == 4);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next() == null);

    collection.remove(handles[5]);
    collection.remove(handles[0]);
    collection.remove(handles[2]);

    iterator = collection.iterator();
    try expect(iterator.next().?.* == 7);
    try expect(iterator.next().?.* == 5);
    try expect(iterator.next().?.* == 4);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next() == null);

    collection.remove(handles[3]);
    collection.remove(handles[1]);
    collection.remove(handles[6]);

    iterator = collection.iterator();
    try expect(iterator.next().?.* == 5);
    try expect(iterator.next() == null);
}

test "SpatialCollection: iterator: skip cells" {
    const fp = math.Fix32.fp;

    var collection = SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    _ = try collection.insert(1, .{ .x = fp(-160), .z = fp(-190) });
    _ = try collection.insert(2, .{ .x = fp(-120), .z = fp(70) });
    _ = try collection.insert(3, .{ .x = fp(20), .z = fp(70) });
    _ = try collection.insert(4, .{ .x = fp(70), .z = fp(20) });
    _ = try collection.insert(5, .{ .x = fp(80), .z = fp(-130) });
    _ = try collection.insert(6, .{ .x = fp(20), .z = fp(-130) });
    _ = try collection.insert(7, .{ .x = fp(20), .z = fp(-130) });

    var iterator = collection.iteratorAdvanced(4, 0);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next() == null);

    iterator = collection.iteratorAdvanced(0, 2);
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next().?.* == 4);
    try expect(iterator.next() == null);

    iterator = collection.iteratorAdvanced(0, 3);
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next().?.* == 2);
    try expect(iterator.next() == null);

    iterator = collection.iteratorAdvanced(2, 2);
    try expect(iterator.next().?.* == 5);
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next() == null);

    iterator = collection.iteratorAdvanced(0, 10000);
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next() == null);
    iterator = collection.iteratorAdvanced(10000, 0);
    try expect(iterator.next() == null);
}

test "SpatialCollection: update displaced back references" {
    const fp = math.Fix32.fp;

    var collection = SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    const handles = .{
        try collection.insert(0, .{ .x = fp(0), .z = fp(10) }),
        try collection.insert(1, .{ .x = fp(0), .z = fp(10) }),
        try collection.insert(2, .{ .x = fp(0), .z = fp(10) }),
    };
    collection.remove(handles[0]);
    _ = try collection.insert(3, .{ .x = fp(0), .z = fp(10) });
    collection.remove(handles[2]);

    var iterator = collection.iterator();
    try expect(iterator.next().?.* == 3);
    try expect(iterator.next().?.* == 1);
    try expect(iterator.next() == null);
}

fn testCellLineIterator(
    comptime cell_side_length: u32,
    iterator: *CellLineIterator(CellIndexType(cell_side_length)),
    expected_indices: []const CellIndexType(cell_side_length),
) !void {
    var index: usize = 0;
    while (iterator.next()) |cell_index| : (index += 1) {
        try expect(index < expected_indices.len);
        try expect(cell_index.compare(expected_indices[index]) == .eq);
    }
    try expect(index == expected_indices.len);
}

test "Cell line iterator" {
    const fp = math.Fix32.fp;

    const cell_size = 5;
    const CellType = CellIndexType(cell_size);

    var iterator = cellLineIterator(
        CellType,
        .{ .x = fp(3), .z = fp(-3) },
        .{ .x = fp(3), .z = fp(-3) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{.{ .x = 0, .z = 0 }});

    iterator = cellLineIterator(CellType, .{ .x = fp(5), .z = fp(5) }, .{ .x = fp(0), .z = fp(5) });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 1, .z = 1 }, .{ .x = 0, .z = 1 },
    });

    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(3), .z = fp(-3) },
        .{ .x = fp(70), .z = fp(-9) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 0, .z = 0 },   .{ .x = 1, .z = 0 },   .{ .x = 2, .z = 0 },
        .{ .x = 3, .z = 0 },   .{ .x = 4, .z = 0 },   .{ .x = 5, .z = 0 },
        .{ .x = 5, .z = -1 },  .{ .x = 6, .z = -1 },  .{ .x = 7, .z = -1 },
        .{ .x = 8, .z = -1 },  .{ .x = 9, .z = -1 },  .{ .x = 10, .z = -1 },
        .{ .x = 11, .z = -1 }, .{ .x = 12, .z = -1 }, .{ .x = 13, .z = -1 },
        .{ .x = 14, .z = -1 },
    });

    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(3), .z = fp(-3) },
        .{ .x = fp(43), .z = fp(-11) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 0, .z = 0 },  .{ .x = 1, .z = 0 },  .{ .x = 2, .z = 0 },
        .{ .x = 2, .z = -1 }, .{ .x = 3, .z = -1 }, .{ .x = 4, .z = -1 },
        .{ .x = 5, .z = -1 }, .{ .x = 6, .z = -1 }, .{ .x = 7, .z = -1 },
        .{ .x = 7, .z = -2 }, .{ .x = 8, .z = -2 },
    });

    // Previous test in reverse direction.
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(43), .z = fp(-11) },
        .{ .x = fp(3), .z = fp(-3) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 8, .z = -2 }, .{ .x = 7, .z = -2 }, .{ .x = 7, .z = -1 },
        .{ .x = 6, .z = -1 }, .{ .x = 5, .z = -1 }, .{ .x = 4, .z = -1 },
        .{ .x = 3, .z = -1 }, .{ .x = 2, .z = -1 }, .{ .x = 2, .z = 0 },
        .{ .x = 1, .z = 0 },  .{ .x = 0, .z = 0 },
    });

    // 3x3 diagonal traversal in all directions.
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(15), .z = fp(15) },
        .{ .x = fp(25), .z = fp(25) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 3 }, .{ .x = 4, .z = 3 }, .{ .x = 4, .z = 4 },
        .{ .x = 5, .z = 4 }, .{ .x = 5, .z = 5 },
    });
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(25), .z = fp(25) },
        .{ .x = fp(15), .z = fp(15) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 5, .z = 5 }, .{ .x = 4, .z = 5 }, .{ .x = 4, .z = 4 },
        .{ .x = 3, .z = 4 }, .{ .x = 3, .z = 3 },
    });
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(25), .z = fp(15) },
        .{ .x = fp(15), .z = fp(25) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 5, .z = 3 }, .{ .x = 5, .z = 4 }, .{ .x = 4, .z = 4 },
        .{ .x = 4, .z = 5 }, .{ .x = 3, .z = 5 },
    });
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(15), .z = fp(25) },
        .{ .x = fp(25), .z = fp(15) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 5 }, .{ .x = 4, .z = 5 }, .{ .x = 4, .z = 4 },
        .{ .x = 5, .z = 4 }, .{ .x = 5, .z = 3 },
    });

    // 3x4 diagonal traversal.
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(15), .z = fp(15) },
        .{ .x = fp(25), .z = fp(30) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 3 }, .{ .x = 3, .z = 4 }, .{ .x = 4, .z = 4 },
        .{ .x = 4, .z = 5 }, .{ .x = 5, .z = 5 }, .{ .x = 5, .z = 6 },
    });

    // Long line downwards.
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(-6), .z = fp(-3) },
        .{ .x = fp(-10.001), .z = fp(46) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = -1, .z = 0 }, .{ .x = -1, .z = 1 }, .{ .x = -1, .z = 2 },
        .{ .x = -1, .z = 3 }, .{ .x = -1, .z = 4 }, .{ .x = -1, .z = 5 },
        .{ .x = -1, .z = 6 }, .{ .x = -1, .z = 7 }, .{ .x = -1, .z = 8 },
        .{ .x = -1, .z = 9 }, .{ .x = -1, .z = 9 }, .{ .x = -2, .z = 9 },
    });
    // Long line upwards.
    iterator = cellLineIterator(
        CellType,
        .{ .x = fp(-10.001), .z = fp(46) },
        .{ .x = fp(-6), .z = fp(-3) },
    );
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = -2, .z = 9 }, .{ .x = -1, .z = 9 }, .{ .x = -1, .z = 8 },
        .{ .x = -1, .z = 7 }, .{ .x = -1, .z = 6 }, .{ .x = -1, .z = 5 },
        .{ .x = -1, .z = 4 }, .{ .x = -1, .z = 3 }, .{ .x = -1, .z = 2 },
        .{ .x = -1, .z = 1 }, .{ .x = -1, .z = 0 },
    });
}

test "SpatialGrid: const straight line iterator" {
    const fp = math.Fix32.fp;

    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const factor = fp(grid_cell_side_length).mul(fp(0.4));
    _ = try grid.insertIntoArea(1, .{
        .min = .{ .x = fp(-16).mul(factor), .z = fp(-19).mul(factor) },
        .max = .{ .x = fp(-7).mul(factor), .z = fp(-3).mul(factor) },
    });
    _ = try grid.insertIntoArea(2, .{
        .min = .{ .x = fp(-12).mul(factor), .z = fp(7).mul(factor) },
        .max = .{ .x = fp(-1).mul(factor), .z = fp(13).mul(factor) },
    });
    _ = try grid.insertIntoArea(3, .{
        .min = .{ .x = fp(2).mul(factor), .z = fp(7).mul(factor) },
        .max = .{ .x = fp(8).mul(factor), .z = fp(13).mul(factor) },
    });
    _ = try grid.insertIntoArea(4, .{
        .min = .{ .x = fp(7).mul(factor), .z = fp(2).mul(factor) },
        .max = .{ .x = fp(13).mul(factor), .z = fp(7).mul(factor) },
    });
    _ = try grid.insertIntoArea(5, .{
        .min = .{ .x = fp(8).mul(factor), .z = fp(-13).mul(factor) },
        .max = .{ .x = fp(13).mul(factor), .z = fp(-1).mul(factor) },
    });
    _ = try grid.insertIntoArea(6, .{
        .min = .{ .x = fp(3).mul(factor), .z = fp(-13).mul(factor) },
        .max = .{ .x = fp(13).mul(factor), .z = fp(-1).mul(factor) },
    });
    _ = try grid.insertIntoArea(7, .{
        .min = .{ .x = fp(3).mul(factor), .z = fp(-13).mul(factor) },
        .max = .{ .x = fp(13).mul(factor), .z = fp(-1).mul(factor) },
    });

    var iterator = grid.straightLineIterator(
        .{ .x = fp(0).mul(factor), .z = fp(0).mul(factor) },
        .{ .x = fp(0).mul(factor), .z = fp(0).mul(factor) },
    );
    try expect(iterator.next() == null);
    iterator = grid.straightLineIterator(
        .{ .x = fp(-7000).mul(factor), .z = fp(3000).mul(factor) },
        .{ .x = fp(-7000).mul(factor), .z = fp(3000).mul(factor) },
    );
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = fp(-9).mul(factor), .z = fp(-4.5).mul(factor) },
        .{ .x = fp(12).mul(factor), .z = fp(10).mul(factor) },
    );
    try expect(iterator.next().? == 1);
    try expect(iterator.next().? == 1);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 4);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = fp(-2).mul(factor), .z = fp(-2).mul(factor) },
        .{ .x = fp(12).mul(factor), .z = fp(15).mul(factor) },
    );
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 4);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = fp(-7).mul(factor), .z = fp(7).mul(factor) },
        .{ .x = fp(3).mul(factor), .z = fp(-1).mul(factor) },
    );
    try expect(iterator.next().? == 2);
    try expect(iterator.next().? == 2);
    try expect(iterator.next().? == 6);
    try expect(iterator.next().? == 7);
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = fp(0).mul(factor), .z = fp(0).mul(factor) },
        .{ .x = fp(3).mul(factor), .z = fp(-1).mul(factor) },
    );
    try expect(iterator.next().? == 6);
    try expect(iterator.next().? == 7);
    try expect(iterator.next() == null);
}
