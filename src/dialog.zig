const BillboardRenderer = @import("rendering.zig").BillboardRenderer;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const math = @import("math.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");

const dialog_text_scale = 2;

/// Stores, renders and dispatches input to dialogs.
pub const Controller = struct {
    /// Non-owning reference.
    allocator: std.mem.Allocator,
    renderer: BillboardRenderer,
    billboard_buffer: []BillboardRenderer.BillboardData,
    spritesheet: *SpriteSheetTexture,
    dialog_stack: std.ArrayList(Prompt),

    pub fn create(allocator: std.mem.Allocator) !Controller {
        var renderer = try BillboardRenderer.create();
        errdefer renderer.destroy();

        var spritesheet = try allocator.create(SpriteSheetTexture);
        errdefer allocator.destroy(spritesheet);
        spritesheet.* = try SpriteSheetTexture.loadFromDisk();
        errdefer spritesheet.destroy();

        return .{
            .allocator = allocator,
            .renderer = renderer,
            .billboard_buffer = &.{},
            .spritesheet = spritesheet,
            .dialog_stack = std.ArrayList(Prompt).init(allocator),
        };
    }

    pub fn destroy(self: *Controller) void {
        for (self.dialog_stack.items) |*dialog| {
            dialog.destroy(self.allocator);
        }
        self.dialog_stack.deinit();
        self.spritesheet.destroy();
        self.allocator.destroy(self.spritesheet);
        self.allocator.free(self.billboard_buffer);
        self.renderer.destroy();
    }

    pub fn render(
        self: *Controller,
        screen_dimensions: util.ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        var total_billboards: usize = 0;
        for (self.dialog_stack.items) |*dialog| {
            try dialog.prepareRender(self.allocator, interval_between_previous_and_current_tick);
            total_billboards += dialog.getBillboardCount();
        }

        if (self.billboard_buffer.len < total_billboards) {
            self.billboard_buffer =
                try self.allocator.realloc(self.billboard_buffer, total_billboards);
        }

        var start: usize = 0;
        var end: usize = 0;
        for (self.dialog_stack.items) |dialog| {
            start = end;
            end += dialog.getBillboardCount();
            dialog.populateBillboardData(
                screen_dimensions,
                interval_between_previous_and_current_tick,
                self.billboard_buffer[start..end],
            );
        }
        self.renderer.uploadBillboards(self.billboard_buffer[0..end]);
        self.renderer.render2d(screen_dimensions, self.spritesheet.id);
    }

    pub fn processElapsedTick(self: *Controller) void {
        var index: usize = 0;
        var dialogs_total = self.dialog_stack.items.len;

        while (index < dialogs_total) {
            if (!self.dialog_stack.items[index].processElapsedTick()) {
                self.dialog_stack.items[index].destroy(self.allocator);
                _ = self.dialog_stack.orderedRemove(index);
                dialogs_total -= 1;
            } else {
                index += 1;
            }
        }
    }

    pub const Command = enum { cancel, confirm };

    /// Will do nothing if there is no current dialog.
    pub fn sendCommandToCurrentDialog(self: *Controller, command: Command) void {
        if (self.hasOpenDialogs()) {
            self.dialog_stack.items[self.dialog_stack.items.len - 1]
                .processCommand(command);
        }
    }

    pub fn hasOpenDialogs(self: Controller) bool {
        return self.dialog_stack.items.len > 0;
    }

    pub fn openNpcDialog(self: *Controller, npc_name: []const u8, message_text: []const u8) !void {
        var prompt = try Prompt.create(self.allocator, self.spritesheet, npc_name, message_text);
        errdefer prompt.destroy(self.allocator);
        try self.dialog_stack.append(prompt);
    }
};

