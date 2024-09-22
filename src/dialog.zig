const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const fp = math.Fix32.fp;
const math = @import("math.zig");
const rendering = @import("rendering.zig");
const simulation = @import("simulation.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");

const dialog_text_scale = 2;

/// Stores, renders and dispatches input to dialogs. Thread safe.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    sprite_buffer: []rendering.SpriteData,
    spritesheet: *SpriteSheetTexture,
    dialog_stack: std.ArrayList(Dialog),

    pub fn create(allocator: std.mem.Allocator) !Controller {
        var spritesheet = try allocator.create(SpriteSheetTexture);
        errdefer allocator.destroy(spritesheet);
        spritesheet.* = try SpriteSheetTexture.loadFromDisk();
        errdefer spritesheet.destroy();

        return .{
            .allocator = allocator,
            .mutex = .{},
            .sprite_buffer = &.{},
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
        self.allocator.free(self.sprite_buffer);
    }

    pub fn render(
        self: *Controller,
        renderer: *rendering.SpriteRenderer,
        screen_dimensions: rendering.ScreenDimensions,
        previous_tick: u32,
        interval_between_previous_and_current_tick: math.Fix32,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_sprites: usize = 0;
        for (self.dialog_stack.items) |*dialog| {
            try dialog.prepareRender(interval_between_previous_and_current_tick);
            total_sprites += dialog.getSpriteCount();
        }

        if (self.sprite_buffer.len < total_sprites) {
            self.sprite_buffer =
                try self.allocator.realloc(self.sprite_buffer, total_sprites);
        }

        var start: usize = 0;
        var end: usize = 0;
        for (self.dialog_stack.items) |dialog| {
            start = end;
            end += dialog.getSpriteCount();
            dialog.populateSpriteData(
                screen_dimensions,
                interval_between_previous_and_current_tick,
                self.sprite_buffer[start..end],
            );
        }
        renderer.uploadSprites(self.sprite_buffer[0..end]);
        renderer.render(
            screen_dimensions,
            self.spritesheet.id,
            previous_tick,
            interval_between_previous_and_current_tick,
        );
    }

    pub fn processElapsedTick(self: *Controller) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.dialog_stack.items.len > 0) {
            self.dialog_stack.items[self.dialog_stack.items.len - 1]
                .processCommand(command);
        }
    }

    pub fn hasOpenDialogs(self: *Controller) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.dialog_stack.items.len > 0;
    }

    pub fn openNpcDialog(self: *Controller, npc_name: []const u8, message_text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

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
        interval_between_previous_and_current_tick: math.Fix32,
    ) !void {
        return switch (self.*) {
            inline else => |*subtype| subtype.prepareRender(
                interval_between_previous_and_current_tick,
            ),
        };
    }

    pub fn getSpriteCount(self: Dialog) usize {
        return switch (self) {
            inline else => |subtype| subtype.getSpriteCount(),
        };
    }

    pub fn populateSpriteData(
        self: Dialog,
        screen_dimensions: rendering.ScreenDimensions,
        interval_between_previous_and_current_tick: math.Fix32,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        return switch (self) {
            inline else => |subtype| subtype.populateSpriteData(
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
        interval_between_previous_and_current_tick: math.Fix32,
    ) !void {
        try self.text_block.animated_text_block.prepareRender(
            interval_between_previous_and_current_tick,
        );
    }

    pub fn getSpriteCount(self: Prompt) usize {
        return self.slide_in_animation_box.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: Prompt,
        screen_dimensions: rendering.ScreenDimensions,
        interval_between_previous_and_current_tick: math.Fix32,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        self.slide_in_animation_box.populateSpriteData(
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
        var text_blocks = try createBoxHeaders(allocator, spritesheet, npc_name, message_text);
        errdefer freeAllTextBlocks(allocator, text_blocks);

        for (choice_texts) |choice_text| {
            text_blocks = try appendChoiceText(
                allocator,
                text_blocks,
                choice_text,
                spritesheet,
                ui.Highlight.selectableChoice,
            );
        }
        text_blocks = try appendChoiceText(
            allocator,
            text_blocks,
            "Cancel",
            spritesheet,
            ui.Highlight.cancelChoice,
        );

        const widget_list = try allocator.alloc(ui.Widget, text_blocks.len);
        errdefer allocator.free(widget_list);
        putBoxAroundSelection(
            text_blocks,
            text_blocks.len, // This ensures that the box opens without selections.
            spritesheet,
            widget_list,
        );

        const split_widget = try allocator.create(ui.Widget);
        errdefer allocator.destroy(split_widget);
        split_widget.* = .{ .split = ui.Split.wrap(.horizontal, widget_list) };

        return .{
            .text_blocks = text_blocks,
            .widget_list = widget_list,
            .split_widget = split_widget,
            .slide_in_animation_box = SlideInAnimationBox.wrap(split_widget, spritesheet),
            .active_widget_index = text_blocks.len - 1, // Preselect cancel section.
            .spritesheet = spritesheet,
        };
    }

    pub fn destroy(self: *ChoiceBox, allocator: std.mem.Allocator) void {
        allocator.destroy(self.split_widget);
        allocator.free(self.widget_list);
        freeAllTextBlocks(allocator, self.text_blocks);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *ChoiceBox) bool {
        self.slide_in_animation_box.processElapsedTick();
        if (self.slide_in_animation_box.isStillOpening()) {
            return true;
        }

        var all_text_boxes_are_on_screen = true;
        for (self.text_blocks) |*text_block| {
            text_block.animated_text_block.processElapsedTick();
            if (!text_block.animated_text_block.hasFinished()) {
                all_text_boxes_are_on_screen = false;
                break;
            }
        }
        if (all_text_boxes_are_on_screen) {
            putBoxAroundSelection(
                self.text_blocks,
                self.active_widget_index,
                self.spritesheet,
                self.widget_list,
            );
        }

        return !self.slide_in_animation_box.hasClosed();
    }

    pub fn prepareRender(
        self: *ChoiceBox,
        interval_between_previous_and_current_tick: math.Fix32,
    ) !void {
        for (self.text_blocks) |*text_block| {
            try text_block.animated_text_block.prepareRender(
                interval_between_previous_and_current_tick,
            );
        }
    }

    pub fn getSpriteCount(self: ChoiceBox) usize {
        return self.slide_in_animation_box.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: ChoiceBox,
        screen_dimensions: rendering.ScreenDimensions,
        interval_between_previous_and_current_tick: math.Fix32,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        self.slide_in_animation_box.populateSpriteData(
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
            },
            .previous => {
                if (self.active_widget_index > 2) { // First two blocks are dialog.
                    self.active_widget_index -= 1;
                }
            },
        }
    }

    fn createBoxHeaders(
        allocator: std.mem.Allocator,
        spritesheet: *const SpriteSheetTexture,
        npc_name: []const u8,
        message_text: []const u8,
    ) ![]PackagedAnimatedTextBlock {
        var result: []PackagedAnimatedTextBlock = &.{};
        errdefer freeAllTextBlocks(allocator, result);

        const box_headers = [_][]const text_rendering.TextSegment{
            &wrapNpcDialog(npc_name, message_text),
            &.{ui.Highlight.normal("")},
        };
        for (box_headers) |box_header| {
            var first_line_iterator = std.mem.tokenizeAny(u8, Prompt.sample_content, "\n");
            var npc_header = try makePackagedAnimatedTextBlock(
                allocator,
                spritesheet,
                box_header,
                first_line_iterator.next().?,
            );
            errdefer freePackagedAnimatedTextBlock(allocator, &npc_header);

            result = try appendTextBlock(allocator, result, npc_header);
        }
        return result;
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
        highlight_function: *const fn (text: []const u8) text_rendering.TextSegment,
    ) ![]PackagedAnimatedTextBlock {
        var text_block = try makePackagedAnimatedTextBlock(
            allocator,
            spritesheet,
            &.{highlight_function(choice_text)},
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
            if (index < 2) {
                // Preserve fixed dialogs.
                out_text_block_wrapper_list[index] = text_blocks[index].minimum_size_widget.*;
            } else if (index == selection_index) {
                out_text_block_wrapper_list[index] = .{ .box = wrapper_box };
            } else {
                const box_frame_dimensions = wrapper_box.getFrameDimensionsWithoutContent();
                out_text_block_wrapper_list[index] = .{
                    .spacing = ui.Spacing.wrapFixedPixels(
                        text_blocks[index].minimum_size_widget,
                        box_frame_dimensions.w / 2,
                        box_frame_dimensions.h / 2,
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
            .movement_animation = AnimationState.create(fp(0), fp(1)),
        };
    }

    pub fn processElapsedTick(self: *SlideInAnimationBox) void {
        self.movement_animation.processElapsedTick(simulation.kphToGameUnitsPerTick(43.2));

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

    pub fn getSpriteCount(self: SlideInAnimationBox) usize {
        return self.widget.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: SlideInAnimationBox,
        screen_dimensions: rendering.ScreenDimensions,
        interval_between_previous_and_current_tick: math.Fix32,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        const raw_interval =
            self.movement_animation.getInterval(interval_between_previous_and_current_tick);
        // Value from 0 (closed) to 1 (fully open).
        const window_open_interval = switch (self.state) {
            .open => raw_interval,
            .opening => raw_interval,
            .closing => fp(1).sub(raw_interval),
            .closed => fp(1).sub(raw_interval),
        };
        const dimensions = self.widget.getDimensionsInPixels();
        self.widget.populateSpriteData(
            screen_dimensions.w / 2 - dimensions.w / 2,
            screen_dimensions.h -
                fp(dimensions.h).mul(window_open_interval).convertTo(u16),
            out,
        );
    }
};

/// Reveals a text block character by character.
const AnimatedTextBlock = struct {
    original_segments: []const text_rendering.TextSegment,
    reusable_buffer: text_rendering.ReusableBuffer,
    spritesheet: *const SpriteSheetTexture,
    codepoint_progress: AnimationState,
    widget: *ui.Widget,

    /// Returned object will keep a reference to the given slices and pointers.
    pub fn wrap(
        allocator: std.mem.Allocator,
        segments: []const text_rendering.TextSegment,
        spritesheet: *const SpriteSheetTexture,
    ) !AnimatedTextBlock {
        const widget = try allocator.create(ui.Widget);
        errdefer allocator.destroy(widget);
        widget.* = .{
            .text = ui.Text.wrap(&.{}, spritesheet, dialog_text_scale),
        };

        return .{
            .original_segments = segments,
            .reusable_buffer = text_rendering.ReusableBuffer.create(allocator),
            .spritesheet = spritesheet,
            .codepoint_progress = AnimationState.create(fp(0), fp(try countCodepoints(segments))),
            .widget = widget,
        };
    }

    pub fn destroy(self: *AnimatedTextBlock, allocator: std.mem.Allocator) void {
        self.reusable_buffer.destroy();
        allocator.destroy(self.widget);
    }

    /// Returned widget will be invalidated when destroy() is being called on the given text block.
    pub fn getWidgetPointer(self: AnimatedTextBlock) *ui.Widget {
        return self.widget;
    }

    pub fn processElapsedTick(self: *AnimatedTextBlock) void {
        const reveal_codepoints_per_tick = simulation.kphToGameUnitsPerTick(648);
        self.codepoint_progress.processElapsedTick(reveal_codepoints_per_tick);
    }

    pub fn hasFinished(self: AnimatedTextBlock) bool {
        return self.codepoint_progress.hasFinished();
    }

    pub fn prepareRender(
        self: *AnimatedTextBlock,
        interval_between_previous_and_current_tick: math.Fix32,
    ) !void {
        const codepoints_to_reveal = self.codepoint_progress
            .getInterval(interval_between_previous_and_current_tick).convertTo(usize);
        const truncated_segments = try text_rendering.truncateTextSegments(
            &self.reusable_buffer,
            self.original_segments,
            codepoints_to_reveal,
        );
        self.widget.* = .{
            .text = ui.Text.wrap(truncated_segments, self.spritesheet, dialog_text_scale),
        };
    }

    pub fn getSpriteCount(self: AnimatedTextBlock) usize {
        return self.widget.getSpriteCount();
    }

    pub fn populateSpriteData(
        self: AnimatedTextBlock,
        /// Top left corner.
        screen_position_x: u16,
        screen_position_y: u16,
        /// Must have enough capacity to store all sprites. See getSpriteCount().
        out: []rendering.SpriteData,
    ) void {
        self.widget.populateSpriteData(screen_position_x, screen_position_y, out);
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
    at_previous_tick: math.Fix32,
    at_next_tick: math.Fix32,
    start_value: math.Fix32,
    end_value: math.Fix32,

    pub fn create(start_value: math.Fix32, end_value: math.Fix32) AnimationState {
        return .{
            .at_previous_tick = start_value,
            .at_next_tick = start_value,
            .start_value = start_value,
            .end_value = end_value,
        };
    }

    pub fn processElapsedTick(self: *AnimationState, step: math.Fix32) void {
        self.at_previous_tick = self.at_next_tick;
        self.at_next_tick = self.at_next_tick.add(step)
            .clamp(self.start_value, self.end_value);
    }

    pub fn reset(self: *AnimationState) void {
        self.* = AnimationState.create(self.start_value, self.end_value);
    }

    pub fn hasFinished(self: AnimationState) bool {
        return self.at_previous_tick.eql(self.end_value);
    }

    pub fn getInterval(
        self: AnimationState,
        interval_between_previous_and_current_tick: math.Fix32,
    ) math.Fix32 {
        return self.at_previous_tick.lerp(
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
    reusable_buffer: text_rendering.ReusableBuffer,
    reformatted_segments: []const text_rendering.TextSegment,
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

    var reusable_buffer = text_rendering.ReusableBuffer.create(allocator);
    errdefer reusable_buffer.destroy();

    const reformatted_segments =
        try text_rendering.reflowTextBlock(&reusable_buffer, text_block, max_line_length);

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

    const minimum_size_widget = try allocator.create(ui.Widget);
    errdefer allocator.destroy(minimum_size_widget);
    minimum_size_widget.* = .{ .minimum_size = ui.MinimumSize.wrap(
        animated_text_block.getWidgetPointer(),
        @max(dimensions.w, sample_dimensions.w),
        @max(dimensions.h, sample_dimensions.h),
    ) };

    return .{
        .reusable_buffer = reusable_buffer,
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
    text_block.reusable_buffer.destroy();
}
