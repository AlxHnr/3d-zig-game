//! Contains various test cases.

const UnorderedCollection = @import("unordered_collection.zig").UnorderedCollection;
const collision = @import("collision.zig");
const math = @import("math.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const util = @import("util.zig");

const grid_cell_side_length = 7;
const SpatialGrid = @import("spatial_partitioning/grid.zig").Grid(u32, grid_cell_side_length);
const SpatialCollection =
    @import("spatial_partitioning/collection.zig").Collection(u32, grid_cell_side_length);
const CellIndexType = @import("spatial_partitioning/cell_index.zig").Index;
const CellIndex = CellIndexType(grid_cell_side_length);
const CellRange = @import("spatial_partitioning/cell_range.zig").Range(grid_cell_side_length);
const CellLineIterator = @import("spatial_partitioning/cell_line_iterator.zig").Iterator;
const cellLineIterator = @import("spatial_partitioning/cell_line_iterator.zig").iterator;

const epsilon = math.epsilon;
const expect = std.testing.expect;
const expectApproxEqRel = std.testing.expectApproxEqRel;

fn expectXZ(vector: ?math.FlatVector, expected_x: f32, expected_z: f32) !void {
    try expect(vector != null);
    try expectApproxEqRel(expected_x, vector.?.x, epsilon);
    try expectApproxEqRel(expected_z, vector.?.z, epsilon);
}

test "Create collision rectangle" {
    const rectangle = collision.Rectangle.create(
        .{ .x = 12, .z = -3.1 },
        .{ .x = 6.16, .z = 27.945 },
        19.18,
    );
    const expected_angle = std.math.degreesToRadians(f32, 10.653624);
    try expectApproxEqRel(@as(f32, 11.220045), rectangle.aabb.min.x, epsilon);
    try expectApproxEqRel(@as(f32, -5.265016), rectangle.aabb.min.z, epsilon);
    try expectApproxEqRel(@as(f32, 30.400045), rectangle.aabb.max.x, epsilon);
    try expectApproxEqRel(@as(f32, 26.3245), rectangle.aabb.max.z, epsilon);
    try expectApproxEqRel(std.math.sin(expected_angle), rectangle.rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(expected_angle), rectangle.rotation.cosine, epsilon);
    try expectApproxEqRel(std.math.sin(-expected_angle), rectangle.inverse_rotation.sine, epsilon);
    try expectApproxEqRel(std.math.cos(-expected_angle), rectangle.inverse_rotation.cosine, epsilon);
}

test "Collision between circle and point" {
    const circle = collision.Circle{ .position = .{ .x = 20, .z = -15 }, .radius = 5 };
    try expect(circle.collidesWithPoint(.{ .x = 5, .z = -5 }) == null);
    try expect(circle.collidesWithPoint(.{ .x = 20, .z = -5 }) == null);
    try expect(circle.collidesWithPoint(.{ .x = 5, .z = -15 }) == null);
    try expectXZ(circle.collidesWithPoint(.{ .x = 22, .z = -16 }), -2.472135, 1.236067);
}

test "Collision between circle and line" {
    const circle = collision.Circle{ .position = .{ .x = 2, .z = 1.5 }, .radius = 0.5 };
    try expect(circle.collidesWithLine(.{ .x = 2, .z = 3 }, .{ .x = 3, .z = 2 }) == null);
    try expect(circle.collidesWithLine(.{ .x = 2.5, .z = 2.5 }, .{ .x = 3.5, .z = 3.5 }) == null);
    try expect(circle.collidesWithLine(.{ .x = 0, .z = 0 }, .{ .x = 0, .z = 0 }) == null);

    // Line is partially inside circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = 2.2, .z = 1.7 },
        .{ .x = 3, .z = 2 },
    ), -0.153553, -0.153553);
    try expectXZ(circle.collidesWithLine(
        .{ .x = 3, .z = 2 },
        .{ .x = 2.2, .z = 1.7 },
    ), -0.153553, -0.153553);

    // Line is inside circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = 1.6, .z = 1.3 },
        .{ .x = 2.1, .z = 1.6 },
    ), 0.239600360, -0.399334996);
    try expectXZ(circle.collidesWithLine(
        .{ .x = 2.1, .z = 1.6 },
        .{ .x = 1.6, .z = 1.3 },
    ), 0.239600360, -0.399334996);

    // Line is inside circle, but circles center doesn't project onto line.
    try expectXZ(circle.collidesWithLine(
        .{ .x = 2.1, .z = 1.4 },
        .{ .x = 2.3, .z = 1.4 },
    ), -0.2535532, 0.2535535);

    // Line is inside circle and has zero length.
    try expectXZ(circle.collidesWithLine(
        .{ .x = 1.6, .z = 1.3 },
        .{ .x = 1.6, .z = 1.3 },
    ), 0.0472135, 0.0236068);

    // Line goes trough circle.
    try expectXZ(circle.collidesWithLine(
        .{ .x = 1.7, .z = 0.3 },
        .{ .x = 1.7, .z = 2.7 },
    ), 0.2, 0);
    try expectXZ(circle.collidesWithLine(
        .{ .x = 1, .z = 0 },
        .{ .x = 3, .z = 2 },
    ), -0.1035533, 0.1035533);
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