const Prompt = struct {
    reformatted_segments: []text_rendering.TextSegment,
    animated_text_block: AnimatedTextBlock,
    minimum_size_widget: *ui.Widget,
    slide_in_animation_box: SlideInAnimationBox,

    const sample_content =
        \\,------------------------------------,
        \\| This is a sample text box which is |
        \\| used as a template for formatting  |
        \\| and aligning all dialog prompts.   |
        \\| The borders here are also valid    |
        \\| space for potential letters.       |
        \\|____________________________________|
    ;

    pub fn create(
        allocator: std.mem.Allocator,
        /// Returned object will keep a reference to this spritesheet.
        spritesheet: *const SpriteSheetTexture,
        npc_name: []const u8,
        message_text: []const u8,
    ) !Prompt {
        const npc_header = try makePackagedAnimatedTextBlock(
            allocator,
            spritesheet,
            npc_name,
            message_text,
            sample_content,
        );
        return .{
            .reformatted_segments = npc_header.reformatted_segments,
            .animated_text_block = npc_header.animated_text_block,
            .minimum_size_widget = npc_header.minimum_size_widget,
            .slide_in_animation_box = SlideInAnimationBox.wrap(
                npc_header.minimum_size_widget,
                spritesheet,
            ),
        };
    }

    pub fn destroy(self: *Prompt, allocator: std.mem.Allocator) void {
        allocator.destroy(self.minimum_size_widget);
        self.animated_text_block.destroy(allocator);
        text_rendering.freeTextSegments(allocator, self.reformatted_segments);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *Prompt) bool {
        self.slide_in_animation_box.processElapsedTick();
        if (!self.slide_in_animation_box.isStillOpening()) {
            self.animated_text_block.processElapsedTick();
        }

        return !self.slide_in_animation_box.hasClosed();
    }

    pub fn prepareRender(
        self: *Prompt,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        try self.animated_text_block.prepareRender(
            allocator,
            interval_between_previous_and_current_tick,
        );
    }

    pub fn getBillboardCount(self: Prompt) usize {
        return self.slide_in_animation_box.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: Prompt,
        screen_dimensions: util.ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        self.slide_in_animation_box.populateBillboardData(
            screen_dimensions,
            interval_between_previous_and_current_tick,
            out,
        );
    }

    pub fn processCommand(self: *Prompt, command: Controller.Command) void {
        _ = command;
        if (self.animated_text_block.hasFinished()) {
            self.slide_in_animation_box.startClosingIfOpen();
        }
    }
};

/// UI box which slides in from the bottom.
const SlideInAnimationBox = struct {
    widget: ui.Widget,
    state: State,
    movement_animation: AnimationState,

    pub const State = enum { opening, open, closing, closed };

    /// Returned object will keep a reference to the given pointers.
    pub fn wrap(
        widget_to_wrap: *const ui.Widget,
        spritesheet: *const SpriteSheetTexture,
    ) SlideInAnimationBox {
        return .{
            .widget = .{ .box = ui.Box.wrap(widget_to_wrap, spritesheet) },
            .state = .opening,
            .movement_animation = AnimationState.create(0, 1),
        };
    }

    pub fn processElapsedTick(self: *SlideInAnimationBox) void {
        self.movement_animation.processElapsedTick(0.2);

        switch (self.state) {
            .opening, .closing => {
                if (self.movement_animation.hasFinished()) {
                    self.state = util.getNextEnumWrapAround(self.state);
                }
            },
            .open, .closed => {},
        }
    }

    pub fn isStillOpening(self: SlideInAnimationBox) bool {
        return self.state == .opening;
    }

    pub fn hasClosed(self: SlideInAnimationBox) bool {
        return self.state == .closed;
    }

    pub fn startClosingIfOpen(self: *SlideInAnimationBox) void {
        if (self.state == .open) {
            self.state = .closing;
            self.movement_animation.reset();
        }
    }

    pub fn getBillboardCount(self: SlideInAnimationBox) usize {
        return self.widget.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: SlideInAnimationBox,
        screen_dimensions: util.ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        const raw_interval =
            self.movement_animation.getInterval(interval_between_previous_and_current_tick);
        // Value from 0 (closed) to 1 (fully open).
        const window_open_interval = switch (self.state) {
            .open => raw_interval,
            .opening => raw_interval,
            .closing => 1 - raw_interval,
            .closed => 1 - raw_interval,
        };
        const dimensions = self.widget.getDimensionsInPixels();
        self.widget.populateBillboardData(
            screen_dimensions.width / 2 - dimensions.width / 2,
            screen_dimensions.height - scale(dimensions.height, window_open_interval),
            out,
        );
    }
};

