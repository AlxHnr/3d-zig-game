//! Contains extra math functions which are not in std.math.

const std = @import("std");

/// Smallest viable number for game-world calculations.
pub const epsilon = 0.00001;

/// Linearly interpolate between a and b. T is a value between 0 and 1. Will be clamped into this
/// range.
pub const lerp = _lerp;
fn _lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * std.math.clamp(t, 0, 1);
}

pub fn isEqual(a: f32, b: f32) bool {
    return std.math.fabs(a - b) < epsilon;
}

pub fn scaleU16(value: u16, factor: f32) u16 {
    return @as(u16, @intFromFloat(@as(f32, @floatFromInt(value)) * factor));
}

/// Vector on a flat plane with no height information.
pub const FlatVector = struct {
    x: f32,
    z: f32,

    pub fn toVector3d(self: FlatVector) Vector3d {
        return .{ .x = self.x, .y = 0, .z = self.z };
    }

    pub fn normalize(self: FlatVector) FlatVector {
        const own_length = self.length();
        return if (own_length < epsilon)
            self
        else
            .{ .x = self.x / own_length, .z = self.z / own_length };
    }

    pub fn lerp(self: FlatVector, other: FlatVector, t: f32) FlatVector {
        return .{ .x = _lerp(self.x, other.x, t), .z = _lerp(self.z, other.z, t) };
    }

    pub fn add(self: FlatVector, other: FlatVector) FlatVector {
        return .{ .x = self.x + other.x, .z = self.z + other.z };
    }

    pub fn subtract(self: FlatVector, other: FlatVector) FlatVector {
        return .{ .x = self.x - other.x, .z = self.z - other.z };
    }

    pub fn scale(self: FlatVector, factor: f32) FlatVector {
        return .{ .x = self.x * factor, .z = self.z * factor };
    }

    pub fn length(self: FlatVector) f32 {
        return std.math.sqrt(self.lengthSquared());
    }

    pub fn lengthSquared(self: FlatVector) f32 {
        return self.x * self.x + self.z * self.z;
    }

    pub fn dotProduct(self: FlatVector, other: FlatVector) f32 {
        return self.x * other.x + self.z * other.z;
    }

    /// Get the angle needed to rotate this vector to have the same direction as another vector. The
    /// given vectors don't need to be normalized.
    pub fn computeRotationToOtherVector(self: FlatVector, other: FlatVector) f32 {
        const other_normalized = other.normalize();
        const angle = std.math.acos(std.math.clamp(self.normalize().dotProduct(
            other_normalized,
        ), -1, 1));
        return if (other_normalized.dotProduct(.{ .x = self.z, .z = -self.x }) < 0)
            -angle
        else
            angle;
    }

    pub fn negate(self: FlatVector) FlatVector {
        return .{ .x = -self.x, .z = -self.z };
    }

    pub fn rotate(self: FlatVector, angle: f32) FlatVector {
        const sin = std.math.sin(angle);
        const cos = std.math.cos(angle);
        return .{ .x = self.x * cos + self.z * sin, .z = -self.x * sin + self.z * cos };
    }

    pub fn rotateRightBy90Degrees(self: FlatVector) FlatVector {
        return .{ .x = -self.z, .z = self.x };
    }

    pub fn projectOnto(self: FlatVector, other: FlatVector) FlatVector {
        return other.scale(self.dotProduct(other) / other.dotProduct(other));
    }
};

