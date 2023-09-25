//! Contains functions for rendering text. Text characters are rendered as billboards and will
//! rotate around the Y axis towards the camera. The characters ' ' and '\n' affect the formatting
//! of the rendered text. All strings passed to these functions are assumed to contain valid UTF-8.
const std = @import("std");
const BillboardData = @import("rendering.zig").BillboardRenderer.BillboardData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const Color = @import("util.zig").Color;
const Vector3d = @import("math.zig").Vector3d;

pub const TextSegment = struct {
    color: Color,
    /// Can be formatted with ' ' and '\n'.
    text: []const u8,
};

/// Returns the amount of billboards required to render the given text segments.
pub fn getBillboardCount(text_segments: []const TextSegment) usize {
    return getInfo(text_segments).required_billboard_count;
}

pub const Dimensions = struct {
    width: f32,
    height: f32,
};

pub fn getTextBlockDimensions(
    text_segments: []const TextSegment,
    character_size: f32,
    spritesheet: SpriteSheetTexture,
) Dimensions {
    const info = getInfo(text_segments);
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
    text_segments: []const TextSegment,
    center_position: Vector3d,
    /// Size is specified in game-world units.
    character_size: f32,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    populateBillboardDataRaw(
        text_segments,
        center_position,
        getOffsetToTopLeftCorner(text_segments, character_size, spritesheet),
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
    text_segments: []const TextSegment,
    center_position: Vector3d,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    populateBillboardDataRaw(
        text_segments,
        center_position,
        getOffsetToTopLeftCorner(
            text_segments,
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
    text_segments: []const TextSegment,
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
        text_segments,
        position,
        offset_to_top_left_corner,
        @floatFromInt(character_size_pixels),
        false,
        false,
        spritesheet,
        out,
    );
}

const TextSegmentInfo = struct {
    newline_count: usize,
    required_billboard_count: usize,
    codepoint_count_in_longest_line: usize,
};

fn getInfo(text_segments: []const TextSegment) TextSegmentInfo {
    var result = TextSegmentInfo{
        .newline_count = 0,
        .required_billboard_count = 0,
        .codepoint_count_in_longest_line = 0,
    };

    var codepoints_in_current_line: usize = 0;
    for (text_segments) |segment| {
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
    text_segments: []const TextSegment,
    character_size: f32,
    spritesheet: SpriteSheetTexture,
) Vector3d {
    const info = getInfo(text_segments);
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
    text_segments: []const TextSegment,
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
    for (text_segments) |segment| {
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
