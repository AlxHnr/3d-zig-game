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
    dialog_stack: std.ArrayList(Dialog),

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
            .dialog_stack = std.ArrayList(Dialog).init(allocator),
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

    pub const Command = enum { cancel, confirm, next, previous };

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
        try self.dialog_stack.append(.{ .prompt = prompt });
    }

    pub fn openNpcChoiceBox(
        self: *Controller,
        npc_name: []const u8,
        message_text: []const u8,
        choice_texts: []const []const u8,
    ) !void {
        var choice_box = try ChoiceBox.create(
            self.allocator,
            self.spritesheet,
            npc_name,
            message_text,
            choice_texts,
        );
        errdefer choice_box.destroy(self.allocator);
        try self.dialog_stack.append(.{ .choice_box = choice_box });
    }
};

/// Polymorphic dispatcher serving as an interface.
const Dialog = union(enum) {
    prompt: Prompt,
    choice_box: ChoiceBox,

    pub fn destroy(self: *Dialog, allocator: std.mem.Allocator) void {
        return switch (self.*) {
            inline else => |*subtype| subtype.destroy(allocator),
        };
    }

    pub fn processElapsedTick(self: *Dialog) bool {
        return switch (self.*) {
            inline else => |*subtype| subtype.processElapsedTick(),
        };
    }

    pub fn prepareRender(
        self: *Dialog,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        return switch (self.*) {
            inline else => |*subtype| subtype.prepareRender(
                allocator,
                interval_between_previous_and_current_tick,
            ),
        };
    }

    pub fn getBillboardCount(self: Dialog) usize {
        return switch (self) {
            inline else => |subtype| subtype.getBillboardCount(),
        };
    }

    pub fn populateBillboardData(
        self: Dialog,
        screen_dimensions: util.ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        return switch (self) {
            inline else => |subtype| subtype.populateBillboardData(
                screen_dimensions,
                interval_between_previous_and_current_tick,
                out,
            ),
        };
    }

    pub fn processCommand(self: *Dialog, command: Controller.Command) void {
        return switch (self.*) {
            inline else => |*subtype| subtype.processCommand(command),
        };
    }
};

const Prompt = struct {
    text_block: PackagedAnimatedTextBlock,
    slide_in_animation_box: SlideInAnimationBox,

    pub const sample_content =
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
        const npc_header = wrapNpcDialog(npc_name, message_text);
        const text_block =
            try makePackagedAnimatedTextBlock(allocator, spritesheet, &npc_header, sample_content);
        return .{
            .text_block = text_block,
            .slide_in_animation_box = SlideInAnimationBox.wrap(
                text_block.minimum_size_widget,
                spritesheet,
            ),
        };
    }

    pub fn destroy(self: *Prompt, allocator: std.mem.Allocator) void {
        freePackagedAnimatedTextBlock(allocator, &self.text_block);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *Prompt) bool {
        self.slide_in_animation_box.processElapsedTick();
        if (!self.slide_in_animation_box.isStillOpening()) {
            self.text_block.animated_text_block.processElapsedTick();
        }

        return !self.slide_in_animation_box.hasClosed();
    }

    pub fn prepareRender(
        self: *Prompt,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        try self.text_block.animated_text_block.prepareRender(
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
        if (command != .cancel and command != .confirm) {
            return;
        }
        if (!self.text_block.animated_text_block.hasFinished()) {
            return;
        }

        self.slide_in_animation_box.startClosingIfOpen();
    }
};

