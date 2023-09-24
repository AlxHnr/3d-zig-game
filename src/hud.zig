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
        var gem_buffer: [16]u8 = undefined;
        var edit_mode_buffer: [64]u8 = undefined;
        const gem_info = try GemCountInfo.create(
            game_context.getPlayerGemCount(),
            self.sprite_sheet,
            &gem_buffer,
        );
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
        gem_info.populateBillboardData(
            screen_dimensions,
            self.sprite_sheet,
            self.billboard_buffer[start..end],
        );

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
    segments: [1]text_rendering.TextSegment,
    image_with_text: ui.ImageWithText,

    fn create(
        gem_count: u64,
        sprite_sheet: SpriteSheetTexture,
        /// Returned result keeps a reference to this buffer.
        buffer: []u8,
    ) !GemCountInfo {
        return .{
            .segments = [_]text_rendering.TextSegment{.{
                .color = Color.fromRgb8(0, 0, 0),
                .text = try std.fmt.bufPrint(buffer, "{}", .{gem_count}),
            }},
            .image_with_text = ui.ImageWithText.create(.gem, 3, sprite_sheet, 4),
        };
    }

    fn getBillboardCount(self: GemCountInfo) usize {
        return self.image_with_text.getBillboardCount(&self.segments);
    }

    fn populateBillboardData(
        self: GemCountInfo,
        screen_dimensions: ScreenDimensions,
        sprite_sheet: SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        const info_dimensions =
            self.image_with_text.getDimensionsInPixels(&self.segments, sprite_sheet);
        self.image_with_text.populateBillboardData(
            0,
            screen_dimensions.height - info_dimensions.height,
            sprite_sheet,
            &self.segments,
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