test "Collision between line and point" {
    const line_start = .{ .x = 0, .z = 0 };
    const line_end = .{ .x = 10, .z = 10 };
    try expect(!collision.lineCollidesWithPoint(line_start, line_end, .{ .x = 2, .z = 3 }));
    try expect(!collision.lineCollidesWithPoint(line_start, line_end, .{ .x = 11, .z = 11 }));
    try expect(!collision.lineCollidesWithPoint(line_start, line_start, .{ .x = 11, .z = 11 }));
    try expect(collision.lineCollidesWithPoint(line_start, line_end, .{ .x = 5, .z = 5 }));
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
    const allocator = std.testing.allocator;
    const TextSegment = text_rendering.TextSegment;
    const reflow = text_rendering.reflowTextBlock;
    const white = util.Color.white;

    // Empty text block.
    {
        const segments = try reflow(allocator, &[_]TextSegment{}, 30);
        defer text_rendering.freeTextSegments(allocator, segments); // Test no-op.
        try expect(segments.len == 0);
    }

    // Empty lines
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "  \n \n" },
            .{ .color = white, .text = "" },
            .{ .color = white, .text = "  " },
        };
        const segments = try reflow(allocator, &text_block, 0);
        defer text_rendering.freeTextSegments(allocator, segments); // Test no-op.
        try expect(segments.len == 0);
    }

    // Zero line length.
    {
        const text_block = [_]TextSegment{
            .{ .color = white, .text = "This is a long" },
            .{ .color = white, .text = " example text" },
            .{ .color = white, .text = " with words." },
        };
        const segments = try reflow(allocator, &text_block, 0);
        defer text_rendering.freeTextSegments(allocator, segments);
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
        const segments = try reflow(allocator, &text_block, 10);
        defer text_rendering.freeTextSegments(allocator, segments);
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
        const segments = try reflow(allocator, &text_block, 12);
        defer text_rendering.freeTextSegments(allocator, segments);
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
        const segments = try reflow(allocator, &text_block, 100);
        defer text_rendering.freeTextSegments(allocator, segments);
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
        const segments = try reflow(allocator, &text_block, 3);
        defer text_rendering.freeTextSegments(allocator, segments);
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
        const segments = try reflow(allocator, &text_block, 12);
        defer text_rendering.freeTextSegments(allocator, segments);
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
    const allocator = std.testing.allocator;
    const text_block = [_]text_rendering.TextSegment{
        .{ .color = white, .text = "This is a löñg" },
        .{ .color = green, .text = " example\ntext" },
        .{ .color = red, .text = " with words." },
    };

    // Length 0.
    {
        const segments = try text_rendering.truncateTextSegments(allocator, &text_block, 0);
        defer text_rendering.freeTextSegments(allocator, segments);
        try expect(segments.len == 0);
    }

    // Length 20.
    {
        const segments = try text_rendering.truncateTextSegments(allocator, &text_block, 20);
        defer text_rendering.freeTextSegments(allocator, segments);
        try expectSegments(segments, &[_][]const u8{ "This is a löñg", " examp" });
        try expectSegmentColors(segments, &[_]util.Color{ white, green });
    }

    // Length 32.
    {
        const segments = try text_rendering.truncateTextSegments(allocator, &text_block, 32);
        defer text_rendering.freeTextSegments(allocator, segments);
        try expectSegments(
            segments,
            &[_][]const u8{ "This is a löñg", " example\ntext", " with" },
        );
        try expectSegmentColors(segments, &[_]util.Color{ white, green, red });
    }

    // Length 1000.
    {
        const segments = try text_rendering.truncateTextSegments(allocator, &text_block, 1000);
        defer text_rendering.freeTextSegments(allocator, segments);
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
    const index = CellIndex.fromPosition(.{ .x = 23.89, .z = -34.54 });
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
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    _ = try grid.insertIntoArea(19, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 14, .z = 84 } });
    _ = try grid.insertIntoArea(20, .{ .min = .{ .x = 1, .z = 1 }, .max = .{ .x = 20, .z = 20 } });
}

