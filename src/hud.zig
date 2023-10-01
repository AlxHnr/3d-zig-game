const std = @import("std");
const Color = @import("util.zig").Color;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");
const ui = @import("ui.zig");
const rendering = @import("rendering.zig");

pub const Hud = struct {
    renderer: rendering.BillboardRenderer,
    billboard_buffer: []rendering.BillboardData,

    pub fn create() !Hud {
        return .{
            .renderer = try rendering.BillboardRenderer.create(),
            .billboard_buffer = &.{},
        };
    }

    pub fn destroy(self: *Hud, allocator: std.mem.Allocator) void {
        allocator.free(self.billboard_buffer);
        self.renderer.destroy();
    }

    pub fn render(
        self: *Hud,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
        spritesheet: SpriteSheetTexture,
        gem_count: u64,
    ) !void {
        var gem_info = try GemCountInfo.create(allocator, gem_count, &spritesheet);
        defer gem_info.destroy(allocator);

        const total_billboard_count = gem_info.getBillboardCount();
        if (self.billboard_buffer.len < total_billboard_count) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, total_billboard_count);
        }

        gem_info.populateBillboardData(
            screen_dimensions,
            self.billboard_buffer[0..total_billboard_count],
        );
        self.renderer.uploadBillboards(self.billboard_buffer[0..total_billboard_count]);
        self.renderer.render2d(screen_dimensions, spritesheet.id);
    }
};

const GemCountInfo = struct {
    buffer: []u8,
    segments: []text_rendering.TextSegment,
    widgets: []ui.Widget,
    /// Non-owning pointer.
    main_widget: *const ui.Widget,

    fn create(
        allocator: std.mem.Allocator,
        gem_count: u64,
        /// Returned object keeps a reference to this sprite sheet.
        spritesheet: *const SpriteSheetTexture,
    ) !GemCountInfo {
        var buffer = try allocator.alloc(u8, 16);
        errdefer allocator.free(buffer);

        var segments = try allocator.alloc(text_rendering.TextSegment, 1);
        errdefer allocator.free(segments);

        var widgets = try allocator.alloc(ui.Widget, 4);
        errdefer allocator.free(widgets);

        const sprite_scale = 3;
        widgets[0] = .{ .sprite = ui.Sprite.create(.gem, spritesheet.*, sprite_scale) };
        widgets[1] = .{
            .spacing = ui.Spacing.wrapFixedPixels(&widgets[0], sprite_scale * 2, sprite_scale * 2),
        };

        segments[0] = .{
            .color = Color.fromRgb8(0, 0, 0),
            .text = try std.fmt.bufPrint(buffer, "{}", .{gem_count}),
        };
        widgets[2] = .{ .text = ui.Text.wrap(segments, spritesheet, 4) };
        widgets[3] = .{ .split = ui.Split.wrap(.horizontal, widgets[1..3]) };

        return .{
            .buffer = buffer,
            .segments = segments,
            .widgets = widgets,
            .main_widget = &widgets[widgets.len - 1],
        };
    }

    fn destroy(self: *GemCountInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.widgets);
        allocator.free(self.segments);
        allocator.free(self.buffer);
    }

    fn getBillboardCount(self: GemCountInfo) usize {
        return self.main_widget.getBillboardCount();
    }

    fn populateBillboardData(
        self: GemCountInfo,
        screen_dimensions: ScreenDimensions,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []rendering.BillboardData,
    ) void {
        const info_dimensions = self.main_widget.getDimensionsInPixels();
        self.main_widget.populateBillboardData(
            0,
            screen_dimensions.height - info_dimensions.height,
            out,
        );
    }
};
