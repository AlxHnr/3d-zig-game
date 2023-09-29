const BillboardRenderer = @import("rendering.zig").BillboardRenderer;
const ScreenDimensions = @import("util.zig").ScreenDimensions;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const math = @import("math.zig");
const std = @import("std");
const text_rendering = @import("text_rendering.zig");
const ui = @import("ui.zig");

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
        screen_dimensions: ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
    ) !void {
        var total_billboards: usize = 0;
        for (self.dialog_stack.items) |dialog| {
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
    segments: []text_rendering.TextSegment,
    widgets: []ui.Widget,
    state: State,
    /// Contains values from 0 to 1.
    animation_state: struct { at_previous_tick: f32, at_next_tick: f32 },

    const State = enum { opening, open, closing, closed };

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

        var segments = try text_rendering.reflowTextBlock(allocator, &text_block, 38);
        errdefer text_rendering.freeTextSegments(allocator, segments);

        var widgets = try allocator.alloc(ui.Widget, 2);
        errdefer allocator.free(widgets);

        widgets[1] = .{ .text = ui.Text.wrap(segments[0..], spritesheet, dialog_text_scale) };
        widgets[0] = .{ .box = ui.Box.wrap(&widgets[1], spritesheet) };

        return .{
            .segments = segments,
            .widgets = widgets,
            .state = .opening,
            .animation_state = .{ .at_previous_tick = 0, .at_next_tick = 0 },
        };
    }

    pub fn destroy(self: *Prompt, allocator: std.mem.Allocator) void {
        allocator.free(self.widgets);
        text_rendering.freeTextSegments(allocator, self.segments);
    }

    // Returns true if this dialog is still needed.
    pub fn processElapsedTick(self: *Prompt) bool {
        self.animation_state.at_previous_tick = self.animation_state.at_next_tick;
        self.animation_state.at_next_tick = @min(self.animation_state.at_next_tick + 0.2, 1);

        switch (self.state) {
            .opening => {
                if (math.isEqual(self.animation_state.at_next_tick, 1)) {
                    self.setState(.open);
                }
            },
            .closing => {
                if (math.isEqual(self.animation_state.at_next_tick, 1)) {
                    self.setState(.closed);
                }
            },
            .open, .closed => {},
        }

        return self.state != .closed;
    }

    pub fn getBillboardCount(self: Prompt) usize {
        return self.widgets[0].getBillboardCount();
    }

    pub fn populateBillboardData(
        self: Prompt,
        screen_dimensions: ScreenDimensions,
        interval_between_previous_and_current_tick: f32,
        /// Must have enough capacity to store all billboards. See getBillboardCount().
        out: []BillboardRenderer.BillboardData,
    ) void {
        const animation_state = math.lerp(
            self.animation_state.at_previous_tick,
            self.animation_state.at_next_tick,
            interval_between_previous_and_current_tick,
        );

        // Value from 0 (closed) to 1 (fully open).
        const window_open_interval = switch (self.state) {
            .opening => animation_state,
            .open => 1,
            .closing => 1 - animation_state,
            .closed => 0,
        };

        const dimensions = self.widgets[0].getDimensionsInPixels();
        self.widgets[0].populateBillboardData(
            screen_dimensions.width / 2 - dimensions.width / 2,
            screen_dimensions.height -
                @as(
                u16,
                @intFromFloat(@as(f32, @floatFromInt(dimensions.height)) * window_open_interval),
            ),
            out,
        );
    }

    pub fn processCommand(self: *Prompt, command: Controller.Command) void {
        _ = command;
        switch (self.state) {
            .open => self.setState(.closing),
            .opening, .closing, .closed => {},
        }
    }

    fn setState(self: *Prompt, new_state: State) void {
        self.state = new_state;
        self.animation_state.at_previous_tick = 0;
        self.animation_state.at_next_tick = 0;
    }
};