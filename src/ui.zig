const BillboardData = @import("rendering.zig").BillboardRenderer.BillboardData;
const Color = @import("util.zig").Color;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");

pub const Highlight = struct {
    pub fn normal(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.fromRgb8(193, 193, 193), .text = text };
    }
    pub fn npcName(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.fromRgb8(114, 173, 206), .text = text };
    }
};

/// Polymorphic dispatcher serving as an interface.
pub const Widget = union(enum) {
    box: Box,
    minimum_size: MinimumSize,
    split: Split,
    sprite: Sprite,
    text: Text,

    pub fn getDimensionsInPixels(self: Widget) ScreenDimensions {
        return switch (self) {
            inline else => |subtype| subtype.getDimensionsInPixels(),
        };
    }

    pub fn getBillboardCount(self: Widget) usize {
        return switch (self) {
            inline else => |subtype| subtype.getBillboardCount(),
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

pub const Text = struct {
    /// Non-owning slice.
    wrapped_segments: []const text_rendering.TextSegment,
    /// Non-owning pointer.
    spritesheet: *const SpriteSheetTexture,
    font_size: u16,

    /// Returned object will keep a reference to the given slices and pointers.
    pub fn wrap(
        segments: []const text_rendering.TextSegment,
        spritesheet: *const SpriteSheetTexture,
        text_scale: u8,
    ) Text {
        return .{
            .wrapped_segments = segments,
            .spritesheet = spritesheet,
            .font_size = spritesheet.getFontSizeMultiple(text_scale),
        };
    }

    pub fn getDimensionsInPixels(self: Text) ScreenDimensions {
        const dimensions = text_rendering.getTextBlockDimensions(
            self.wrapped_segments,
            @as(f32, @floatFromInt(self.font_size)),
            self.spritesheet.*,
        );
        return .{
            .width = @as(u16, @intFromFloat(dimensions.width)),
            .height = @as(u16, @intFromFloat(dimensions.height)),
        };
    }

    pub fn getBillboardCount(self: Text) usize {
        return text_rendering.getBillboardCount(self.wrapped_segments);
    }

    pub fn populateBillboardData(
        self: Text,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        return text_rendering.populateBillboardData2d(
            self.wrapped_segments,
            screen_position_x,
            screen_position_y,
            self.font_size,
            self.spritesheet.*,
            out,
        );
    }
};

pub const Sprite = struct {
    sprite_texcoords: SpriteSheetTexture.TextureCoordinates,
    sprite_on_screen_dimensions: struct { w: f32, h: f32 },
    /// Has to be applied twice, both for left/right and top/bottom.
    sprite_on_screen_spacing: struct { horizontal: f32, vertical: f32 },

    pub fn create(
        sprite: SpriteSheetTexture.SpriteId,
        spritesheet: SpriteSheetTexture,
        /// 1 means the original size in pixels.
        sprite_scale: u16,
    ) Sprite {
        const dimensions = spritesheet.getSpriteDimensionsInPixels(sprite);
        return .{
            .sprite_texcoords = spritesheet.getSpriteTexcoords(sprite),
            .sprite_on_screen_dimensions = .{
                .w = @as(f32, @floatFromInt(dimensions.w * sprite_scale)),
                .h = @as(f32, @floatFromInt(dimensions.h * sprite_scale)),
            },
            .sprite_on_screen_spacing = .{
                // 2 Has been picked by trial and error to improve padding.
                .horizontal = 2 * @as(f32, @floatFromInt(sprite_scale)),
                .vertical = 2 * @as(f32, @floatFromInt(sprite_scale)),
            },
        };
    }

    pub fn getDimensionsInPixels(self: Sprite) ScreenDimensions {
        return .{
            .width = @as(u16, @intFromFloat(self.sprite_on_screen_dimensions.w +
                self.sprite_on_screen_spacing.horizontal * 2)),
            .height = @as(u16, @intFromFloat(self.sprite_on_screen_dimensions.h +
                self.sprite_on_screen_spacing.vertical * 2)),
        };
    }

    pub fn getBillboardCount(_: Sprite) usize {
        return 1;
    }

    pub fn populateBillboardData(
        self: Sprite,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        const sprite_dimensions = self.getDimensionsInPixels();
        out[0] = .{
            .position = .{
                .x = @as(f32, @floatFromInt(screen_position_x + sprite_dimensions.width / 2)),
                .y = @as(f32, @floatFromInt(screen_position_y + sprite_dimensions.height / 2)),
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
    }
};

pub const Split = struct {
    split_type: Type,
    /// Non-owning slice.
    wrapped_widgets: []const Widget,

    pub const Type = enum { horizontal, vertical };

    /// Returned object will keep a reference to the given slice.
    pub fn wrap(split_type: Type, widgets_to_wrap: []const Widget) Split {
        return .{ .split_type = split_type, .wrapped_widgets = widgets_to_wrap };
    }

    pub fn getDimensionsInPixels(self: Split) ScreenDimensions {
        var result = ScreenDimensions{ .width = 0, .height = 0 };
        for (self.wrapped_widgets) |widget| {
            const dimensions = widget.getDimensionsInPixels();

            switch (self.split_type) {
                .horizontal => {
                    result.width = @max(result.width, dimensions.width);
                    result.height += dimensions.height;
                },
                .vertical => {
                    result.width += dimensions.width;
                    result.height = @max(result.height, dimensions.height);
                },
            }
        }
        return result;
    }

    pub fn getBillboardCount(self: Split) usize {
        var result: usize = 0;
        for (self.wrapped_widgets) |widget| {
            result += widget.getBillboardCount();
        }
        return result;
    }

    pub fn populateBillboardData(
        self: Split,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        const total_dimensions = self.getDimensionsInPixels();
        var start: usize = 0;
        var end: usize = 0;
        var screen_x = screen_position_x;
        var screen_y = screen_position_y;

        for (self.wrapped_widgets) |widget| {
            const dimensions = widget.getDimensionsInPixels();

            start = end;
            end += widget.getBillboardCount();

            switch (self.split_type) {
                .horizontal => {
                    widget.populateBillboardData(
                        screen_x + total_dimensions.width / 2 - dimensions.width / 2,
                        screen_y,
                        out[start..end],
                    );
                    screen_y += dimensions.height;
                },
                .vertical => {
                    widget.populateBillboardData(
                        screen_x,
                        screen_y + total_dimensions.height / 2 - dimensions.height / 2,
                        out[start..end],
                    );
                    screen_x += dimensions.width;
                },
            }
        }
    }
};

/// Wraps a widget to give it a minimum size.
pub const MinimumSize = struct {
    wrapped_widget: *const Widget,
    minimum: ScreenDimensions,

    /// Returned object will keep a reference to the given widget.
    pub fn wrap(
        widget_to_wrap: *const Widget,
        minimum_width: u16,
        minimum_height: u16,
    ) MinimumSize {
        return .{
            .wrapped_widget = widget_to_wrap,
            .minimum = .{ .width = minimum_width, .height = minimum_height },
        };
    }

    pub fn getDimensionsInPixels(self: MinimumSize) ScreenDimensions {
        const dimensions = self.wrapped_widget.getDimensionsInPixels();
        return .{
            .width = @max(self.minimum.width, dimensions.width),
            .height = @max(self.minimum.height, dimensions.height),
        };
    }

    pub fn getBillboardCount(self: MinimumSize) usize {
        return self.wrapped_widget.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: MinimumSize,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardData,
    ) void {
        self.wrapped_widget.populateBillboardData(screen_position_x, screen_position_y, out);
    }
};

pub const Box = struct {
    /// Non-owning pointer.
    wrapped_widget: *const Widget,
    /// Non-owning pointer.
    spritesheet: *const SpriteSheetTexture,
    /// Dimensions of the dialog box elements. Assumed to be the same for all dialog box sprites.
    scaled_sprite: struct { width: f32, height: f32 },

    const dialog_sprite_count = 9;
    const dialog_sprite_scale = 4;

    /// Returned object will keep a reference to the given pointers.
    pub fn wrap(widget_to_wrap: *const Widget, spritesheet: *const SpriteSheetTexture) Box {
        const dimensions = spritesheet.getSpriteDimensionsInPixels(.dialog_box_top_left);
        return .{
            .wrapped_widget = widget_to_wrap,
            .spritesheet = spritesheet,
            .scaled_sprite = .{
                .width = @as(f32, @floatFromInt(dimensions.w)) * dialog_sprite_scale,
                .height = @as(f32, @floatFromInt(dimensions.h)) * dialog_sprite_scale,
            },
        };
    }

    pub fn getDimensionsInPixels(self: Box) ScreenDimensions {
        const content = self.wrapped_widget.getDimensionsInPixels();
        return .{
            .width = @as(u16, @intFromFloat(self.scaled_sprite.width)) * 2 + content.width,
            .height = @as(u16, @intFromFloat(self.scaled_sprite.height)) * 2 + content.height,
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
            self.spritesheet,
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

    const BillboardDataHelper = struct {
        spritesheet: *const SpriteSheetTexture,
        top_left_corner: struct { x: f32, y: f32 },
        /// Dimensions. Assumed to be the same for all dialog box sprites.
        scaled_sprite: struct { width: f32, height: f32 },
        out: []BillboardData,

        fn create(
            spritesheet: *const SpriteSheetTexture,
            screen_position_x: u16,
            screen_position_y: u16,
            scaled_sprite_width: f32,
            scaled_sprite_height: f32,
            out: []BillboardData,
        ) BillboardDataHelper {
            return .{
                .spritesheet = spritesheet,
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
            const sprite_texcoords = self.spritesheet.getSpriteTexcoords(corner);
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