test "SpatialGrid: insert and remove" {
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    var handle_12 =
        try grid.insertIntoArea(99, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 14, .z = 14 } });
    grid.remove(handle_12);

    const handle_11 =
        try grid.insertIntoArea(19, .{ .min = .{ .x = -40, .z = 20 }, .max = .{ .x = 14, .z = 84 } });
    handle_12 =
        try grid.insertIntoArea(20, .{ .min = .{ .x = -10, .z = 0 }, .max = .{ .x = -1, .z = 3 } });
    const handle_34 =
        try grid.insertIntoArea(21, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 23, .z = 32 } });
    grid.remove(handle_12);
    grid.remove(handle_34);
    grid.remove(handle_11);
}

test "SpatialGrid: insert and remove: update displaced object ids" {
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const handle_11 =
        try grid.insertIntoArea(19, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 100, .z = 100 } });
    const handle_12 =
        try grid.insertIntoArea(20, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 100, .z = 100 } });
    _ = try grid.insertIntoArea(21, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 100, .z = 100 } });
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
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const range = .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 100, .z = 100 } };

    var iterator = grid.areaIterator(range);
    try expect(iterator.next() == null);

    const handle_11 =
        try grid.insertIntoArea(19, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 14, .z = 84 } });
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
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const handles = .{
        try grid.insertIntoArea(1, .{ .min = .{ .x = -160, .z = -190 }, .max = .{ .x = -70, .z = -30 } }),
        try grid.insertIntoArea(2, .{ .min = .{ .x = -120, .z = 70 }, .max = .{ .x = -10, .z = 130 } }),
        try grid.insertIntoArea(3, .{ .min = .{ .x = 20, .z = 70 }, .max = .{ .x = 80, .z = 130 } }),
        try grid.insertIntoArea(4, .{ .min = .{ .x = 70, .z = 20 }, .max = .{ .x = 130, .z = 70 } }),
        try grid.insertIntoArea(5, .{ .min = .{ .x = 80, .z = -130 }, .max = .{ .x = 130, .z = -10 } }),
        try grid.insertIntoArea(6, .{ .min = .{ .x = 30, .z = -130 }, .max = .{ .x = 130, .z = -10 } }),
    };

    const range = .{ .min = .{ .x = -70, .z = -30 }, .max = .{ .x = 90, .z = 90 } };
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

    iterator = grid.areaIterator(.{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 0, .z = 0 } });
    try expect(iterator.next() == null);

    grid.remove(handles[0]);
    iterator = grid.areaIterator(range);
    try testAreaIterator(&iterator, &[_]usize{
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3,
    });
}

test "SpatialGrid: reset to empty state." {
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const range = .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 100, .z = 100 } };

    _ = try grid.insertIntoArea(0, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 14, .z = 84 } });
    _ = try grid.insertIntoArea(1, .{ .min = .{ .x = 0, .z = 0 }, .max = .{ .x = 14, .z = 84 } });
    grid.resetPreservingCapacity();
    var iterator = grid.areaIterator(range);
    try expect(iterator.next() == null);
}

