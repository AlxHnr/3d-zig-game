const BillboardData = @import("rendering.zig").BillboardRenderer.BillboardData;
const ScreenDimensions = @import("math.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");

pub const ImageWithText = struct {
    sprite_texcoords: SpriteSheetTexture.TextureCoordinates,
    sprite_on_screen_dimensions: struct { w: f32, h: f32 },
    /// Has to be applied twice, both for left/right and top/bottom.
    sprite_on_screen_spacing: struct { horizontal: f32, vertical: f32 },
    font_size: f32,

    pub fn create(
        sprite: SpriteSheetTexture.SpriteId,
        /// 1 means the original size in pixels.
        sprite_scale: u16,
        sprite_sheet: SpriteSheetTexture,
        /// 1 means the original character size in pixels.
        text_scale: u8,
    ) ImageWithText {
        const dimensions = sprite_sheet.getSpriteDimensionsInPixels(sprite);
        return .{
            .sprite_texcoords = sprite_sheet.getSpriteTexcoords(sprite),
            .sprite_on_screen_dimensions = .{
                .w = @as(f32, @floatFromInt(dimensions.w * sprite_scale)),
                .h = @as(f32, @floatFromInt(dimensions.h * sprite_scale)),
            },
            .sprite_on_screen_spacing = .{
                // 2 Has been picked by trial and error to improve padding.
                .horizontal = 2 * @as(f32, @floatFromInt(sprite_scale)),
                .vertical = 2 * @as(f32, @floatFromInt(sprite_scale)),
            },
            .font_size = @as(f32, @floatFromInt(sprite_sheet.getFontSizeMultiple(text_scale))),
        };
    }

    pub fn getBillboardCount(_: ImageWithText, segments: []const text_rendering.TextSegment) usize {
        return 1 + // Image.
            text_rendering.getBillboardCount(segments);
    }

    pub fn getDimensionsInPixels(
        self: ImageWithText,
        segments: []const text_rendering.TextSegment,
        sprite_sheet: SpriteSheetTexture,
    ) ScreenDimensions {
        return getTotalDimensions(
            self.getSpriteDimensionsInPixels(),
            text_rendering.getTextBlockDimensions(segments, self.font_size, sprite_sheet),
        );
    }

    pub fn populateBillboardData(
        self: ImageWithText,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        sprite_sheet: SpriteSheetTexture,
        segments: []const text_rendering.TextSegment,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        const sprite_dimensions = self.getSpriteDimensionsInPixels();
        const text_dimensions =
            text_rendering.getTextBlockDimensions(segments, self.font_size, sprite_sheet);
        const total_dimensions = getTotalDimensions(sprite_dimensions, text_dimensions);

        out[0] = .{
            .position = .{
                .x = @as(f32, @floatFromInt(screen_position_x + sprite_dimensions.width / 2)),
                .y = @as(f32, @floatFromInt(screen_position_y + total_dimensions.height / 2)),
                .z = 0,
            },
            .size = .{
                .w = self.sprite_on_screen_dimensions.w,
                .h = self.sprite_on_screen_dimensions.h,
            },
            .source_rect = .{
                .x = self.sprite_texcoords.x,
                .y = self.sprite_texcoords.y,
                .w = self.sprite_texcoords.w,
                .h = self.sprite_texcoords.h,
            },
        };

        text_rendering.populateBillboardData2d(
            segments,
            @as(u16, @intFromFloat(out[0].position.x)) + sprite_dimensions.width / 2,
            screen_position_y + total_dimensions.height / 2 -
                @as(u16, @intFromFloat(text_dimensions.height / 2)),
            @as(u16, @intFromFloat(self.font_size)),
            sprite_sheet,
            out[1..],
        );
    }

    fn getSpriteDimensionsInPixels(self: ImageWithText) ScreenDimensions {
        return .{
            .width = @as(u16, @intFromFloat(self.sprite_on_screen_dimensions.w +
                self.sprite_on_screen_spacing.horizontal * 2)),
            .height = @as(u16, @intFromFloat(self.sprite_on_screen_dimensions.h +
                self.sprite_on_screen_spacing.vertical * 2)),
        };
    }

    fn getTotalDimensions(
        sprite_dimensions: ScreenDimensions,
        text_dimensions: text_rendering.Dimensions,
    ) ScreenDimensions {
        return .{
            .width = sprite_dimensions.width + @as(u16, @intFromFloat(text_dimensions.width)),
            .height = @max(
                sprite_dimensions.height,
                @as(u16, @intFromFloat(text_dimensions.height)),
            ),
        };
    }
};
