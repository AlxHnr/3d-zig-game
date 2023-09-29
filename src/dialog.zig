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

    pub const Command = enum { abort, confirm };

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
    segments_to_render: []text_rendering.TextSegment,
    widgets: []ui.Widget,
    /// Non-owning pointer.
    spritesheet: *const SpriteSheetTexture,
    state: State,
    /// Contains values from 0 to 1.
    animation_state: struct { at_previous_tick: f32, at_next_tick: f32 },

    const State = enum { opening, opening_letters, open, closing, closed };

    const sample_content =
        \\,------------------------------------,
        \\| This is a sample text box which is |
        \\| used as a template for formatting  |
        \\| and aligning all dialog prompts.   |
        \\| The borders here are also valid    |
        \\| space for potential letters.       |
        \\|____________________________________|
    ;
    const max_lines = std.mem.count(u8, sample_content, "\n");
    const max_line_length = std.mem.indexOfScalar(u8, sample_content, '\n').?;
    const max_dialog_characters = max_lines * max_line_length;

    pub fn create(
        allocator: std.mem.Allocator,
        /// Returned object will keep a reference to this spritesheet.
        spritesheet: *const SpriteSheetTexture,
        npc_name: []const u8,
        message_text: []const u8,
    ) !Prompt {
        const text_block = [_]text_rendering.TextSegment{
            ui.Highlight.npcName(npc_name),
            ui.Highlight.normal("\n\n"),
            ui.Highlight.normal(message_text),
        };

        var reformatted_segments =
            try text_rendering.reflowTextBlock(allocator, &text_block, max_line_length);
        errdefer text_rendering.freeTextSegments(allocator, reformatted_segments);

        var result = Prompt{
            .reformatted_segments = reformatted_segments,
            .segments_to_render = &[_]text_rendering.TextSegment{},
            .widgets = &[_]ui.Widget{},
            .spritesheet = spritesheet,
            .state = .opening,
            .animation_state = .{ .at_previous_tick = 0, .at_next_tick = 0 },
        };

        try result.regenerateSegmentsAndWidgets(allocator, 0);
        return result;
    }

    pub fn destroy(self: *Prompt, allocator: std.mem.Allocator) void {
        allocator.free(self.widgets);
        text_rendering.freeTextSegments(allocator, self.segments_to_render);
        text_rendering.freeTextSegments(allocator, self.reformatted_segments);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *Prompt) bool {
        self.animation_state.at_previous_tick = self.animation_state.at_next_tick;

        const animation_step: f32 = switch (self.state) {
            .opening_letters => 0.01,
            else => 0.2,
        };
        self.animation_state.at_next_tick =
            @min(self.animation_state.at_next_tick + animation_step, 1);

        // Finish typing animation when all letters are on screen.
        if (self.state == .opening_letters) {
            const available_characters = countCharacters(self.reformatted_segments);
            const letter_animation_interval = self.animation_state.at_next_tick;
            if (scale(max_dialog_characters, letter_animation_interval) >= available_characters) {
                self.animation_state.at_next_tick = 1;
            }
        }

        switch (self.state) {
            .opening, .opening_letters, .closing => {
                if (math.isEqual(self.animation_state.at_next_tick, 1)) {
                    self.setState(util.getNextEnumWrapAround(self.state));
                }
            },
            .open, .closed => {},
        }

        return self.state != .closed;
    }

    pub fn prepareRender(
        self: *Prompt,
        allocator: std.mem.Allocator,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        const letter_animation_interval = switch (self.state) {
            .opening => 0,
            .opening_letters => self.getAnimationState(interval_between_previous_and_current_tick),
            else => 1,
        };
        try self.regenerateSegmentsAndWidgets(allocator, letter_animation_interval);
    }

    pub fn getBillboardCount(self: Prompt) usize {
        return self.widgets[0].getBillboardCount();
    }

    pub fn populateBillboardData(
        self: Prompt,
        screen_dimensions: util.ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        const animation_state = self.getAnimationState(interval_between_previous_and_current_tick);

        // Value from 0 (closed) to 1 (fully open).
        const window_open_interval = switch (self.state) {
            .opening => animation_state,
            .opening_letters, .open => 1,
            .closing => 1 - animation_state,
            .closed => 0,
        };
        const dimensions = self.widgets[0].getDimensionsInPixels();
        self.widgets[0].populateBillboardData(
            screen_dimensions.width / 2 - dimensions.width / 2,
            screen_dimensions.height - scale(dimensions.height, window_open_interval),
            out,
        );
    }

    pub fn processCommand(self: *Prompt, command: Controller.Command) void {
        _ = command;
        switch (self.state) {
            .open => self.setState(.closing),
            else => {},
        }
    }

    fn setState(self: *Prompt, new_state: State) void {
        self.state = new_state;
        self.animation_state.at_previous_tick = 0;
        self.animation_state.at_next_tick = 0;
    }

    fn scale(value: u16, factor: f32) u16 {
        return @as(u16, @intFromFloat(@as(f32, @floatFromInt(value)) * factor));
    }

    fn getAnimationState(self: Prompt, interval_between_previous_and_current_tick: f32) f32 {
        return math.lerp(
            self.animation_state.at_previous_tick,
            self.animation_state.at_next_tick,
            interval_between_previous_and_current_tick,
        );
    }

    fn regenerateSegmentsAndWidgets(
        self: *Prompt,
        allocator: std.mem.Allocator,
        letter_animation_interval: f32,
    ) !void {
        const minimum = ui.Text.wrap(
            &[_]text_rendering.TextSegment{ui.Highlight.normal(sample_content)},
            self.spritesheet,
            dialog_text_scale,
        ).getDimensionsInPixels();

        const segments = try text_rendering.truncateTextSegments(
            allocator,
            self.reformatted_segments,
            scale(max_dialog_characters, letter_animation_interval),
        );
        errdefer text_rendering.freeTextSegments(allocator, segments);

        var widgets = try allocator.alloc(ui.Widget, 3);
        errdefer allocator.free(widgets);
        widgets[2] = .{ .text = ui.Text.wrap(segments[0..], self.spritesheet, dialog_text_scale) };
        widgets[1] = .{
            .minimum_size = ui.MinimumSize.wrap(&widgets[2], minimum.width, minimum.height),
        };
        widgets[0] = .{ .box = ui.Box.wrap(&widgets[1], self.spritesheet) };

        allocator.free(self.widgets);
        text_rendering.freeTextSegments(allocator, self.segments_to_render);
        self.segments_to_render = segments;
        self.widgets = widgets;
    }

    fn countCharacters(segments: []text_rendering.TextSegment) usize {
        var result: usize = 0;
        for (segments) |segment| {
            result += segment.text.len;
        }
        return result;
    }
};