test "SpatialCollection: iterator" {
    var collection = try SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    const handles = .{
        try collection.insert(1, .{ .x = -160, .z = -190 }),
        try collection.insert(2, .{ .x = -120, .z = 70 }),
        try collection.insert(3, .{ .x = 20, .z = 70 }),
        try collection.insert(4, .{ .x = 70, .z = 20 }),
        try collection.insert(5, .{ .x = 80, .z = -130 }),
        try collection.insert(6, .{ .x = 20, .z = -130 }),
        try collection.insert(7, .{ .x = 20, .z = -130 }),
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
    var collection = try SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    _ = try collection.insert(1, .{ .x = -160, .z = -190 });
    _ = try collection.insert(2, .{ .x = -120, .z = 70 });
    _ = try collection.insert(3, .{ .x = 20, .z = 70 });
    _ = try collection.insert(4, .{ .x = 70, .z = 20 });
    _ = try collection.insert(5, .{ .x = 80, .z = -130 });
    _ = try collection.insert(6, .{ .x = 20, .z = -130 });
    _ = try collection.insert(7, .{ .x = 20, .z = -130 });

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
    var collection = try SpatialCollection.create(std.testing.allocator);
    defer collection.destroy();

    const handles = .{
        try collection.insert(0, .{ .x = 0, .z = 10 }),
        try collection.insert(1, .{ .x = 0, .z = 10 }),
        try collection.insert(2, .{ .x = 0, .z = 10 }),
    };
    collection.remove(handles[0]);
    _ = try collection.insert(3, .{ .x = 0, .z = 10 });
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
    const cell_size = 5;
    const CellType = CellIndexType(cell_size);

    var iterator = cellLineIterator(CellType, .{ .x = 3, .z = -3 }, .{ .x = 3, .z = -3 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{.{ .x = 0, .z = 0 }});

    iterator = cellLineIterator(CellType, .{ .x = 5, .z = 5 }, .{ .x = 0, .z = 5 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 1, .z = 1 }, .{ .x = 0, .z = 1 },
    });

    iterator = cellLineIterator(CellType, .{ .x = 3, .z = -3 }, .{ .x = 70, .z = -9 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 0, .z = 0 },   .{ .x = 1, .z = 0 },   .{ .x = 2, .z = 0 },
        .{ .x = 3, .z = 0 },   .{ .x = 4, .z = 0 },   .{ .x = 5, .z = 0 },
        .{ .x = 5, .z = -1 },  .{ .x = 6, .z = -1 },  .{ .x = 7, .z = -1 },
        .{ .x = 8, .z = -1 },  .{ .x = 9, .z = -1 },  .{ .x = 10, .z = -1 },
        .{ .x = 11, .z = -1 }, .{ .x = 12, .z = -1 }, .{ .x = 13, .z = -1 },
        .{ .x = 14, .z = -1 },
    });

    iterator = cellLineIterator(CellType, .{ .x = 3, .z = -3 }, .{ .x = 43, .z = -11 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 0, .z = 0 },  .{ .x = 1, .z = 0 },  .{ .x = 2, .z = 0 },
        .{ .x = 2, .z = -1 }, .{ .x = 3, .z = -1 }, .{ .x = 4, .z = -1 },
        .{ .x = 5, .z = -1 }, .{ .x = 6, .z = -1 }, .{ .x = 7, .z = -1 },
        .{ .x = 7, .z = -2 }, .{ .x = 8, .z = -2 },
    });

    // Previous test in reverse direction.
    iterator = cellLineIterator(CellType, .{ .x = 43, .z = -11 }, .{ .x = 3, .z = -3 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 8, .z = -2 }, .{ .x = 7, .z = -2 }, .{ .x = 7, .z = -1 },
        .{ .x = 6, .z = -1 }, .{ .x = 5, .z = -1 }, .{ .x = 4, .z = -1 },
        .{ .x = 3, .z = -1 }, .{ .x = 2, .z = -1 }, .{ .x = 2, .z = 0 },
        .{ .x = 1, .z = 0 },  .{ .x = 0, .z = 0 },
    });

    // 3x3 diagonal traversal in all directions.
    iterator = cellLineIterator(CellType, .{ .x = 15, .z = 15 }, .{ .x = 25, .z = 25 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 3 }, .{ .x = 4, .z = 3 }, .{ .x = 4, .z = 4 },
        .{ .x = 5, .z = 4 }, .{ .x = 5, .z = 5 },
    });
    iterator = cellLineIterator(CellType, .{ .x = 25, .z = 25 }, .{ .x = 15, .z = 15 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 5, .z = 5 }, .{ .x = 4, .z = 5 }, .{ .x = 4, .z = 4 },
        .{ .x = 3, .z = 4 }, .{ .x = 3, .z = 3 },
    });
    iterator = cellLineIterator(CellType, .{ .x = 25, .z = 15 }, .{ .x = 15, .z = 25 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 5, .z = 3 }, .{ .x = 4, .z = 3 }, .{ .x = 4, .z = 4 },
        .{ .x = 3, .z = 4 }, .{ .x = 3, .z = 5 },
    });
    iterator = cellLineIterator(CellType, .{ .x = 15, .z = 25 }, .{ .x = 25, .z = 15 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 5 }, .{ .x = 4, .z = 5 }, .{ .x = 4, .z = 4 },
        .{ .x = 5, .z = 4 }, .{ .x = 5, .z = 3 },
    });

    // 3x4 diagonal traversal.
    iterator = cellLineIterator(CellType, .{ .x = 15, .z = 15 }, .{ .x = 25, .z = 30 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = 3, .z = 3 }, .{ .x = 3, .z = 4 }, .{ .x = 4, .z = 4 },
        .{ .x = 4, .z = 5 }, .{ .x = 5, .z = 5 }, .{ .x = 5, .z = 6 },
    });

    // Long line downwards.
    iterator = cellLineIterator(CellType, .{ .x = -6, .z = -3 }, .{ .x = -10.001, .z = 46 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = -1, .z = 0 }, .{ .x = -1, .z = 1 }, .{ .x = -1, .z = 2 },
        .{ .x = -1, .z = 3 }, .{ .x = -1, .z = 4 }, .{ .x = -1, .z = 5 },
        .{ .x = -1, .z = 6 }, .{ .x = -1, .z = 7 }, .{ .x = -1, .z = 8 },
        .{ .x = -1, .z = 9 }, .{ .x = -1, .z = 9 }, .{ .x = -2, .z = 9 },
    });
    // Long line upwards.
    iterator = cellLineIterator(CellType, .{ .x = -10.001, .z = 46 }, .{ .x = -6, .z = -3 });
    try testCellLineIterator(cell_size, &iterator, &[_]CellType{
        .{ .x = -2, .z = 9 }, .{ .x = -1, .z = 9 }, .{ .x = -1, .z = 8 },
        .{ .x = -1, .z = 7 }, .{ .x = -1, .z = 6 }, .{ .x = -1, .z = 5 },
        .{ .x = -1, .z = 4 }, .{ .x = -1, .z = 3 }, .{ .x = -1, .z = 2 },
        .{ .x = -1, .z = 1 }, .{ .x = -1, .z = 0 },
    });
}

