//! Contains functions for rendering text. Text characters are rendered as billboards and will
//! rotate around the Y axis towards the camera. The characters ' ' and '\n' affect the formatting
//! of the rendered text. All strings passed to these functions are assumed to contain valid UTF-8.
const std = @import("std");
const BillboardData = @import("rendering.zig").BillboardData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const Color = @import("util.zig").Color;
const Vector3d = @import("math.zig").Vector3d;

pub const TextSegment = struct {
    color: Color,
    /// Can be formatted with ' ' and '\n'.
    text: []const u8,
};

/// Returns the amount of billboards required to render the given text segments.
pub fn getBillboardCount(segments: []const TextSegment) usize {
    return getInfo(segments).required_billboard_count;
}

pub const Dimensions = struct {
    width: f32,
    height: f32,
};

pub fn getTextBlockDimensions(
    segments: []const TextSegment,
    character_size: f32,
    spritesheet: SpriteSheetTexture,
) Dimensions {
    const info = getInfo(segments);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const longest_line = @as(f32, @floatFromInt(info.codepoint_count_in_longest_line));
    const line_count = @as(f32, @floatFromInt(1 + info.newline_count));

    const horizontal_spaces = 1 + longest_line;
    const vertical_spaces = 1 + line_count;
    return .{
        .width = longest_line * character_size + horizontal_spaces * font_letter_spacing.horizontal,
        .height = line_count * character_size + vertical_spaces * font_letter_spacing.vertical,
    };
}

pub fn populateBillboardData(
    segments: []const TextSegment,
    center_position: Vector3d,
    /// Size is specified in game-world units.
    character_size: f32,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    populateBillboardDataRaw(
        segments,
        center_position,
        getOffsetToTopLeftCorner(segments, character_size, spritesheet),
        character_size,
        false,
        true,
        spritesheet,
        out,
    );
}

/// Text size is specified in screen pixels and will preserve its exact size independently from its
/// distance to the camera.
pub fn populateBillboardDataExactPixelSize(
    segments: []const TextSegment,
    center_position: Vector3d,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    populateBillboardDataRaw(
        segments,
        center_position,
        getOffsetToTopLeftCorner(
            segments,
            @floatFromInt(character_size_pixels),
            spritesheet,
        ),
        @floatFromInt(character_size_pixels),
        true,
        true,
        spritesheet,
        out,
    );
}

/// Fill the given billboard data slice with the data needed to render text with
/// BillboardRenderer.render2d().
pub fn populateBillboardData2d(
    segments: []const TextSegment,
    /// Top left corner of the first character.
    screen_position_x: u16,
    screen_position_y: u16,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    const position = .{
        .x = @as(f32, @floatFromInt(screen_position_x)),
        .y = @as(f32, @floatFromInt(screen_position_y)),
        .z = 0,
    };
    const offset_to_top_left_corner = .{ .x = 0, .y = 0, .z = 0 };
    populateBillboardDataRaw(
        segments,
        position,
        offset_to_top_left_corner,
        @floatFromInt(character_size_pixels),
        false,
        false,
        spritesheet,
        out,
    );
}