const ChoiceBox = struct {
    /// Contains the npc dialog header at index 0 and all the choice text blocks after it, in order.
    text_blocks: []PackagedAnimatedTextBlock,
    /// Wrapper around the content in `text_blocks`. Each block in `text_block` will be wrapped in
    /// either in a ui.Box when currently selected, or in a ui.Spacing wrapper when not selected.
    widget_list: []ui.Widget,
    /// Wrapper around `widget_list`.
    split_widget: *ui.Widget,
    /// Wrapper around `split_widget`.
    slide_in_animation_box: SlideInAnimationBox,

    active_widget_index: usize,

    /// Non-owning wrapper.
    spritesheet: *const SpriteSheetTexture,

    const sample_selection = "| Fits into Prompt.sample_content  |";

    pub fn create(
        allocator: std.mem.Allocator,
        /// Returned object will keep a reference to this spritesheet.
        spritesheet: *const SpriteSheetTexture,
        npc_name: []const u8,
        message_text: []const u8,
        choice_texts: []const []const u8,
    ) !ChoiceBox {
        var text_blocks: []PackagedAnimatedTextBlock = &.{};
        errdefer freeAllTextBlocks(allocator, text_blocks);

        {
            var first_line_iterator = std.mem.tokenizeAny(u8, Prompt.sample_content, "\n");
            var npc_header = try makePackagedAnimatedTextBlock(
                allocator,
                spritesheet,
                &wrapNpcDialog(npc_name, message_text),
                // Align only based on first line.
                first_line_iterator.next().?,
            );
            errdefer freePackagedAnimatedTextBlock(allocator, &npc_header);

            text_blocks = try appendTextBlock(allocator, text_blocks, npc_header);
        }

        for (choice_texts) |choice_text| {
            text_blocks = try appendChoiceText(allocator, text_blocks, choice_text, spritesheet);
        }
        text_blocks = try appendChoiceText(allocator, text_blocks, "Cancel", spritesheet);

        var widget_list = try allocator.alloc(ui.Widget, text_blocks.len);
        errdefer allocator.free(widget_list);

        const cancel_choice_index = text_blocks.len - 1;
        putBoxAroundSelection(text_blocks, cancel_choice_index, spritesheet, widget_list);

        var split_widget = try allocator.create(ui.Widget);
        errdefer allocator.destroy(split_widget);
        split_widget.* = .{ .split = ui.Split.wrap(.horizontal, widget_list) };

        return .{
            .text_blocks = text_blocks,
            .widget_list = widget_list,
            .split_widget = split_widget,
            .slide_in_animation_box = SlideInAnimationBox.wrap(split_widget, spritesheet),
            .active_widget_index = cancel_choice_index,
            .spritesheet = spritesheet,
        };
    }

    pub fn destroy(self: *ChoiceBox, allocator: std.mem.Allocator) void {
        allocator.destroy(self.split_widget);
        allocator.free(self.widget_list);
        freeAllTextBlocks(allocator, self.text_blocks[0..]);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *ChoiceBox) bool {
        self.slide_in_animation_box.processElapsedTick();
        if (!self.slide_in_animation_box.isStillOpening()) {
            for (self.text_blocks) |*text_block| {
                text_block.animated_text_block.processElapsedTick();
            }
        }

        return !self.slide_in_animation_box.hasClosed();
    }

    pub fn prepareRender(
        self: *ChoiceBox,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        for (self.text_blocks) |*text_block| {
            try text_block.animated_text_block.prepareRender(
                allocator,
                interval_between_previous_and_current_tick,
            );
        }
    }

    pub fn getBillboardCount(self: ChoiceBox) usize {
        return self.slide_in_animation_box.getBillboardCount();
    }

    pub fn populateBillboardData(
        self: ChoiceBox,
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

    pub fn processCommand(self: *ChoiceBox, command: Controller.Command) void {
        for (self.text_blocks) |text_block| {
            if (!text_block.animated_text_block.hasFinished()) {
                return;
            }
        }

        switch (command) {
            .cancel, .confirm => self.slide_in_animation_box.startClosingIfOpen(),
            .next => {
                if (self.active_widget_index < self.text_blocks.len - 1) {
                    self.active_widget_index += 1;
                }
                putBoxAroundSelection(
                    self.text_blocks,
                    self.active_widget_index,
                    self.spritesheet,
                    self.widget_list,
                );
            },
            .previous => {
                if (self.active_widget_index > 1) { // First block is the NPC header.
                    self.active_widget_index -= 1;
                }
                putBoxAroundSelection(
                    self.text_blocks,
                    self.active_widget_index,
                    self.spritesheet,
                    self.widget_list,
                );
            },
        }
    }

    fn appendTextBlock(
        allocator: std.mem.Allocator,
        text_blocks: []PackagedAnimatedTextBlock,
        text_block: PackagedAnimatedTextBlock,
    ) ![]PackagedAnimatedTextBlock {
        var result = try allocator.realloc(text_blocks, text_blocks.len + 1);
        result[result.len - 1] = text_block;
        return result;
    }

    fn appendChoiceText(
        allocator: std.mem.Allocator,
        text_blocks: []PackagedAnimatedTextBlock,
        choice_text: []const u8,
        spritesheet: *const SpriteSheetTexture,
    ) ![]PackagedAnimatedTextBlock {
        var text_block = try makePackagedAnimatedTextBlock(
            allocator,
            spritesheet,
            &.{ui.Highlight.selectableChoice(choice_text)},
            sample_selection,
        );
        errdefer freePackagedAnimatedTextBlock(allocator, &text_block);
        return try appendTextBlock(allocator, text_blocks, text_block);
    }

    fn freeAllTextBlocks(
        allocator: std.mem.Allocator,
        text_blocks: []PackagedAnimatedTextBlock,
    ) void {
        for (text_blocks) |*text_block| {
            freePackagedAnimatedTextBlock(allocator, text_block);
        }
        allocator.free(text_blocks);
    }

    fn putBoxAroundSelection(
        text_blocks: []const PackagedAnimatedTextBlock,
        selection_index: usize,
        spritesheet: *const SpriteSheetTexture,
        out_text_block_wrapper_list: []ui.Widget,
    ) void {
        for (text_blocks, 0..) |_, index| {
            const wrapper_box = ui.Box.wrap(text_blocks[index].minimum_size_widget, spritesheet);
            if (index == 0) {
                // Preserve NPC dialog header.
                out_text_block_wrapper_list[index] = text_blocks[index].minimum_size_widget.*;
            } else if (index == selection_index) {
                out_text_block_wrapper_list[index] = .{ .box = wrapper_box };
            } else {
                const box_frame_dimensions = wrapper_box.getFrameDimensionsWithoutContent();
                out_text_block_wrapper_list[index] = .{
                    .spacing = ui.Spacing.wrapFixedPixels(
                        text_blocks[index].minimum_size_widget,
                        box_frame_dimensions.width / 2,
                        box_frame_dimensions.height / 2,
                    ),
                };
            }
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
            screen_dimensions.height - math.scaleU16(dimensions.height, window_open_interval),
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
            .text = ui.Text.wrap(&.{}, spritesheet, dialog_text_scale),
        };

        return .{
            .original_segments = segments,
            .segments_in_current_frame = &.{},
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

fn wrapNpcDialog(npc_name: []const u8, message_text: []const u8) [3]text_rendering.TextSegment {
    return .{
        ui.Highlight.npcName(npc_name),
        ui.Highlight.normal("\n\n"),
        ui.Highlight.normal(message_text),
    };
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
    text_block: []const text_rendering.TextSegment,
    sample_content: []const u8,
) !PackagedAnimatedTextBlock {
    const max_line_length =
        std.mem.indexOfScalar(u8, sample_content, '\n') orelse sample_content.len;

    var reformatted_segments =
        try text_rendering.reflowTextBlock(allocator, text_block, max_line_length);
    errdefer text_rendering.freeTextSegments(allocator, reformatted_segments);

    var animated_text_block =
        try AnimatedTextBlock.wrap(allocator, reformatted_segments, spritesheet);
    errdefer animated_text_block.destroy(allocator);

    const dimensions = ui.Text.wrap(reformatted_segments, spritesheet, dialog_text_scale)
        .getDimensionsInPixels();
    const sample_dimensions = ui.Text.wrap(
        &.{ui.Highlight.normal(sample_content)},
        spritesheet,
        dialog_text_scale,
    ).getDimensionsInPixels();

    var minimum_size_widget = try allocator.create(ui.Widget);
    errdefer allocator.destroy(minimum_size_widget);
    minimum_size_widget.* = .{ .minimum_size = ui.MinimumSize.wrap(
        animated_text_block.getWidgetPointer(),
        @max(dimensions.width, sample_dimensions.width),
        @max(dimensions.height, sample_dimensions.height),
    ) };

    return .{
        .reformatted_segments = reformatted_segments,
        .animated_text_block = animated_text_block,
        .minimum_size_widget = minimum_size_widget,
    };
}

fn freePackagedAnimatedTextBlock(
    allocator: std.mem.Allocator,
    text_block: *PackagedAnimatedTextBlock,
) void {
    allocator.destroy(text_block.minimum_size_widget);
    text_block.animated_text_block.destroy(allocator);
    text_rendering.freeTextSegments(allocator, text_block.reformatted_segments);
}
