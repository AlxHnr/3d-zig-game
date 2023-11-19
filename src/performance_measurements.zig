const std = @import("std");

pub const Measurements = struct {
    metrics: std.enums.EnumArray(MetricType, Metric),

    pub const MetricType = enum { enemy_logic };
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

    pub fn end(self: *Measurements, metric_type: MetricType) void {
        const metric = self.metrics.getPtr(metric_type);
        metric.accumulated_time += metric.timer.read();
        metric.accumulated_time_count += 1;
    }

    pub fn updateAverageAndReset(self: *Measurements) void {
        var iterator = self.metrics.iterator();
        while (iterator.next()) |item| {
            const metric = item.value;
            metric.average_time = metric.accumulated_time / metric.accumulated_time_count;
            metric.accumulated_time = 0;
            metric.accumulated_time_count = 0;
        }
    }

    pub fn printLogInfo(self: Measurements) void {
        std.log.info("Enemies: {d:.3}ms", .{
            self.getAverage(.enemy_logic),
        });
    }

    fn getAverage(self: Measurements, metric_type: MetricType) f32 {
        return @as(f32, @floatFromInt(self.metrics.get(metric_type).average_time)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
    }
};
