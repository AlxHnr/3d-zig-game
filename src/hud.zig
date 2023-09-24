const std = @import("std");
const BillboardRenderer = @import("rendering.zig").BillboardRenderer;
const Color = @import("util.zig").Color;
const EditModeState = @import("edit_mode.zig").State;
const ScreenDimensions = @import("math.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const text_rendering = @import("text_rendering.zig");
const GameContext = @import("game_context.zig").Context;

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
        const gem_info = try GemCountInfo.create(game_context.getPlayerGemCount(), &gem_buffer);
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

    fn create(
        gem_count: u64,
        /// Returned result keeps a reference to this buffer.
        buffer: []u8,
    ) !GemCountInfo {
        const text_color = Color.fromRgb8(0, 0, 0);
        return .{
            .segments = [_]text_rendering.TextSegment{
                .{
                    .color = text_color,
                    .text = try std.fmt.bufPrint(buffer, "{}", .{gem_count}),
                },
            },
        };
    }

    fn getBillboardCount(self: GemCountInfo) usize {
        return 1 + // Gem icon.
            text_rendering.getBillboardCount(&self.segments);
    }

    fn populateBillboardData(
        self: GemCountInfo,
        screen_dimensions: ScreenDimensions,
        sprite_sheet: SpriteSheetTexture,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        const font_size = SpriteSheetTexture.getFontSizeMultiple(4);
        const font_size_f32 = @as(f32, @floatFromInt(font_size));
        const font_letter_spacing = SpriteSheetTexture.getFontLetterSpacing(font_size_f32);
        const text_dimensions = text_rendering.getTextBlockDimensions(&self.segments, font_size_f32);

        // Place gem icon on screen.
        const source = sprite_sheet.getSpriteTexcoords(.gem);
        const source_dimensions = sprite_sheet.getSpriteDimensionsInPixels(.gem);
        const multiple = 3;
        const dimensions = .{
            .w = @as(f32, @floatFromInt(source_dimensions.w)) * multiple,
            .h = @as(f32, @floatFromInt(source_dimensions.h)) * multiple,
        };
        const spacing = .{
            .horizontal = font_letter_spacing.horizontal,
            .vertical = font_letter_spacing.vertical,
        };
        out[0] = .{
            .position = .{
                .x = spacing.horizontal * 2 + dimensions.w / 2,
                .y = @as(f32, @floatFromInt(screen_dimensions.height)) -
                    spacing.vertical - dimensions.h / 2,
                .z = 0,
            },
            .size = .{ .w = dimensions.w, .h = dimensions.h },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
        };

        text_rendering.populateBillboardData2d(
            &self.segments,
            @as(u16, @intFromFloat(spacing.horizontal * 3 + out[0].size.w)),
            screen_dimensions.height - @as(u16, @intFromFloat(text_dimensions.height)),
            font_size,
            sprite_sheet,
            out[1..],
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
            SpriteSheetTexture.getFontSizeMultiple(2),
            sprite_sheet,
            out,
        );
    }
};
