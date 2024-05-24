//! Contains functions for rendering text using individual letter sprites. The characters ' ' and
//! '\n' affect the formatting of the rendered text. All strings passed to these functions are
//! assumed to contain valid UTF-8.

const Color = @import("util.zig").Color;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const Vector3d = math.Vector3d;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const std = @import("std");

pub const TextSegment = struct {
    color: Color,
    /// Can be formatted with ' ' and '\n'.
    text: []const u8,
};

/// Returns the amount of sprites required to render the given text segments.
pub fn getSpriteCount(segments: []const TextSegment) usize {
    return getInfo(segments).required_sprite_count;
}

pub const Dimensions = struct {
    width: math.Fix32,
    height: math.Fix32,
};

pub fn getTextBlockDimensions(
    segments: []const TextSegment,
    character_size: math.Fix32,
    spritesheet: SpriteSheetTexture,
) Dimensions {
    const info = getInfo(segments);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const longest_line = fp(info.codepoint_count_in_longest_line);
    const line_count = fp(1 + info.newline_count);

    const horizontal_spaces = fp(1).add(longest_line);
    const vertical_spaces = fp(1).add(line_count);
    return .{
        .width = longest_line.mul(character_size)
            .add(horizontal_spaces.mul(font_letter_spacing.horizontal)),
        .height = line_count.mul(character_size)
            .add(vertical_spaces.mul(font_letter_spacing.vertical)),
    };
}

