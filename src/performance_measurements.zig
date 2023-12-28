const std = @import("std");

pub const Measurements = struct {
    metrics: std.enums.EnumArray(MetricType, Metric),

    pub const MetricType = enum {
        tick_total,
        logic_total,
        enemy_logic,
        gem_logic,
        spatial_grids,
        flow_field,
        populate_render_snapshots,

        frame_total,
        frame_wait_for_data,
        aggregate_enemy_billboards,
        aggregate_gem_billboards,
        draw_billboards,
        render_level_geometry,
        hud,
    };
    const Metric = struct {
        timer: std.time.Timer,
        accumulated_time: u64,
        accumulated_time_count: u64,
        average_time: u64,
    };

    pub fn create() !Measurements {
        var metrics = std.enums.EnumArray(MetricType, Metric).initUndefined();
        var iterator = metrics.iterator();
        while (iterator.next()) |item| {
            item.value.* = .{
                .timer = try std.time.Timer.start(),
                .accumulated_time = 0,
                .accumulated_time_count = 0,
                .average_time = 0,
            };
        }
        return .{ .metrics = metrics };
    }

    pub fn begin(self: *Measurements, metric_type: MetricType) void {
        self.metrics.getPtr(metric_type).timer.reset();
    }

    pub fn pause(self: *Measurements, metric_type: MetricType) void {
        const metric = self.metrics.getPtr(metric_type);
        metric.accumulated_time += metric.timer.read();
    }

    pub fn proceed(self: *Measurements, metric_type: MetricType) void {
        self.begin(metric_type);
    }

    pub fn end(self: *Measurements, metric_type: MetricType) void {
        const metric = self.metrics.getPtr(metric_type);
        metric.accumulated_time += metric.timer.read();
        metric.accumulated_time_count += 1;
    }

    pub fn updateAverageAndReset(self: *Measurements) void {
        var iterator = self.metrics.iterator();
        while (iterator.next()) |item| {
            const metric = item.value;
            if (metric.accumulated_time_count == 0) {
                metric.average_time = 0;
            } else {
                metric.average_time = metric.accumulated_time / metric.accumulated_time_count;
            }
            metric.accumulated_time = 0;
            metric.accumulated_time_count = 0;
        }
    }

    pub fn getLongest(self: Measurements, other: Measurements, metric_type: MetricType) Measurements {
        if (self.metrics.get(metric_type).accumulated_time >
            other.metrics.get(metric_type).accumulated_time)
        {
            return self;
        }
        return other;
    }

    pub fn copySingleMetric(
        self: *Measurements,
        source: Measurements,
        metric_type_to_copy: MetricType,
    ) void {
        self.metrics.getPtr(metric_type_to_copy).* = source.metrics.get(metric_type_to_copy);
    }

    pub fn printTickInfo(self: Measurements) void {
        std.log.info(
            "Avg. Tick: {d:.2}ms: 🧵{d:.2}ms⟨👾{d:.2}ms OR ♦️ {d:.2}ms⟩ 🧵⟨🌐{d:.2}ms AND ↪️ {d:.2}ms⟩ ⏱️ 🖼️{d:.2}ms",
            .{
                self.getAverage(.tick_total),
                self.getAverage(.logic_total),
                self.getAverage(.enemy_logic),
                self.getAverage(.gem_logic),
                self.getAverage(.flow_field),
                self.getAverage(.spatial_grids),
                self.getAverage(.populate_render_snapshots),
            },
        );
    }

    pub fn printFrameInfo(self: Measurements) void {
        std.log.info(
            "Avg. Frame: {d:.2}ms: ⏱️ 🖼️{d:.2}ms 👾{d:.2}ms ♦️ {d:.2}ms 🖌️{d:.2}ms 🌐{d:.2}ms ℹ️ {d:.2}ms",
            .{
                self.getAverage(.frame_total),
                self.getAverage(.frame_wait_for_data),
                self.getAverage(.aggregate_enemy_billboards),
                self.getAverage(.aggregate_gem_billboards),
                self.getAverage(.draw_billboards),
                self.getAverage(.render_level_geometry),
                self.getAverage(.hud),
            },
        );
    }

    fn getAverage(self: Measurements, metric_type: MetricType) f32 {
        return @as(f32, @floatFromInt(self.metrics.get(metric_type).average_time)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
    }
};
