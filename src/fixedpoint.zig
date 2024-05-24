const std = @import("std");

/// Fixed-point numeric type for deterministic computations which are portably reproducible.
/// Non-saturating. Overflows cause a panic in debug builds.
pub fn Fixedpoint(comptime integer_bit_count: u6, comptime fraction_bit_count: u6) type {
    comptime {
        std.debug.assert(integer_bit_count > 0);
        std.debug.assert(fraction_bit_count > 0);
    }
    return struct {
        internal: UnderlyingType,

        pub const Limits = struct {
            pub const max = Self{ .internal = std.math.maxInt(UnderlyingType) };
            pub const min = Self{ .internal = std.math.minInt(UnderlyingType) };
        };

        pub fn fp(value: anytype) Self {
            return switch (@typeInfo(@TypeOf(value))) {
                .Float, .ComptimeFloat => .{ .internal = @intFromFloat(value * scaling_factor) },
                .Int, .ComptimeInt => .{
                    .internal = @as(UnderlyingType, @intCast(value)) * scaling_factor,
                },
                else => @compileError("unsupported type: " ++ @typeName(@TypeOf(value))),
            };
        }

        /// Converts `self` to float, int or other fixedpoint types.
        ///
        /// Overflows are not handled by this function and will cause panic in debug builds. When
        /// converting to raw integers or fixedpoint types, precision loss (underflow) is handled by
        /// cutting off precision bits.
        pub fn convertTo(self: Self, comptime T: type) T {
            return switch (@typeInfo(T)) {
                .Int, .ComptimeInt => @intCast(@divTrunc(self.internal, scaling_factor)),
                .Float, .ComptimeFloat => @as(T, @floatFromInt(self.internal)) / scaling_factor,
                else => if (T.fraction_bits == Self.fraction_bits)
                    .{ .internal = @intCast(self.internal) }
                else if (T.fraction_bits > Self.fraction_bits)
                    .{ .internal = @shlExact(
                        @as(T.UnderlyingType, @intCast(self.internal)),
                        T.fraction_bits - Self.fraction_bits,
                    ) }
                else
                    .{ .internal = @intCast(
                        self.internal >> (Self.fraction_bits - T.fraction_bits),
                    ) },
            };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .internal = self.internal + other.internal };
        }

        pub fn saturatingAdd(self: Self, other: Self) Self {
            return .{ .internal = self.internal +| other.internal };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .internal = self.internal - other.internal };
        }

        pub fn mul(self: Self, other: Self) Self {
            const result =
                @as(IntermediateType, self.internal) *
                @as(IntermediateType, other.internal);
            return .{ .internal = @intCast(@divTrunc(result, scaling_factor)) };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{ .internal = @intCast(
                @divTrunc(@as(IntermediateType, self.internal) * scaling_factor, other.internal),
            ) };
        }

        pub fn mod(self: Self, other: Self) Self {
            return .{ .internal = @mod(self.internal, other.internal) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.internal == other.internal;
        }

        pub fn lt(self: Self, other: Self) bool {
            return self.internal < other.internal;
        }

        pub fn lte(self: Self, other: Self) bool {
            return self.internal <= other.internal;
        }

        pub fn gt(self: Self, other: Self) bool {
            return self.internal > other.internal;
        }

        pub fn gte(self: Self, other: Self) bool {
            return self.internal >= other.internal;
        }

        pub fn neg(self: Self) Self {
            return .{ .internal = -self.internal };
        }

        pub fn min(self: Self, other: Self) Self {
            return .{ .internal = @min(self.internal, other.internal) };
        }

        pub fn max(self: Self, other: Self) Self {
            return .{ .internal = @max(self.internal, other.internal) };
        }

        pub fn abs(self: Self) Self {
            return .{ .internal = @intCast(@abs(self.internal)) };
        }

        pub fn floor(self: Self) Self {
            return .{
                .internal = self.internal & @as(UnderlyingType, @truncate(
                    std.math.maxInt(std.meta.Int(.unsigned, integer_bits)) * scaling_factor,
                )),
            };
        }

        pub fn ceil(self: Self) Self {
            return self.floor().add(.{ .internal = scaling_factor });
        }

        /// Range is inclusive.
        pub fn clamp(self: Self, lower: Self, upper: Self) Self {
            return .{ .internal = std.math.clamp(self.internal, lower.internal, upper.internal) };
        }

        pub fn lerp(
            self: Self,
            other: Self,
            /// Value between 0.0 and 1.0. Will be clamped into this range.
            t: Self,
        ) Self {
            const zero = .{ .internal = 0 };
            const one = .{ .internal = scaling_factor };
            return self.add(other.sub(self).mul(clamp(t, zero, one)));
        }

        pub fn toDegrees(self: Self) Self {
            return self.mul(fp(std.math.deg_per_rad));
        }

        pub fn toRadians(self: Self) Self {
            return self.mul(fp(std.math.rad_per_deg));
        }

        /// Given value must be positive.
        pub fn sqrt(self: Self) Self {
            std.debug.assert(self.internal >= 0);
            const UnsignedType = std.meta.Int(.unsigned, @typeInfo(IntermediateType).Int.bits);
            return .{ .internal = @intCast(
                std.math.sqrt(@as(UnsignedType, @intCast(self.internal)) * scaling_factor),
            ) };
        }

        pub fn sin(self: Self) Self {
            // Derived from https://github.com/MikeLankamp/fpm
            const pi = fp(std.math.pi);
            const pi2 = fp(std.math.tau);
            const inverted_half_pi = fp(1.0 / (std.math.pi / 2.0));

            var value = self.mod(pi2).mul(inverted_half_pi);
            std.debug.assert(value.gte(fp(0))); // The original code can have negative values here.

            var sign_factor = fp(0.5); // Combines sign inversion with a division.
            if (value.gt(fp(2))) {
                sign_factor = sign_factor.neg();
                value = value.sub(fp(2));
            }
            if (value.gt(fp(1))) {
                value = fp(2).sub(value);
            }
            const squared = value.mul(value);
            return value
                .mul(pi.sub(squared.mul(pi2.sub(fp(5)).sub(squared.mul(pi.sub(fp(3)))))))
                .mul(sign_factor);
        }

        pub fn cos(self: Self) Self {
            return self.add(fp(std.math.pi / 2.0)).sin();
        }

        pub fn acos(self: Self) Self {
            std.debug.assert(self.gte(fp(-1)));
            std.debug.assert(self.lte(fp(1)));
            if (self.eql(fp(-1))) {
                return fp(std.math.pi);
            }
            return fp(2).mul(
                fp(1).sub(self.mul(self)).sqrt().atanDivisionInternal(fp(1).add(self)),
            );
        }

        fn atanInternal(self: Self) Self {
            // Derived from https://github.com/MikeLankamp/fpm
            std.debug.assert(self.gte(fp(0)));
            std.debug.assert(self.lte(fp(1)));

            const a = fp(0.0776509570923569);
            const b = fp(-0.287434475393028);
            const c = fp(std.math.pi).mul(fp(0.25)).sub(a).sub(b);
            const squared = self.mul(self);
            return a.mul(squared).add(b).mul(squared).add(c).mul(self);
        }

        fn atanDivisionInternal(self: Self, other: Self) Self {
            // Derived from https://github.com/MikeLankamp/fpm
            std.debug.assert(!other.eql(fp(0)));
            if (self.lt(fp(0))) {
                if (other.lt(fp(0))) {
                    return self.neg().atanDivisionInternal(other.neg());
                }
                return self.neg().atanDivisionInternal(other).neg();
            }
            if (other.lt(fp(0))) {
                return self.atanDivisionInternal(other.neg()).neg();
            }
            std.debug.assert(self.gte(fp(0)));
            std.debug.assert(other.gt(fp(0)));

            if (self.gt(other)) {
                return fp(std.math.pi / 2.0).sub(other.div(self).atanInternal());
            }
            return self.div(other).atanInternal();
        }

        const Self = @This();
        const integer_bits = integer_bit_count;
        const fraction_bits = fraction_bit_count;
        const UnderlyingType = std.meta.Int(
            .signed,
            @as(usize, integer_bits) + @as(usize, fraction_bits),
        );
        const IntermediateType = std.meta.Int(.signed, @typeInfo(UnderlyingType).Int.bits * 2);
        const scaling_factor = 1 << fraction_bits;
    };
}