pub const Vector3d = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const y_axis = Vector3d{ .x = 0, .y = 1, .z = 0 };
    pub const x_axis = Vector3d{ .x = 1, .y = 0, .z = 0 };

    /// Will cut off the height component.
    pub fn toFlatVector(self: Vector3d) FlatVector {
        return .{ .x = self.x, .z = self.z };
    }

    pub fn normalize(self: Vector3d) Vector3d {
        const own_length = self.length();
        return if (own_length < epsilon)
            self
        else
            .{ .x = self.x / own_length, .y = self.y / own_length, .z = self.z / own_length };
    }

    pub fn lerp(self: Vector3d, other: Vector3d, t: f32) Vector3d {
        return .{
            .x = _lerp(self.x, other.x, t),
            .y = _lerp(self.y, other.y, t),
            .z = _lerp(self.z, other.z, t),
        };
    }

    pub fn scale(self: Vector3d, factor: f32) Vector3d {
        return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor };
    }

    pub fn add(self: Vector3d, other: Vector3d) Vector3d {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn subtract(self: Vector3d, other: Vector3d) Vector3d {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn length(self: Vector3d) f32 {
        return std.math.sqrt(self.lengthSquared());
    }

    pub fn lengthSquared(self: Vector3d) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub fn dotProduct(self: Vector3d, other: Vector3d) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn crossProduct(self: Vector3d, other: Vector3d) Vector3d {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn negate(self: Vector3d) Vector3d {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    pub fn rotate(self: Vector3d, axis: Vector3d, angle: f32) Vector3d {
        const rescaled_axis = axis.normalize().scale(std.math.sin(angle / 2));
        const rescaled_axis_cross = rescaled_axis.crossProduct(self);
        return self
            .add(rescaled_axis_cross.scale(std.math.cos(angle / 2) * 2))
            .add(rescaled_axis.crossProduct(rescaled_axis_cross).scale(2));
    }
};

pub const Matrix = struct {
    rows: [4]@Vector(4, f32),

    pub const identity = Matrix{ .rows = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn multiply(self: Matrix, other: Matrix) Matrix {
        var result: [4]@Vector(4, f32) = undefined;
        for (other.transpose().rows, 0..) |column, column_index| {
            for (self.rows, 0..) |row, row_index| {
                result[row_index][column_index] = @reduce(.Add, row * column);
            }
        }
        return .{ .rows = result };
    }

    pub fn multiplyScalar(self: Matrix, scalar: f32) Matrix {
        var result: [4]@Vector(4, f32) = undefined;
        for (self.rows, 0..) |row, index| {
            result[index] = row * @as(@Vector(4, f32), @splat(scalar));
        }
        return .{ .rows = result };
    }

    /// M * V, where V contains (x, y, z, w). To achieve V * M use .transpose().
    pub fn multiplyVector4d(self: Matrix, vector: @Vector(4, f32)) @Vector(4, f32) {
        return .{
            @reduce(.Add, self.rows[0] * vector),
            @reduce(.Add, self.rows[1] * vector),
            @reduce(.Add, self.rows[2] * vector),
            @reduce(.Add, self.rows[3] * vector),
        };
    }

    pub fn scale(self: Matrix, dimensions: Vector3d) Matrix {
        var scaling = identity;
        scaling.rows[0][0] = dimensions.x;
        scaling.rows[1][1] = dimensions.y;
        scaling.rows[2][2] = dimensions.z;
        return scaling.multiply(self);
    }

    pub fn rotate(self: Matrix, axis: Vector3d, angle: f32) Matrix {
        const cosine = std.math.cos(angle);
        const inverted_cosine = 1 - cosine;
        const inverted_cosine_x_y = inverted_cosine * axis.x * axis.y;
        const inverted_cosine_x_z = inverted_cosine * axis.x * axis.z;
        const inverted_cosine_y_z = inverted_cosine * axis.y * axis.z;
        const axis_sine = axis.scale(std.math.sin(angle));
        const rotation = Matrix{ .rows = .{
            .{
                inverted_cosine * axis.x * axis.x + cosine,
                inverted_cosine_x_y - axis_sine.z,
                inverted_cosine_x_z + axis_sine.y,
                0,
            },
            .{
                inverted_cosine_x_y + axis_sine.z,
                inverted_cosine * axis.y * axis.y + cosine,
                inverted_cosine_y_z - axis_sine.x,
                0,
            },
            .{
                inverted_cosine_x_z - axis_sine.y,
                inverted_cosine_y_z + axis_sine.x,
                inverted_cosine * axis.z * axis.z + cosine,
                0,
            },
            .{ 0, 0, 0, 1 },
        } };
        return rotation.multiply(self);
    }

    pub fn translate(self: Matrix, offset: Vector3d) Matrix {
        var translation = identity;
        translation.rows[0][3] = offset.x;
        translation.rows[1][3] = offset.y;
        translation.rows[2][3] = offset.z;
        return translation.multiply(self);
    }

    pub fn transpose(self: Matrix) Matrix {
        return .{ .rows = .{
            .{ self.rows[0][0], self.rows[1][0], self.rows[2][0], self.rows[3][0] },
            .{ self.rows[0][1], self.rows[1][1], self.rows[2][1], self.rows[3][1] },
            .{ self.rows[0][2], self.rows[1][2], self.rows[2][2], self.rows[3][2] },
            .{ self.rows[0][3], self.rows[1][3], self.rows[2][3], self.rows[3][3] },
        } };
    }

    pub fn invert(self: Matrix) Matrix {
        const cofactor_matrix = self.getCofactorMatrix();
        const determinant = @reduce(.Add, self.rows[0] * cofactor_matrix.rows[0]);
        return cofactor_matrix.transpose().multiplyScalar(1 / determinant);
    }

    /// Result can be uploaded to OpenGL.
    pub fn toFloatArray(self: Matrix) [16]f32 {
        return .{
            self.rows[0][0], self.rows[1][0], self.rows[2][0], self.rows[3][0],
            self.rows[0][1], self.rows[1][1], self.rows[2][1], self.rows[3][1],
            self.rows[0][2], self.rows[1][2], self.rows[2][2], self.rows[3][2],
            self.rows[0][3], self.rows[1][3], self.rows[2][3], self.rows[3][3],
        };
    }

    fn getCofactorMatrix(self: Matrix) Matrix {
        var result: [4]@Vector(4, f32) = undefined;
        const negation_matrix = [4]@Vector(4, f32){
            .{ 1, -1, 1, -1 },
            .{ -1, 1, -1, 1 },
            .{ 1, -1, 1, -1 },
            .{ -1, 1, -1, 1 },
        };
        for (self.rows, 0..) |_, index| {
            result[index] = negation_matrix[index] * @Vector(4, f32){
                getDeterminant3x3(self.getCofactorSubmatrix(index, 0)),
                getDeterminant3x3(self.getCofactorSubmatrix(index, 1)),
                getDeterminant3x3(self.getCofactorSubmatrix(index, 2)),
                getDeterminant3x3(self.getCofactorSubmatrix(index, 3)),
            };
        }
        return .{ .rows = result };
    }

    fn getCofactorSubmatrix(self: Matrix, row_to_ignore: usize, column_to_ignore: usize) [3][3]f32 {
        var result: [3][3]f32 = undefined;
        const column_indices = getOtherIndices(column_to_ignore);
        for (getOtherIndices(row_to_ignore), 0..) |row_index, index| {
            result[index] = .{
                self.rows[row_index][column_indices[0]],
                self.rows[row_index][column_indices[1]],
                self.rows[row_index][column_indices[2]],
            };
        }
        return result;
    }

    /// Return 3 indices from 0 to 3 which are not the given index, sorted by value.
    fn getOtherIndices(value: usize) [3]usize {
        return switch (value) {
            0 => .{ 1, 2, 3 },
            1 => .{ 0, 2, 3 },
            2 => .{ 0, 1, 3 },
            else => .{ 0, 1, 2 },
        };
    }

    fn getDeterminant3x3(matrix: [3][3]f32) f32 {
        return // Rule of Sarrus.
        matrix[0][0] * matrix[1][1] * matrix[2][2] //
        + matrix[0][1] * matrix[1][2] * matrix[2][0] //
        + matrix[0][2] * matrix[1][0] * matrix[2][1] //
        - matrix[2][0] * matrix[1][1] * matrix[0][2] //
        - matrix[2][1] * matrix[1][2] * matrix[0][0] //
        - matrix[2][2] * matrix[1][0] * matrix[0][1];
    }
};