/// Renders 2d strings in 3d space.
pub fn populateBillboardData(
    segments: []const TextSegment,
    center_position: Vector3d,
    /// Size is specified in game-world units.
    character_size: math.Fix32,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all sprites. See getSpriteCount().
    out: []SpriteData,
) void {
    populateSpriteDataRaw(
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

/// Renders 2d strings in 3d space. Text size is specified in screen pixels and will preserve its
/// exact size independent from its distance to the camera.
pub fn populateBillboardDataExactPixelSize(
    segments: []const TextSegment,
    center_position: Vector3d,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all sprites. See getSpriteCount().
    out: []SpriteData,
) void {
    populateBillboardDataExactPixelSizeWithOffset(
        segments,
        center_position,
        0,
        0,
        character_size_pixels,
        spritesheet,
        out,
    );
}

/// Like `populateBillboardDataExactPixelSize()`, but takes an extra offset in pixels relative to
/// the rendered center of the text block on the screen. This can be used for adjustments.
pub fn populateBillboardDataExactPixelSizeWithOffset(
    segments: []const TextSegment,
    center_position: Vector3d,
    pixel_offset_from_center_x: i16,
    pixel_offset_from_center_y: i16,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all sprites. See getSpriteCount().
    out: []SpriteData,
) void {
    const top_left_corner = getOffsetToTopLeftCorner(
        segments,
        fp(character_size_pixels),
        spritesheet,
    ).add(.{
        .x = fp(pixel_offset_from_center_x),
        .y = fp(pixel_offset_from_center_y).neg(),
        .z = fp(0),
    });
    populateSpriteDataRaw(
        segments,
        center_position,
        top_left_corner,
        fp(character_size_pixels),
        true,
        true,
        spritesheet,
        out,
    );
}

/// Fill the given sprite data slice with the data needed to render 2d text in screen space with
/// `rendering.SpriteRenderer`.
pub fn populateSpriteData(
    segments: []const TextSegment,
    /// Top left corner of the first character.
    screen_position_x: u16,
    screen_position_y: u16,
    character_size_pixels: u16,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all sprites. See getSpriteCount().
    out: []SpriteData,
) void {
    const position = .{
        .x = fp(screen_position_x),
        .y = fp(screen_position_y),
        .z = fp(0),
    };
    const offset_to_top_left_corner = .{ .x = fp(0), .y = fp(0), .z = fp(0) };
    populateSpriteDataRaw(
        segments,
        position,
        offset_to_top_left_corner,
        fp(character_size_pixels),
        false,
        false,
        spritesheet,
        out,
    );
}

/// Retokenize the given text segments to ensure that lines approximate the specified length. Empty
/// lines can be specified explicitly by either "\n\n" or "\\n". Returns a slice into the given
/// reusable text buffer.
pub fn reflowTextBlock(
    reusable_buffer: *ReusableBuffer,
    segments: []const TextSegment,
    new_line_length: usize,
) ![]const TextSegment {
    reusable_buffer.segments.clearRetainingCapacity();
    reusable_buffer.buffer.clearRetainingCapacity();

    var current_line_length: usize = 0;
    for (segments) |segment| {
        const patched_segment = try injectNewlineTokens(segment.text, &reusable_buffer.helpers);

        var token_iterator = std.mem.tokenizeAny(u8, patched_segment, "\n ");
        while (token_iterator.next()) |token| {
            const token_length = try std.unicode.utf8CountCodepoints(token);
            const whitespace = " ";

            if (std.mem.eql(u8, token, "\\n")) {
                try appendTextSegment(reusable_buffer, "\n", segment.color);
                try appendTextSegment(reusable_buffer, "\n", segment.color);
                current_line_length = 0;
            } else if (current_line_length == 0) {
                try appendTextSegment(reusable_buffer, token, segment.color);
                current_line_length = token_length;
            } else if (current_line_length + whitespace.len + token_length > new_line_length) {
                try appendTextSegment(reusable_buffer, "\n", segment.color);
                try appendTextSegment(reusable_buffer, token, segment.color);
                current_line_length = token_length;
            } else {
                try appendTextSegment(reusable_buffer, whitespace, segment.color);
                try appendTextSegment(reusable_buffer, token, segment.color);
                current_line_length += whitespace.len + token_length;
            }
        }
    }

    reusable_buffer.fixInvalidatedSegmentsAfterArrayGrowth();
    return reusable_buffer.segments.items;
}

pub const ReusableBuffer = struct {
    segments: std.ArrayList(TextSegment),
    buffer: std.ArrayList(u8),
    helpers: [2]std.ArrayList(u8),

    pub fn create(allocator: std.mem.Allocator) ReusableBuffer {
        return .{
            .segments = std.ArrayList(TextSegment).init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
            .helpers = .{
                std.ArrayList(u8).init(allocator),
                std.ArrayList(u8).init(allocator),
            },
        };
    }

    pub fn destroy(self: *ReusableBuffer) void {
        self.helpers[1].deinit();
        self.helpers[0].deinit();
        self.buffer.deinit();
        self.segments.deinit();
    }

    fn fixInvalidatedSegmentsAfterArrayGrowth(self: *ReusableBuffer) void {
        var index: usize = 0;
        for (self.segments.items) |*segment| {
            segment.text = self.buffer.items[index..][0..segment.text.len];
            index += segment.text.len;
        }
    }
};

/// Return enough subsegments to contain not more than the specified amount of codepoints. Returns a
/// slice into the given reusable text buffer. Newlines count as 1 codepoint.
pub fn truncateTextSegments(
    reusable_buffer: *ReusableBuffer,
    segments: []const TextSegment,
    max_total_codepoints: usize,
) ![]const TextSegment {
    reusable_buffer.segments.clearRetainingCapacity();
    reusable_buffer.buffer.clearRetainingCapacity();

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

        try appendTextSegment(reusable_buffer, segment.text[0..current_segment_bytes], segment.color);
        remaining_codepoints -= current_segment_codepoints;
    }

    reusable_buffer.fixInvalidatedSegmentsAfterArrayGrowth();
    return reusable_buffer.segments.items;
}

const TextSegmentInfo = struct {
    newline_count: usize,
    required_sprite_count: usize,
    codepoint_count_in_longest_line: usize,
};

fn getInfo(segments: []const TextSegment) TextSegmentInfo {
    var result = TextSegmentInfo{
        .newline_count = 0,
        .required_sprite_count = 0,
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
                result.required_sprite_count = result.required_sprite_count + 1;
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
    character_size: math.Fix32,
    spritesheet: SpriteSheetTexture,
) Vector3d {
    const info = getInfo(segments);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const half_sizes = .{
        .w = character_size.add(font_letter_spacing.horizontal).div(fp(2)),
        .h = character_size.add(font_letter_spacing.vertical).div(fp(2)),
    };
    return .{
        .x = fp(info.codepoint_count_in_longest_line).mul(half_sizes.w).neg(),
        .y = fp(info.newline_count + 1).mul(half_sizes.h),
        .z = fp(0),
    };
}

fn flip(value: math.Fix32, y_axis_points_upwards: bool) math.Fix32 {
    if (y_axis_points_upwards) {
        return value.neg();
    }
    return value;
}

fn populateSpriteDataRaw(
    segments: []const TextSegment,
    position: Vector3d,
    offset_to_top_left_corner: Vector3d,
    /// Depending on the renderer, the character size can be either relative to game-world units or
    /// to screen pixels. See `SpriteRenderer` and `BillboardRenderer`.
    character_size: math.Fix32,
    /// True if the sprite should have a fixed pixel size independent from its distance.
    preserve_exact_pixel_size: bool,
    y_axis_points_upwards: bool,
    spritesheet: SpriteSheetTexture,
    /// Must have enough capacity to store all sprites. See getSpriteCount().
    out: []SpriteData,
) void {
    // Sprite positions specify their center. Offsets are applied to align the top left corner of
    // the text block.
    const y_offset = flip(character_size, y_axis_points_upwards);
    const font_letter_spacing = spritesheet.getFontLetterSpacing(character_size);
    const offset_increment = .{
        .x = character_size.add(font_letter_spacing.horizontal),
        .y = y_offset.add(flip(font_letter_spacing.vertical, y_axis_points_upwards)),
        .z = undefined,
    };
    const start_position = offset_to_top_left_corner.add(.{
        .x = font_letter_spacing.horizontal,
        .y = font_letter_spacing.vertical,
        .z = fp(0),
    });
    var offset = start_position.add(.{
        .x = character_size.div(fp(2)),
        .y = y_offset.div(fp(2)),
        .z = fp(0),
    });

    var index: usize = 0;
    for (segments) |segment| {
        var codepoint_iterator = std.unicode.Utf8View.initUnchecked(segment.text).iterator();
        while (codepoint_iterator.nextCodepoint()) |codepoint| {
            if (codepoint == ' ') {
                offset.x = offset.x.add(offset_increment.x);
            } else if (codepoint == '\n') {
                offset.x = start_position.x.add(character_size.div(fp(2)));
                offset.y = offset.y.add(offset_increment.y);
            } else {
                const source = spritesheet.getFontCharacterTexcoords(codepoint);
                out[index] = .{
                    .position = .{
                        .x = position.x.convertTo(f32),
                        .y = position.y.convertTo(f32),
                        .z = position.z.convertTo(f32),
                    },
                    .size = .{
                        .w = character_size.convertTo(f32),
                        .h = character_size.convertTo(f32),
                    },
                    .offset_from_origin = .{
                        .x = offset.x.convertTo(f32),
                        .y = offset.y.convertTo(f32),
                    },
                    .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
                    .tint = .{ .r = segment.color.r, .g = segment.color.g, .b = segment.color.b },
                    .preserve_exact_pixel_size = if (preserve_exact_pixel_size) 1 else 0,
                };
                offset.x = offset.x.add(offset_increment.x);
                index = index + 1;
            }
        }
    }
}

/// Append the specified text segments to the given reusable buffer. May invalidate the segments in
/// the given reusable buffer, see `ReusableBuffer.fixInvalidatedSegmentsAfterArrayGrowth()`.
fn appendTextSegment(
    reusable_buffer: *ReusableBuffer,
    text: []const u8,
    color: Color,
) !void {
    const text_start = reusable_buffer.buffer.items.len;
    try reusable_buffer.segments.ensureUnusedCapacity(1);
    try reusable_buffer.buffer.ensureUnusedCapacity(text.len);

    reusable_buffer.buffer.appendSliceAssumeCapacity(text);
    reusable_buffer.segments.appendAssumeCapacity(.{
        .text = reusable_buffer.buffer.items[text_start..],
        .color = color,
    });
}

/// Replace all occurrences of "\n\n" and "\\n" in the given string with " \\n ". Returns a slice
/// pointing into the given helper buffers.
fn injectNewlineTokens(segment: []const u8, helpers: *[2]std.ArrayList(u8)) ![]const u8 {
    try helpers[0].resize(std.mem.replacementSize(u8, segment, "\n\n", "\\n"));
    _ = std.mem.replace(u8, segment, "\n\n", "\\n", helpers[0].items);

    try helpers[1].resize(std.mem.replacementSize(u8, helpers[0].items, "\\n", " \\n "));
    _ = std.mem.replace(u8, helpers[0].items, "\\n", " \\n ", helpers[1].items);
    return helpers[1].items;
}
