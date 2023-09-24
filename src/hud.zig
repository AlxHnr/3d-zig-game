const std = @import("std");
const BillboardRenderer = @import("rendering.zig").BillboardRenderer;
const Color = @import("util.zig").Color;
const EditModeState = @import("edit_mode.zig").State;
const ScreenDimensions = @import("math.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");
const GameContext = @import("game_context.zig").Context;
const ui = @import("ui.zig");

pub const Hud = struct {
    renderer: BillboardRenderer,
    sprite_sheet: SpriteSheetTexture,
    billboard_buffer: []BillboardRenderer.BillboardData,

    pub fn create() !Hud {
        var renderer = try BillboardRenderer.create();
        errdefer renderer.destroy();

        var sprite_sheet = try SpriteSheetTexture.loadFromDisk();
        errdefer sprite_sheet.destroy();

        return .{
            .renderer = renderer,
            .sprite_sheet = sprite_sheet,
            .billboard_buffer = &.{},
        };
    }

    pub fn destroy(self: *Hud, allocator: std.mem.Allocator) void {
        allocator.free(self.billboard_buffer);
        self.sprite_sheet.destroy();
        self.renderer.destroy();
    }

    pub fn render(
        self: *Hud,
        allocator: std.mem.Allocator,
        screen_dimensions: ScreenDimensions,
        game_context: GameContext,
        edit_mode_state: EditModeState,
    ) !void {
        var edit_mode_buffer: [64]u8 = undefined;
        var gem_info = try GemCountInfo.create(
            allocator,
            game_context.getPlayerGemCount(),
            &self.sprite_sheet,
        );
        defer gem_info.destroy(allocator);
        const edit_mode_info = try EditModeInfo.create(edit_mode_state, &edit_mode_buffer);

        const gem_billboard_count = gem_info.getBillboardCount();
        const edit_mode_billboard_count = edit_mode_info.getBillboardCount();
        const total_billboard_count = gem_billboard_count + edit_mode_billboard_count;
        if (self.billboard_buffer.len < total_billboard_count) {
            self.billboard_buffer =
                try allocator.realloc(self.billboard_buffer, total_billboard_count);
        }

        var start: usize = 0;
        var end = gem_billboard_count;
        gem_info.populateBillboardData(screen_dimensions, self.billboard_buffer[start..end]);

        start = end;
        end += edit_mode_billboard_count;
        edit_mode_info.populateBillboardData(
            self.sprite_sheet,
            self.billboard_buffer[start..end],
        );

        self.renderer.uploadBillboards(self.billboard_buffer[0..end]);
        self.renderer.render2d(screen_dimensions, self.sprite_sheet.id);
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
        sprite_sheet: *const SpriteSheetTexture,
    ) !GemCountInfo {
        var buffer = try allocator.alloc(u8, 16);
        errdefer allocator.free(buffer);

        var segments = try allocator.alloc(text_rendering.TextSegment, 1);
        errdefer allocator.free(segments);

        var widgets = try allocator.alloc(ui.Widget, 4);
        errdefer allocator.free(widgets);

        segments[0] = .{
            .color = Color.fromRgb8(0, 0, 0),
            .text = try std.fmt.bufPrint(buffer, "{}", .{gem_count}),
        };
        widgets[0] = .{ .sprite = ui.Sprite.create(.gem, sprite_sheet.*, 3) };
        widgets[1] = .{ .text = ui.Text.wrap(segments, sprite_sheet, 4) };
        widgets[2] = .{ .vertical_split = ui.VerticalSplit.wrap(&widgets[0], &widgets[1]) };

        return .{
            .buffer = buffer,
            .segments = segments,
            .widgets = widgets,
            .main_widget = &widgets[2],
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
        out: []BillboardRenderer.BillboardData,
    ) void {
        const info_dimensions = self.main_widget.getDimensionsInPixels();
        self.main_widget.populateBillboardData(
            0,
            screen_dimensions.height - info_dimensions.height,
            out,
        );
    }
};

const EditModeInfo = struct {
    segments: [3]text_rendering.TextSegment,

    fn create(
        state: EditModeState,
        /// Returned result keeps a reference to this buffer.
        buffer: []u8,
    ) !EditModeInfo {
        const text_color = Color.fromRgb8(0, 0, 0);
        const description = try state.describe(buffer);
        return .{ .segments = [_]text_rendering.TextSegment{
            .{ .color = text_color, .text = description[0] },
            .{ .color = text_color, .text = "\n" },
            .{ .color = text_color, .text = description[1] },
        } };
    }

    fn getBillboardCount(self: EditModeInfo) usize {
        return text_rendering.getBillboardCount(&self.segments);
    }

    fn populateBillboardData(
        self: EditModeInfo,
        sprite_sheet: SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        text_rendering.populateBillboardData2d(
            &self.segments,
            0,
            0,
            sprite_sheet.getFontSizeMultiple(2),
            sprite_sheet,
            out,
        );
    }
};
