const Color = rendering.Color;
const ScreenDimensions = @import("rendering.zig").ScreenDimensions;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const text_rendering = @import("text_rendering.zig");

/// Highlight groups for text inside ui.Box.
pub const Highlight = struct {
    pub fn normal(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.create(193, 193, 193, 255), .text = text };
    }
    pub fn npcName(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.create(114, 173, 206, 255), .text = text };
    }
    pub fn selectableChoice(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.create(193, 193, 130, 255), .text = text };
    }
    pub fn cancelChoice(text: []const u8) text_rendering.TextSegment {
        return .{ .color = Color.create(193, 100, 174, 255), .text = text };
    }
};

/// Polymorphic dispatcher serving as an interface.
pub const Widget = union(enum) {
    box: Box,
    minimum_size: MinimumSize,
    spacing: Spacing,
    split: Split,
    sprite: Sprite,
    text: Text,

    pub fn getDimensionsInPixels(self: Widget) ScreenDimensions {
        return switch (self) {
            inline else => |subtype| subtype.getDimensionsInPixels(),
        };
    }

    pub fn getSpriteCount(self: Widget) usize {
        return switch (self) {
            inline else => |subtype| subtype.getSpriteCount(),
        };
    }

    pub fn populateSpriteData(
        self: Widget,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        switch (self) {
            inline else => |subtype| subtype.populateSpriteData(
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
            fp(self.font_size),
            self.spritesheet.*,
        );
        return .{
            .w = dimensions.width.convertTo(u16),
            .h = dimensions.height.convertTo(u16),
        };
    }

    pub fn getSpriteCount(self: Text) usize {
        return text_rendering.getSpriteCount(self.wrapped_segments);
    }

    pub fn populateSpriteData(
        self: Text,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        return text_rendering.populateSpriteData(
            self.wrapped_segments,
            fp(screen_position_x),
            fp(screen_position_y),
            self.font_size,
            self.spritesheet.*,
            out,
        );
    }
};

pub const Sprite = struct {
    texcoords: rendering.TextureSourceRectangle,
    dimensions: ScreenDimensions,

    pub fn create(
        sprite: SpriteSheetTexture.SpriteId,
        spritesheet: SpriteSheetTexture,
        /// 1 means the original size in pixels.
        sprite_scale: u16,
    ) Sprite {
        const dimensions = spritesheet.getSpriteSourceRectangle(sprite);
        return .{
            .texcoords = spritesheet.getSpriteSourceRectangle(sprite),
            .dimensions = .{
                .width = dimensions.width * sprite_scale,
                .height = dimensions.height * sprite_scale,
            },
        };
    }

    pub fn getDimensionsInPixels(self: Sprite) ScreenDimensions {
        return self.dimensions;
    }

    pub fn getSpriteCount(_: Sprite) usize {
        return 1;
    }

    pub fn populateSpriteData(
        self: Sprite,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        const position = math.Vector3d{
            .x = fp(screen_position_x + self.dimensions.w / 2),
            .y = fp(screen_position_y + self.dimensions.h / 2),
            .z = fp(0),
        };
        out[0] = SpriteData
            .create(position, self.texcoords, fp(self.dimensions.w), fp(self.dimensions.h));
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
        var result = ScreenDimensions{ .w = 0, .h = 0 };
        for (self.wrapped_widgets) |widget| {
            const dimensions = widget.getDimensionsInPixels();

            switch (self.split_type) {
                .horizontal => {
                    result.w = @max(result.w, dimensions.w);
                    result.h += dimensions.h;
                },
                .vertical => {
                    result.w += dimensions.w;
                    result.h = @max(result.h, dimensions.h);
                },
            }
        }
        return result;
    }

    pub fn getSpriteCount(self: Split) usize {
        var result: usize = 0;
        for (self.wrapped_widgets) |widget| {
            result += widget.getSpriteCount();
        }
        return result;
    }

    pub fn populateSpriteData(
        self: Split,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        var start: usize = 0;
        var end: usize = 0;
        var screen_x = screen_position_x;
        var screen_y = screen_position_y;

        for (self.wrapped_widgets) |widget| {
            start = end;
            end += widget.getSpriteCount();
            widget.populateSpriteData(screen_x, screen_y, out[start..end]);

            const dimensions = widget.getDimensionsInPixels();
            switch (self.split_type) {
                .horizontal => screen_y += dimensions.h,
                .vertical => screen_x += dimensions.w,
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
            .minimum = .{ .w = minimum_width, .h = minimum_height },
        };
    }

    pub fn getDimensionsInPixels(self: MinimumSize) ScreenDimensions {
        const dimensions = self.wrapped_widget.getDimensionsInPixels();
        return .{
            .w = @max(self.minimum.w, dimensions.w),
            .h = @max(self.minimum.h, dimensions.h),
        };
    }

    pub fn getSpriteCount(self: MinimumSize) usize {
        return self.wrapped_widget.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: MinimumSize,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        self.wrapped_widget.populateSpriteData(screen_position_x, screen_position_y, out);
    }
};

/// Container for adding horizontal and vertical spacing around other widgets.
pub const Spacing = struct {
    /// Non-owning pointer.
    wrapped_widget: *const Widget,
    /// {25, 0} means adding 25 pixels to both the left and the right of the wrapped widget.
    fixed_pixels: struct { horizontal: u16, vertical: u16 },
    /// Values based on the size of the wrapped widget, where {0.5, 0.5} means adding half of
    /// the wrapped_widget's size both to the left and the right plus the top and bottom.
    percentual: struct { horizontal: math.Fix32, vertical: math.Fix32 },

    /// Returned object will keep a reference to the given widget. A horizontal value of 0.5 means
    /// adding half of the wrapped widgets width to both the left and the right of it.
    pub fn wrapPercentual(
        widget_to_wrap: *const Widget,
        horizontal: math.Fix32,
        vertical: math.Fix32,
    ) Spacing {
        return .{
            .wrapped_widget = widget_to_wrap,
            .fixed_pixels = .{ .horizontal = 0, .vertical = 0 },
            .percentual = .{ .horizontal = horizontal, .vertical = vertical },
        };
    }

    /// Returned object will keep a reference to the given widget. Each of the given spacings is
    /// specified in screen pixels and will be applied twice:
    ///   * horizontal => both to the left and the right
    ///   * vertical => both to the top and the bottom
    pub fn wrapFixedPixels(widget_to_wrap: *const Widget, horizontal: u16, vertical: u16) Spacing {
        return .{
            .wrapped_widget = widget_to_wrap,
            .fixed_pixels = .{ .horizontal = horizontal, .vertical = vertical },
            .percentual = .{ .horizontal = fp(0), .vertical = fp(0) },
        };
    }

    pub fn getDimensionsInPixels(self: Spacing) ScreenDimensions {
        const content = self.wrapped_widget.getDimensionsInPixels();
        return .{
            .w = fp(content.w).mul(self.percentual.horizontal.mul(fp(2)).add(fp(1)))
                .convertTo(u16) + self.fixed_pixels.horizontal * 2,
            .h = fp(content.h).mul(self.percentual.vertical.mul(fp(2)).add(fp(1)))
                .convertTo(u16) + self.fixed_pixels.vertical * 2,
        };
    }

    pub fn getSpriteCount(self: Spacing) usize {
        return self.wrapped_widget.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: Spacing,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        const content = self.wrapped_widget.getDimensionsInPixels();
        const offset = .{
            .x = fp(content.w).mul(self.percentual.horizontal)
                .convertTo(u16) + self.fixed_pixels.horizontal,
            .y = fp(content.h).mul(self.percentual.vertical)
                .convertTo(u16) + self.fixed_pixels.vertical,
        };
        self.wrapped_widget.populateSpriteData(
            screen_position_x + offset.x,
            screen_position_y + offset.y,
            out,
        );
    }
};

pub const Box = struct {
    /// Non-owning pointer.
    wrapped_widget: *const Widget,
    /// Non-owning pointer.
    spritesheet: *const SpriteSheetTexture,
    /// Dimensions of the dialog box elements. Assumed to be the same for all dialog box sprites.
    scaled_sprite: struct { width: math.Fix32, height: math.Fix32 },

    const dialog_sprite_count = 9;
    const dialog_sprite_scale = 2;

    /// Returned object will keep a reference to the given pointers.
    pub fn wrap(widget_to_wrap: *const Widget, spritesheet: *const SpriteSheetTexture) Box {
        const dimensions = spritesheet.getSpriteSourceRectangle(.dialog_box_top_left);
        return .{
            .wrapped_widget = widget_to_wrap,
            .spritesheet = spritesheet,
            .scaled_sprite = .{
                .width = fp(dimensions.w).mul(fp(dialog_sprite_scale)),
                .height = fp(dimensions.h).mul(fp(dialog_sprite_scale)),
            },
        };
    }

    pub fn getDimensionsInPixels(self: Box) ScreenDimensions {
        const content = self.wrapped_widget.getDimensionsInPixels();
        const frame_dimensions = self.getFrameDimensionsWithoutContent();
        return .{
            .w = content.w + frame_dimensions.w,
            .h = content.h + frame_dimensions.h,
        };
    }

    /// Get the boxes frame size in pixels.
    pub fn getFrameDimensionsWithoutContent(self: Box) ScreenDimensions {
        return .{
            .w = self.scaled_sprite.width.convertTo(u16) * 2,
            .h = self.scaled_sprite.height.convertTo(u16) * 2,
        };
    }

    pub fn getSpriteCount(self: Box) usize {
        return dialog_sprite_count + self.wrapped_widget.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: Box,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []SpriteData,
    ) void {
        const content_u16 = self.wrapped_widget.getDimensionsInPixels();
        const content = .{
            .w = fp(content_u16.w),
            .h = fp(content_u16.h),
        };
        const sprite = .{
            .w = self.scaled_sprite.width,
            .h = self.scaled_sprite.height,
        };

        const helper = SpriteDataHelper.create(
            self.spritesheet,
            screen_position_x,
            screen_position_y,
            sprite.w,
            sprite.h,
            out,
        );
        helper.insert(.dialog_box_top_left, fp(0), fp(0), sprite.w, sprite.h);
        helper.insert(.dialog_box_top_center, sprite.w, fp(0), content.w, sprite.h);
        helper.insert(.dialog_box_top_right, sprite.w.add(content.w), fp(0), sprite.w, sprite.h);
        helper.insert(.dialog_box_center_left, fp(0), sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_center_left, fp(0), sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_center_center, sprite.w, sprite.h, content.w, content.h);
        helper.insert(.dialog_box_center_right, sprite.w.add(content.w), sprite.h, sprite.w, content.h);
        helper.insert(.dialog_box_bottom_left, fp(0), sprite.h.add(content.h), sprite.w, sprite.h);
        helper.insert(.dialog_box_bottom_center, sprite.w, sprite.h.add(content.h), content.w, sprite.h);
        helper.insert(.dialog_box_bottom_right, sprite.w.add(content.w), sprite.h.add(content.h), sprite.w, sprite.h);

        self.wrapped_widget.populateSpriteData(
            screen_position_x + sprite.w.convertTo(u16),
            screen_position_y + sprite.h.convertTo(u16),
            out[dialog_sprite_count..],
        );
    }

    const SpriteDataHelper = struct {
        spritesheet: *const SpriteSheetTexture,
        top_left_corner: struct { x: math.Fix32, y: math.Fix32 },
        /// Dimensions. Assumed to be the same for all dialog box sprites.
        scaled_sprite: struct { width: math.Fix32, height: math.Fix32 },
        out: []SpriteData,

        fn create(
            spritesheet: *const SpriteSheetTexture,
            screen_position_x: u16,
            screen_position_y: u16,
            scaled_sprite_width: math.Fix32,
            scaled_sprite_height: math.Fix32,
            out: []SpriteData,
        ) SpriteDataHelper {
            return .{
                .spritesheet = spritesheet,
                .top_left_corner = .{
                    .x = fp(screen_position_x),
                    .y = fp(screen_position_y),
                },
                .scaled_sprite = .{
                    .width = scaled_sprite_width,
                    .height = scaled_sprite_height,
                },
                .out = out,
            };
        }

        fn insert(
            self: SpriteDataHelper,
            corner: SpriteSheetTexture.SpriteId,
            offset_from_top_left_x: math.Fix32,
            offset_from_top_left_y: math.Fix32,
            width: math.Fix32,
            height: math.Fix32,
        ) void {
            const sprite_texcoords = self.spritesheet.getSpriteSourceRectangle(corner);
            const position = math.Vector3d{
                .x = self.top_left_corner.x.add(offset_from_top_left_x).add(width.div(fp(2))),
                .y = self.top_left_corner.y.add(offset_from_top_left_y).add(height.div(fp(2))),
                .z = fp(0),
            };
            self.out[getIndex(corner)] = SpriteData
                .create(position, sprite_texcoords, width, height);
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
