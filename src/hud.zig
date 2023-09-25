const std = @import("std");
const BillboardRenderer = @import("rendering.zig").BillboardRenderer;
const Color = @import("util.zig").Color;
const EditModeState = @import("edit_mode.zig").State;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");
const GameContext = @import("game_context.zig").Context;
const ui = @import("ui.zig");

pub const Hud = struct {
    renderer: BillboardRenderer,
    /// Non-owning pointer.
    spritesheet: *const SpriteSheetTexture,
    billboard_buffer: []BillboardRenderer.BillboardData,

    /// Returned object will keep a reference to the given pointers.
    pub fn create(spritesheet: *const SpriteSheetTexture) !Hud {
        return .{
            .renderer = try BillboardRenderer.create(),
            .spritesheet = spritesheet,
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
        game_context: GameContext,
        edit_mode_state: EditModeState,
    ) !void {
        var edit_mode_buffer: [64]u8 = undefined;
        var gem_info = try GemCountInfo.create(
            allocator,
            game_context.getPlayerGemCount(),
            self.spritesheet,
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
            self.spritesheet.*,
            self.billboard_buffer[start..end],
        );

        self.renderer.uploadBillboards(self.billboard_buffer[0..end]);
        self.renderer.render2d(screen_dimensions, self.spritesheet.id);
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

        var widgets = try allocator.alloc(ui.Widget, 3);
        errdefer allocator.free(widgets);

        segments[0] = .{
            .color = Color.fromRgb8(0, 0, 0),
            .text = try std.fmt.bufPrint(buffer, "{}", .{gem_count}),
        };
        widgets[0] = .{ .sprite = ui.Sprite.create(.gem, spritesheet.*, 3) };
        widgets[1] = .{ .text = ui.Text.wrap(segments, spritesheet, 4) };
        widgets[2] = .{ .split = ui.Split.wrap(.vertical, widgets[0..2]) };

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
        spritesheet: SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        text_rendering.populateBillboardData2d(
            &self.segments,
            0,
            0,
            spritesheet.getFontSizeMultiple(2),
            spritesheet,
            out,
        );
    }
};
