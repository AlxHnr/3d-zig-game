//! Contains functions for rendering text. Text characters are rendered as billboards and will
//! rotate around the Y axis towards the camera. The characters ' ' and '\n' affect the formatting
//! of the rendered text. All strings passed to these functions are assumed to contain valid UTF-8.
//! TODO: Add padding between lines and characters
//! TODO: Fix kerning of some characters
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

pub fn populateBillboardData(
    text_segments: []const TextSegment,
    center_position: Vector3d,
    /// Size is specified in game-world units.
    character_size: f32,
    sprite_sheet_texture: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    const info = getInfo(text_segments);
    const half_size = character_size / 2;
    const offset_to_top_left_corner = .{
        .x = -@as(f32, info.codepoint_count_in_longest_line) * half_size,
        .y = @as(f32, info.newline_count + 1) * half_size,
        .z = 0,
    };
    populateBillboardDataRaw(
        text_segments,
        center_position,
        offset_to_top_left_corner,
        character_size,
        true,
        sprite_sheet_texture,
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
    sprite_sheet_texture: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    const position = .{
        .x = @as(f32, screen_position_x),
        .y = @as(f32, screen_position_y),
        .z = 0,
    };
    const offset_to_top_left_corner = .{ .x = 0, .y = 0, .z = 0 };
    populateBillboardDataRaw(
        text_segments,
        position,
        offset_to_top_left_corner,
        @floatCast(character_size_pixels),
        false,
        sprite_sheet_texture,
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
                result.codepoint_count_in_longest_line = std.math.max(
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
    result.codepoint_count_in_longest_line = std.math.max(
        result.codepoint_count_in_longest_line,
        codepoints_in_current_line,
    );

    return result;
}

fn populateBillboardDataRaw(
    text_segments: []const TextSegment,
    position: Vector3d,
    offset_to_top_left_corner: Vector3d,
    /// Depending on the rendering method, the character size can be either relative to game-world
    /// units or to screen pixels. See render() and render2d() in BillboardRenderer.
    character_size: f32,
    y_axis_points_upwards: bool,
    sprite_sheet_texture: SpriteSheetTexture,
    /// Must have enough capacity to store all billboards. See getBillboardCount().
    out: []BillboardData,
) void {
    // Billboard positions usually specify their center. Offsets are applied to align the top left
    // corner of the text block.
    const y_offset = if (y_axis_points_upwards) -character_size else character_size;
    const offset_increment = Vector3d{ .x = character_size, .y = y_offset, .z = undefined };
    var offset = offset_to_top_left_corner.add(.{
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
                offset.x = offset_to_top_left_corner.x + character_size / 2;
                offset.y = offset.y + offset_increment.y;
            } else {
                const source = sprite_sheet_texture.getFontCharacterTexcoords(codepoint);
                out[index] = .{
                    .position = .{
                        .x = position.x,
                        .y = position.y + offset.y,
                        .z = position.z,
                    },
                    .size = .{ .w = character_size, .h = character_size },
                    .x_offset_from_origin = offset.x,
                    .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
                    .tint = .{ .r = segment.color.r, .g = segment.color.g, .b = segment.color.b },
                };
                offset.x = offset.x + offset_increment.x;
                index = index + 1;
            }
        }
    }
}
