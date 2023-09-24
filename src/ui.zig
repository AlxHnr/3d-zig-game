const BillboardData = @import("rendering.zig").BillboardRenderer.BillboardData;
const ScreenDimensions = @import("math.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");

const std = @import("std");

/// Polymorphic dispatcher serving as an interface.
pub const Widget = union(enum) {
    box: Box,

    pub fn getBillboardCount(self: Widget) usize {
        return switch (self) {
            inline else => |subtype| subtype.getBillboardCount(),
        };
    }

    pub fn getDimensionsInPixels(self: Widget) ScreenDimensions {
        return switch (self) {
            inline else => |subtype| subtype.getDimensionsInPixels(),
        };
    }

    pub fn populateBillboardData(
        self: Widget,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        switch (self) {
            inline else => |subtype| subtype.populateBillboardData(
                screen_position_x,
                screen_position_y,
                out,
            ),
        }
    }
};

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

pub const Box = struct {
    /// Non-owning pointer.
    wrapped_widget: *const Widget,
    /// Non-owning pointer.
    sprite_sheet: *const SpriteSheetTexture,
    /// Dimensions of the dialog box elements. Assumed to be the same for all dialog box sprites.
    scaled_sprite: struct { width: f32, height: f32 },

    const dialog_sprite_count = 9;
    const dialog_sprite_scale = 4;

    pub fn wrap(wrapped_widget: *const Widget, sprite_sheet: *const SpriteSheetTexture) Box {
        const dimensions = sprite_sheet.getSpriteDimensionsInPixels(.dialog_box_top_left);
        return .{
            .wrapped_widget = wrapped_widget,
            .sprite_sheet = sprite_sheet,
            .scaled_sprite = .{
                .width = @as(f32, @floatFromInt(dimensions.w)) * dialog_sprite_scale,
                .height = @as(f32, @floatFromInt(dimensions.h)) * dialog_sprite_scale,
            },
        };
    }

    pub fn getBillboardCount(self: Box) usize {
        return dialog_sprite_count + self.wrapped_widget.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: Box,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        const content_u16 = self.wrapped_widget.getDimensionsInPixels();
        const content = .{
            .w = @as(f32, @floatFromInt(content_u16.width)),
            .h = @as(f32, @floatFromInt(content_u16.height)),
        };
        const sprite = .{ .w = self.scaled_sprite.width, .h = self.scaled_sprite.height };

        const helper = BillboardDataHelper.create(
            self.sprite_sheet.*,
            screen_position_x,
            screen_position_y,
            sprite.w,
            sprite.h,
            out,
        );
        helper.insert(.dialog_box_top_left, 0, 0, sprite.w, sprite.h);
        helper.insert(.dialog_box_top_center, sprite.w, 0, content.w, sprite.h);
        helper.insert(.dialog_box_top_right, sprite.w + content.w, 0, sprite.w, sprite.h);
        helper.insert(.dialog_box_center_left, 0, sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_center_left, 0, sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_center_center, sprite.w, sprite.h, content.w, content.h);
        helper.insert(.dialog_box_center_right, sprite.w + content.w, sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_bottom_left, 0, sprite.h + content.h, sprite.w, sprite.h);
        helper.insert(.dialog_box_bottom_center, sprite.w, sprite.h + content.h, content.w, sprite.h);
        helper.insert(.dialog_box_bottom_right, sprite.w + content.w, sprite.h + content.h, sprite.w, sprite.h);

        self.wrapped_widget.populateBillboardData(
            screen_position_x + @as(u16, @intFromFloat(sprite.w)),
            screen_position_y + @as(u16, @intFromFloat(sprite.h)),
            out[dialog_sprite_count..],
        );
    }

    pub fn getDimensionsInPixels(self: Box) ScreenDimensions {
        const content = self.wrapped_widget.getDimensionsInPixels();
        return .{
            .width = @as(u16, @intFromFloat(self.scaled_sprite.width)) * 2 + content.width,
            .height = @as(u16, @intFromFloat(self.scaled_sprite.height)) * 2 + content.height,
        };
    }

    const BillboardDataHelper = struct {
        sprite_sheet: SpriteSheetTexture,
        top_left_corner: struct { x: f32, y: f32 },
        /// Dimensions. Assumed to be the same for all dialog box sprites.
        scaled_sprite: struct { width: f32, height: f32 },
        out: []BillboardData,

        fn create(
            sprite_sheet: SpriteSheetTexture,
            screen_position_x: u16,
            screen_position_y: u16,
            scaled_sprite_width: f32,
            scaled_sprite_height: f32,
            out: []BillboardData,
        ) BillboardDataHelper {
            return .{
                .sprite_sheet = sprite_sheet,
                .top_left_corner = .{
                    .x = @as(f32, @floatFromInt(screen_position_x)),
                    .y = @as(f32, @floatFromInt(screen_position_y)),
                },
                .scaled_sprite = .{
                    .width = scaled_sprite_width,
                    .height = scaled_sprite_height,
                },
                .out = out,
            };
        }

        fn insert(
            self: BillboardDataHelper,
            corner: SpriteSheetTexture.SpriteId,
            offset_from_top_left_x: f32,
            offset_from_top_left_y: f32,
            width: f32,
            height: f32,
        ) void {
            const sprite_texcoords = self.sprite_sheet.getSpriteTexcoords(corner);
            self.out[getIndex(corner)] = .{
                .position = .{
                    .x = self.top_left_corner.x + offset_from_top_left_x + width / 2,
                    .y = self.top_left_corner.y + offset_from_top_left_y + height / 2,
                    .z = 0,
                },
                .size = .{ .w = width, .h = height },
                .source_rect = .{
                    .x = sprite_texcoords.x,
                    .y = sprite_texcoords.y,
                    .w = sprite_texcoords.w,
                    .h = sprite_texcoords.h,
                },
            };
        }

        fn getIndex(corner: SpriteSheetTexture.SpriteId) usize {
            return switch (corner) {
                .dialog_box_bottom_center => 0,
                .dialog_box_bottom_left => 1,
                .dialog_box_bottom_right => 2,
                .dialog_box_center_center => 3,
                .dialog_box_center_left => 4,
                .dialog_box_center_right => 5,
                .dialog_box_top_center => 6,
                .dialog_box_top_left => 7,
                .dialog_box_top_right => 8,
                else => unreachable,
            };
        }
    };
};