/// Retokenize the given text segments to ensure that lines approximate the specified length. Empty
/// lines can be specified explicitly by either "\n\n" or "\\n". The returned segments must be freed
/// with freeTextSegments().
pub fn reflowTextBlock(
    allocator: std.mem.Allocator,
    segments: []const TextSegment,
    new_line_length: usize,
) ![]TextSegment {
    var result: []TextSegment = &.{};
    errdefer freeTextSegments(allocator, result);

    var current_line_length: usize = 0;
    for (segments) |segment| {
        const patched_segment = try injectNewlineTokens(segment.text, allocator);
        defer allocator.free(patched_segment);

        var token_iterator = std.mem.tokenizeAny(u8, patched_segment, "\n ");
        while (token_iterator.next()) |token| {
            const token_length = try std.unicode.utf8CountCodepoints(token);
            const whitespace = " ";

            if (std.mem.eql(u8, token, "\\n")) {
                result = try appendTextSegment(allocator, result, "\n", segment.color);
                result = try appendTextSegment(allocator, result, "\n", segment.color);
                current_line_length = 0;
            } else if (current_line_length == 0) {
                result = try appendTextSegment(allocator, result, token, segment.color);
                current_line_length = token_length;
            } else if (current_line_length + whitespace.len + token_length > new_line_length) {
                result = try appendTextSegment(allocator, result, "\n", segment.color);
                result = try appendTextSegment(allocator, result, token, segment.color);
                current_line_length = token_length;
            } else {
                result = try appendTextSegment(allocator, result, whitespace, segment.color);
                result = try appendTextSegment(allocator, result, token, segment.color);
                current_line_length += whitespace.len + token_length;
            }
        }
    }

    return result;
}

/// Release all text segments and free the given slice.
pub fn freeTextSegments(allocator: std.mem.Allocator, segments: []TextSegment) void {
    for (segments) |segment| {
        allocator.free(segment.text);
    }
    allocator.free(segments);
}

/// Return enough subsegments to contain not more than the given amount of codepoints. Returned copy
/// must be freed with freeTextSegments(). Newlines count as 1 codepoint.
pub fn truncateTextSegments(
    allocator: std.mem.Allocator,
    segments: []const TextSegment,
    max_total_codepoints: usize,
) ![]TextSegment {
    var result: []TextSegment = &.{};
    errdefer freeTextSegments(allocator, result);

    var remaining_codepoints = max_total_codepoints;
    for (segments) |segment| {
        if (remaining_codepoints == 0) {
            break;
        }
        const codepoints_max = @min(
            remaining_codepoints,
            try std.unicode.utf8CountCodepoints(segment.text),
        );

        var current_segment_bytes: usize = 0;
        var current_segment_codepoints: usize = 0;
        var codepoint_iterator = std.unicode.Utf8View.initUnchecked(segment.text).iterator();
        while (codepoint_iterator.nextCodepointSlice()) |slice| {
            if (current_segment_codepoints == codepoints_max) {
                break;
            }
            current_segment_codepoints += 1;
            current_segment_bytes += slice.len;
        }

        result = try appendTextSegment(
            allocator,
            result,
            segment.text[0..current_segment_bytes],
            segment.color,
        );
        remaining_codepoints -= current_segment_codepoints;
    }

    return result;
}

const TextSegmentInfo = struct {
    newline_count: usize,
    required_billboard_count: usize,
    codepoint_count_in_longest_line: usize,
};

fn getInfo(segments: []const TextSegment) TextSegmentInfo {
    var result = TextSegmentInfo{
        .newline_count = 0,
        .required_billboard_count = 0,
        .codepoint_count_in_longest_line = 0,
    };

    var codepoints_in_current_line: usize = 0;
    for (segments) |segment| {
        var iterator = std.unicode.Utf8View.initUnchecked(segment.text).iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                result.newline_count = result.newline_count + 1;
                result.codepoint_count_in_longest_line = @max(
                    result.codepoint_count_in_longest_line,
                    codepoints_in_current_line,
                );
                codepoints_in_current_line = 0;
            } else if (codepoint == ' ') {
                codepoints_in_current_line = codepoints_in_current_line + 1;
            } else {
                codepoints_in_current_line = codepoints_in_current_line + 1;
                result.required_billboard_count = result.required_billboard_count + 1;
            }
        }
    }
    result.codepoint_count_in_longest_line = @max(
        result.codepoint_count_in_longest_line,
        codepoints_in_current_line,
    );

    return result;
}