test "SpatialGrid: const straight line iterator" {
    var grid = SpatialGrid.create(std.testing.allocator);
    defer grid.destroy();

    const factor = @as(f32, @floatFromInt(grid_cell_side_length)) * 0.4;
    _ = try grid.insertIntoArea(1, .{
        .min = .{ .x = -16 * factor, .z = -19 * factor },
        .max = .{ .x = -7 * factor, .z = -3 * factor },
    });
    _ = try grid.insertIntoArea(2, .{
        .min = .{ .x = -12 * factor, .z = 7 * factor },
        .max = .{ .x = -1 * factor, .z = 13 * factor },
    });
    _ = try grid.insertIntoArea(3, .{
        .min = .{ .x = 2 * factor, .z = 7 * factor },
        .max = .{ .x = 8 * factor, .z = 13 * factor },
    });
    _ = try grid.insertIntoArea(4, .{
        .min = .{ .x = 7 * factor, .z = 2 * factor },
        .max = .{ .x = 13 * factor, .z = 7 * factor },
    });
    _ = try grid.insertIntoArea(5, .{
        .min = .{ .x = 8 * factor, .z = -13 * factor },
        .max = .{ .x = 13 * factor, .z = -1 * factor },
    });
    _ = try grid.insertIntoArea(6, .{
        .min = .{ .x = 3 * factor, .z = -13 * factor },
        .max = .{ .x = 13 * factor, .z = -1 * factor },
    });
    _ = try grid.insertIntoArea(7, .{
        .min = .{ .x = 3 * factor, .z = -13 * factor },
        .max = .{ .x = 13 * factor, .z = -1 * factor },
    });

    var iterator = grid.straightLineIterator(
        .{ .x = 0 * factor, .z = 0 * factor },
        .{ .x = 0 * factor, .z = 0 * factor },
    );
    try expect(iterator.next() == null);
    iterator = grid.straightLineIterator(
        .{ .x = -7000 * factor, .z = 3000 * factor },
        .{ .x = -7000 * factor, .z = 3000 * factor },
    );
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = -9 * factor, .z = -4.5 * factor },
        .{ .x = 12 * factor, .z = 10 * factor },
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
        .{ .x = -2 * factor, .z = -2 * factor },
        .{ .x = 12 * factor, .z = 15 * factor },
    );
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 4);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next().? == 3);
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = -7 * factor, .z = 7 * factor },
        .{ .x = 3 * factor, .z = -1 * factor },
    );
    try expect(iterator.next().? == 2);
    try expect(iterator.next().? == 2);
    try expect(iterator.next().? == 6);
    try expect(iterator.next().? == 7);
    try expect(iterator.next() == null);

    iterator = grid.straightLineIterator(
        .{ .x = 0 * factor, .z = 0 * factor },
        .{ .x = 3 * factor, .z = -1 * factor },
    );
    try expect(iterator.next().? == 6);
    try expect(iterator.next().? == 7);
    try expect(iterator.next() == null);
}