/// Reveals a text block character by character.
const AnimatedTextBlock = struct {
    /// Non-owning slice.
    original_segments: []const text_rendering.TextSegment,
    segments_in_current_frame: []text_rendering.TextSegment,
    spritesheet: *const SpriteSheetTexture,
    codepoint_progress: AnimationState,
    widget: *ui.Widget,

    /// Returned object will keep a reference to the given slices and pointers.
    pub fn wrap(
        allocator: std.mem.Allocator,
        segments: []const text_rendering.TextSegment,
        spritesheet: *const SpriteSheetTexture,
    ) !AnimatedTextBlock {
        var widget = try allocator.create(ui.Widget);
        errdefer allocator.destroy(widget);
        widget.* = .{
            .text = ui.Text.wrap(&[_]text_rendering.TextSegment{}, spritesheet, dialog_text_scale),
        };

        return .{
            .original_segments = segments,
            .segments_in_current_frame = &[_]text_rendering.TextSegment{},
            .spritesheet = spritesheet,
            .codepoint_progress = AnimationState.create(
                0,
                @as(f32, @floatFromInt(try countCodepoints(segments))),
            ),
            .widget = widget,
        };
    }

    pub fn destroy(self: *AnimatedTextBlock, allocator: std.mem.Allocator) void {
        allocator.destroy(self.widget);
        text_rendering.freeTextSegments(allocator, self.segments_in_current_frame);
    }

    /// Returned widget will be invalidated when destroy() is being called on the given text block.
    pub fn getWidgetPointer(self: AnimatedTextBlock) *ui.Widget {
        return self.widget;
    }

    pub fn processElapsedTick(self: *AnimatedTextBlock) void {
        const reveal_codepoints_per_tick = 3;
        self.codepoint_progress.processElapsedTick(reveal_codepoints_per_tick);
    }

    pub fn hasFinished(self: AnimatedTextBlock) bool {
        return self.codepoint_progress.hasFinished();
    }

    pub fn prepareRender(
        self: *AnimatedTextBlock,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        const codepoints_to_reveal = @as(usize, @intFromFloat(
            self.codepoint_progress.getInterval(interval_between_previous_and_current_tick),
        ));

        const segments_in_current_frame = try text_rendering.truncateTextSegments(
            allocator,
            self.original_segments,
            codepoints_to_reveal,
        );
        errdefer text_rendering.freeTextSegments(allocator, segments_in_current_frame);

        self.widget.* = .{
            .text = ui.Text.wrap(segments_in_current_frame, self.spritesheet, dialog_text_scale),
        };
        text_rendering.freeTextSegments(allocator, self.segments_in_current_frame);
        self.segments_in_current_frame = segments_in_current_frame;
    }

    pub fn getBillboardCount(self: AnimatedTextBlock) usize {
        return self.widget.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: AnimatedTextBlock,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        self.widget.populateBillboardData(screen_position_x, screen_position_y, out);
    }

    fn countCodepoints(segments: []const text_rendering.TextSegment) !usize {
        var result: usize = 0;
        for (segments) |segment| {
            result += try std.unicode.utf8CountCodepoints(segment.text);
        }
        return result;
    }
};

const AnimationState = struct {
    at_previous_tick: f32,
    at_next_tick: f32,
    start_value: f32,
    end_value: f32,

    pub fn create(start_value: f32, end_value: f32) AnimationState {
        return .{
            .at_previous_tick = start_value,
            .at_next_tick = start_value,
            .start_value = start_value,
            .end_value = end_value,
        };
    }

    pub fn processElapsedTick(self: *AnimationState, step: f32) void {
        self.at_previous_tick = self.at_next_tick;
        self.at_next_tick = std.math.clamp(
            self.at_next_tick + step,
            self.start_value,
            self.end_value,
        );
    }

    pub fn reset(self: *AnimationState) void {
        self.* = AnimationState.create(self.start_value, self.end_value);
    }

    pub fn hasFinished(self: AnimationState) bool {
        return math.isEqual(self.at_previous_tick, self.end_value);
    }

    pub fn getInterval(self: AnimationState, interval_between_previous_and_current_tick: f32) f32 {
        return math.lerp(
            self.at_previous_tick,
            self.at_next_tick,
            interval_between_previous_and_current_tick,
        );
    }
};

fn scale(value: u16, factor: f32) u16 {
    return @as(u16, @intFromFloat(@as(f32, @floatFromInt(value)) * factor));
}

const PackagedAnimatedTextBlock = struct {
    reformatted_segments: []text_rendering.TextSegment,
    animated_text_block: AnimatedTextBlock,
    minimum_size_widget: *ui.Widget,
};

fn makePackagedAnimatedTextBlock(
    allocator: std.mem.Allocator,
    /// Returned object will keep a reference to this spritesheet.
    spritesheet: *const SpriteSheetTexture,
    npc_name: []const u8,
    message_text: []const u8,
    sample_content: []const u8,
) !PackagedAnimatedTextBlock {
    const max_line_length = std.mem.indexOfScalar(u8, sample_content, '\n').?;

    const text_block = [_]text_rendering.TextSegment{
        ui.Highlight.npcName(npc_name),
        ui.Highlight.normal("\n\n"),
        ui.Highlight.normal(message_text),
    };

    var reformatted_segments =
        try text_rendering.reflowTextBlock(allocator, &text_block, max_line_length);
    errdefer text_rendering.freeTextSegments(allocator, reformatted_segments);

    var animated_text_block =
        try AnimatedTextBlock.wrap(allocator, reformatted_segments, spritesheet);
    errdefer animated_text_block.destroy(allocator);

    const minimum = ui.Text.wrap(
        &[_]text_rendering.TextSegment{ui.Highlight.normal(sample_content)},
        spritesheet,
        dialog_text_scale,
    ).getDimensionsInPixels();

    var minimum_size_widget = try allocator.create(ui.Widget);
    errdefer allocator.destroy(minimum_size_widget);
    minimum_size_widget.* = .{ .minimum_size = ui.MinimumSize.wrap(
        animated_text_block.getWidgetPointer(),
        minimum.width,
        minimum.height,
    ) };

    return .{
        .reformatted_segments = reformatted_segments,
        .animated_text_block = animated_text_block,
        .minimum_size_widget = minimum_size_widget,
    };
}
