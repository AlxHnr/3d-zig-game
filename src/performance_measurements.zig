const std = @import("std");

pub const Measurements = struct {
    metrics: std.enums.EnumArray(MetricType, Metric),

    pub const MetricType = enum {
        total,
        tick,
        enemy_logic,
        gem_logic,
        thread_aggregation,
        flow_field,
        thread_aggregation_flow_field,
        render,
        render_enemies,
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

    pub fn printLogInfo(self: Measurements) void {
        std.log.err(
            "⏱️ {d:.2}ms │ ⏲️ {d:.2}ms: 👾{d:.2}ms ♦️ {d:.2}ms 🧵{d:.2}ms⟨🌐{d:.2}ms ∧ ↪️ {d:.2}ms⟩ │ 🖌️{d:.2}ms: 👾{d:.2}ms",
            .{
                self.getAverage(.total),
                self.getAverage(.tick),
                self.getAverage(.enemy_logic),
                self.getAverage(.gem_logic),
                self.getAverage(.thread_aggregation_flow_field),
                self.getAverage(.flow_field),
                self.getAverage(.thread_aggregation),
                self.getAverage(.render),
                self.getAverage(.render_enemies),
            },
        );
    }

    fn getAverage(self: Measurements, metric_type: MetricType) f32 {
        return @as(f32, @floatFromInt(self.metrics.get(metric_type).average_time)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
    }
};