fn getOffsetToTopLeftCorner(
    segments: []const TextSegment,
    character_size: f32,
    spritesheet: SpriteSheetTexture,
) Vector3d {
    const info = getInfo(segments);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const half_sizes = .{
        .w = (character_size + font_letter_spacing.horizontal) / 2,
        .h = (character_size + font_letter_spacing.vertical) / 2,
    };
    return .{
        .x = -@as(f32, @floatFromInt(info.codepoint_count_in_longest_line)) * half_sizes.w,
        .y = @as(f32, @floatFromInt(info.newline_count + 1)) * half_sizes.h,
        .z = 0,
    };
}

fn flip(value: f32, y_axis_points_upwards: bool) f32 {
    if (y_axis_points_upwards) {
        return -value;
    }
    return value;
}

fn populateBillboardDataRaw(
    segments: []const TextSegment,
    position: Vector3d,
    offset_to_top_left_corner: Vector3d,
    /// Depending on the rendering method, the character size can be either relative to game-world
    /// units or to screen pixels. See render() and render2d() in BillboardRenderer.
    character_size: f32,
    /// True if the billboard should have a fixed pixel size independently from its distance.
    preserve_exact_pixel_size: bool,
    y_axis_points_upwards: bool,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    // Billboard positions usually specify their center. Offsets are applied to align the top left
    // corner of the text block.
    const y_offset = flip(character_size, y_axis_points_upwards);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const offset_increment = Vector3d{
        .x = character_size + font_letter_spacing.horizontal,
        .y = y_offset + flip(font_letter_spacing.vertical, y_axis_points_upwards),
        .z = undefined,
    };
    const start_position = offset_to_top_left_corner.add(.{
        .x = font_letter_spacing.horizontal,
        .y = font_letter_spacing.vertical,
        .z = 0,
    });
    var offset = start_position.add(.{
        .x = character_size / 2,
        .y = y_offset / 2,
        .z = 0,
    });

    var index: usize = 0;
    for (segments) |segment| {
        var codepoint_iterator = std.unicode.Utf8View.initUnchecked(segment.text).iterator();
        while (codepoint_iterator.nextCodepoint()) |codepoint| {
            if (codepoint == ' ') {
                offset.x = offset.x + offset_increment.x;
            } else if (codepoint == '\n') {
                offset.x = start_position.x + character_size / 2;
                offset.y = offset.y + offset_increment.y;
            } else {
                const source = spritesheet.getFontCharacterTexcoords(codepoint);
                out[index] = .{
                    .position = .{ .x = position.x, .y = position.y, .z = position.z },
                    .size = .{ .w = character_size, .h = character_size },
                    .offset_from_origin = .{ .x = offset.x, .y = offset.y },
                    .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
                    .tint = .{ .r = segment.color.r, .g = segment.color.g, .b = segment.color.b },
                    .preserve_exact_pixel_size = if (preserve_exact_pixel_size) 1 else 0,
                };
                offset.x = offset.x + offset_increment.x;
                index = index + 1;
            }
        }
    }
}

/// Reallocates the given text segments and appends a copy of the specified colored text.
fn appendTextSegment(
    allocator: std.mem.Allocator,
    segments: []TextSegment,
    text: []const u8,
    color: Color,
) ![]TextSegment {
    const text_copy = try allocator.dupe(u8, text);
    errdefer allocator.free(text_copy);

    var result = try allocator.realloc(segments, segments.len + 1);
    result[result.len - 1].text = text_copy;
    result[result.len - 1].color = color;
    return result;
}

/// Replaces all occurrences of "\n\n" and "\\n" in the given string with " \\n ".
fn injectNewlineTokens(segment: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var step1 = try allocator.alloc(u8, std.mem.replacementSize(u8, segment, "\n\n", "\\n"));
    defer allocator.free(step1);
    _ = std.mem.replace(u8, segment, "\n\n", "\\n", step1);

    var step2 = try allocator.alloc(u8, std.mem.replacementSize(u8, step1, "\\n", " \\n "));
    _ = std.mem.replace(u8, step1, "\\n", " \\n ", step2);
    return step2;
}
