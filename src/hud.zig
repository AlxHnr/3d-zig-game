const std = @import("std");
const Color = @import("util.zig").Color;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");
const ui = @import("ui.zig");
const rendering = @import("rendering.zig");

pub const Hud = struct {
    renderer: rendering.SpriteRenderer,
    sprite_buffer: []rendering.SpriteData,

    pub fn create() !Hud {
        return .{
            .renderer = try rendering.SpriteRenderer.create(),
            .sprite_buffer = &.{},
        };
    }

    pub fn destroy(self: *Hud, allocator: std.mem.Allocator) void {
        allocator.free(self.sprite_buffer);
        self.renderer.destroy();
    }

    pub fn render(
        self: *Hud,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
        spritesheet: SpriteSheetTexture,
        gem_count: u64,
        player_health: u32,
    ) !void {
        var widgets = try WrappedWidgets.create(allocator, gem_count, player_health, &spritesheet);
        defer widgets.destroy(allocator);

        const total_sprite_count = widgets.getSpriteCount();
        if (self.sprite_buffer.len < total_sprite_count) {
            self.sprite_buffer =
                try allocator.realloc(self.sprite_buffer, total_sprite_count);
        }

        widgets.populateSpriteData(
            screen_dimensions,
            self.sprite_buffer[0..total_sprite_count],
        );
        self.renderer.uploadSprites(self.sprite_buffer[0..total_sprite_count]);
        self.renderer.render(screen_dimensions, spritesheet.id);
    }
};

const WrappedWidgets = struct {
    buffer: []u8,
    segments: []text_rendering.TextSegment,
    widgets: []ui.Widget,
    /// Non-owning pointer.
    main_widget: *const ui.Widget,

    fn create(
        allocator: std.mem.Allocator,
        gem_count: u64,
        player_health: u32,
        /// Returned object keeps a reference to this sprite sheet.
        spritesheet: *const SpriteSheetTexture,
    ) !WrappedWidgets {
        var buffer = try allocator.alloc(u8, 64);
        errdefer allocator.free(buffer);

        var segments = try allocator.alloc(text_rendering.TextSegment, 1);
        errdefer allocator.free(segments);

        var widgets = try allocator.alloc(ui.Widget, 1);
        errdefer allocator.free(widgets);

        segments[0] = .{
            .color = Color.fromRgb8(0, 0, 0),
            .text = try std.fmt.bufPrint(buffer, "Gems: {}\nHP: {}", .{ gem_count, player_health }),
        };
        widgets[0] = .{ .text = ui.Text.wrap(segments, spritesheet, 3) };

        return .{
            .buffer = buffer,
            .segments = segments,
            .widgets = widgets,
            .main_widget = &widgets[widgets.len - 1],
        };
    }

    fn destroy(self: *WrappedWidgets, allocator: std.mem.Allocator) void {
        allocator.free(self.widgets);
        allocator.free(self.segments);
        allocator.free(self.buffer);
    }

    fn getSpriteCount(self: WrappedWidgets) usize {
        return self.main_widget.getSpriteCount();
    }

    fn populateSpriteData(
        self: WrappedWidgets,
        screen_dimensions: ScreenDimensions,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        const info_dimensions = self.main_widget.getDimensionsInPixels();
        self.main_widget.populateSpriteData(
            0,
            screen_dimensions.height - info_dimensions.height,
            out,
        );
    }
};
