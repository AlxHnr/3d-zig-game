const std = @import("std");

pub const Measurements = struct {
    metrics: std.enums.EnumArray(MetricType, Metric),

    pub const MetricType = enum {
        tick_total,
        enemy_logic,
        gem_logic,
        spatial_grids,
        flow_field,

        frame_total,
        frame_wait_for_data,
        hud_sprite_data,
        upload_billboards,
        render_billboards,
        render_level_geometry,
        render_hud,
    };
    const Metric = struct {
        timer: std.time.Timer,
        accumulated_time: u64,
        accumulated_time_count: u64,
        accumulated_worst_time: u64,

        average_time: u64,
        worst_time: u64,
    };

    pub fn create() !Measurements {
        var metrics = std.enums.EnumArray(MetricType, Metric).initUndefined();
        var iterator = metrics.iterator();
        while (iterator.next()) |item| {
            item.value.* = .{
                .timer = try std.time.Timer.start(),
                .accumulated_time = 0,
                .accumulated_time_count = 0,
                .accumulated_worst_time = 0,
                .average_time = 0,
                .worst_time = 0,
            };
        }
        return .{ .metrics = metrics };
    }

    pub fn begin(self: *Measurements, metric_type: MetricType) void {
        self.metrics.getPtr(metric_type).timer.reset();
    }

    pub fn end(self: *Measurements, metric_type: MetricType) void {
        const metric = self.metrics.getPtr(metric_type);
        const time = metric.timer.read();
        metric.accumulated_time += time;
        metric.accumulated_time_count += 1;
        metric.accumulated_worst_time = @max(metric.accumulated_worst_time, time);
    }

    pub fn updateAverageAndReset(self: *Measurements) void {
        var iterator = self.metrics.iterator();
        while (iterator.next()) |item| {
            const metric = item.value;
            if (metric.accumulated_time_count == 0) {
                metric.average_time = 0;
                metric.accumulated_worst_time = 0;
            } else {
                metric.average_time = metric.accumulated_time / metric.accumulated_time_count;
                metric.worst_time = metric.accumulated_worst_time;
            }
            metric.accumulated_time = 0;
            metric.accumulated_time_count = 0;
            metric.accumulated_worst_time = 0;
        }
    }

    pub fn getLongest(self: Measurements, other: Measurements, metric_type: MetricType) Measurements {
        var result = self;
        const result_metric = result.metrics.getPtr(metric_type);
        const other_metric = other.metrics.get(metric_type);
        if (result_metric.accumulated_time < other_metric.accumulated_time) {
            result_metric.accumulated_time = other_metric.accumulated_time;
            result_metric.accumulated_time_count = other_metric.accumulated_time_count;
        }
        result_metric.accumulated_worst_time =
            @max(result_metric.accumulated_worst_time, other_metric.accumulated_worst_time);
        return result;
    }

    pub fn copySingleMetric(
        self: *Measurements,
        source: Measurements,
        metric_type_to_copy: MetricType,
    ) void {
        self.metrics.getPtr(metric_type_to_copy).* = source.metrics.get(metric_type_to_copy);
    }

    pub fn printTickInfo(self: Measurements) void {
        for (summary_types) |summary| {
            std.log.info(
                "{s} Tick: {d:.2}ms: 🧵⟨👾{d:.2}ms then ♦️ {d:.2}ms⟩ 🧵⟨🗒️{d:.2}ms & 🌐{d:.2}ms⟩",
                .{
                    summary.name,
                    summary.get_function(self, .tick_total),
                    summary.get_function(self, .enemy_logic),
                    summary.get_function(self, .gem_logic),
                    summary.get_function(self, .flow_field),
                    summary.get_function(self, .spatial_grids),
                },
            );
        }
    }

    pub fn printFrameInfo(self: Measurements) void {
        for (summary_types) |summary| {
            std.log.info(
                "{s} Frame: {d:.2}ms: ⏱️ {d:.2}ms 🔳{d:.2}ms ⬆️ {d:.2}ms 🏠{d:.2}ms 🖼️{d:.2}ms 🔳{d:.2}ms",
                .{
                    summary.name,
                    summary.get_function(self, .frame_total),
                    summary.get_function(self, .frame_wait_for_data),
                    summary.get_function(self, .hud_sprite_data),
                    summary.get_function(self, .upload_billboards),
                    summary.get_function(self, .render_billboards),
                    summary.get_function(self, .render_level_geometry),
                    summary.get_function(self, .render_hud),
                },
            );
        }
    }

    const summary_types = [_]struct {
        name: []const u8,
        get_function: *const fn (a: Measurements, b: MetricType) f32,
    }{
        .{ .name = "Avg. ", .get_function = getAverage },
        .{ .name = "Worst", .get_function = getWorst },
    };

    fn getAverage(self: Measurements, metric_type: MetricType) f32 {
        return @as(f32, @floatFromInt(self.metrics.get(metric_type).average_time)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
    }

    fn getWorst(self: Measurements, metric_type: MetricType) f32 {
        return @as(f32, @floatFromInt(self.metrics.get(metric_type).worst_time)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
    }
};
