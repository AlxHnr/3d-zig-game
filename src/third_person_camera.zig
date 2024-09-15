//! Camera which smoothly follows an object and auto-rotates across the Y axis.
const ScreenDimensions = @import("rendering.zig").ScreenDimensions;
const collision = @import("collision.zig");
const fp = math.Fix32.fp;
const math = @import("math.zig");
const simulation = @import("simulation.zig");
const std = @import("std");

const Camera = @This();

target_position: math.Vector3d,
target_orientation: math.Fix32,

distance_from_object: math.Fix32,
/// This value will be approached by processElapsedTick().
target_distance_from_object: math.Fix32,
angle_from_ground: math.Fix32,
/// This value will be approached by processElapsedTick().
target_angle_from_ground: math.Fix32,

const target_follow_speed = simulation.kphToGameUnitsPerTick(32.4);
const default_angle_from_ground = fp(10).toRadians();
const default_distance_from_object = fp(10);

/// Initialize the camera to look down at the given object from behind.
pub fn create(target_position: math.FlatVector, target_orientation: math.Fix32) Camera {
    return .{
        .target_position = add3dHeight(target_position),
        .target_orientation = target_orientation,
        .distance_from_object = default_distance_from_object,
        .target_distance_from_object = default_distance_from_object,
        .angle_from_ground = default_angle_from_ground,
        .target_angle_from_ground = default_angle_from_ground,
    };
}

/// Interpolate between this cameras state and another cameras state.
pub fn lerp(self: Camera, other: Camera, t: math.Fix32) Camera {
    return .{
        .target_position = self.target_position.lerp(other.target_position, t),
        .target_orientation = self.target_orientation.lerp(other.target_orientation, t),
        .distance_from_object = self.distance_from_object.lerp(other.distance_from_object, t),
        .target_distance_from_object = self.target_distance_from_object.lerp(
            other.target_distance_from_object,
            t,
        ),
        .angle_from_ground = self.angle_from_ground.lerp(other.angle_from_ground, t),
        .target_angle_from_ground = self.target_angle_from_ground.lerp(
            other.target_angle_from_ground,
            t,
        ),
    };
}

pub fn getViewProjectionMatrix(
    self: Camera,
    screen_dimensions: ScreenDimensions,
    /// Optional distance limit to prevent walls from covering the cameras target object.
    max_distance_from_target: ?math.Fix64,
) math.Matrix {
    return getProjectionMatrix(screen_dimensions)
        .multiply(self.getViewMatrix(max_distance_from_target));
}

pub fn getDirectionToTarget(self: Camera) math.Vector3d {
    return self.target_position.subtract(self.getPosition()).normalize();
}

pub fn increaseDistanceToObject(self: *Camera, offset: math.Fix32) void {
    self.target_distance_from_object =
        self.target_distance_from_object.add(offset).max(fp(5));
}

/// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
pub fn setAngleFromGround(self: *Camera, angle: math.Fix32) void {
    self.target_angle_from_ground = angle.clamp(fp(0), fp(80).toRadians());
}

pub fn resetAngleFromGround(self: *Camera) void {
    self.target_angle_from_ground = default_angle_from_ground;
}

pub fn get3DRay(
    self: Camera,
    mouse_x: u16,
    mouse_y: u16,
    screen_dimensions: ScreenDimensions,
    /// Optional value to account for walls covering the camera.
    max_distance_from_target: ?math.Fix64,
) collision.Ray3d {
    const clip_ray = .{
        .x = fp(mouse_x).div(fp(screen_dimensions.w)).mul(fp(2)).sub(fp(1)),
        .y = fp(1).sub(fp(mouse_y).div(fp(screen_dimensions.h)).mul(fp(2))),
        .z = fp(0),
    };
    const view_ray = getProjectionMatrix(screen_dimensions).invert().multiplyVector4d(.{
        clip_ray.x.convertTo(f32),
        clip_ray.y.convertTo(f32),
        -1,
        0,
    });
    const unnormalized_direction = self.getViewMatrix(max_distance_from_target)
        .invert().multiplyVector4d(.{ view_ray[0], view_ray[1], -1, 0 });
    return .{
        .start_position = self.getAdjustedCameraPosition(max_distance_from_target),
        .direction = math.Vector3d.normalize(.{
            .x = fp(unnormalized_direction[0]),
            .y = fp(unnormalized_direction[1]),
            .z = fp(unnormalized_direction[2]),
        }),
    };
}

pub fn get3DRayFromTargetToSelf(self: Camera) collision.Ray3d {
    return .{
        .start_position = self.target_position,
        .direction = self.getPosition().subtract(self.target_position).normalize(),
    };
}

pub fn processElapsedTick(
    self: *Camera,
    target_position: math.FlatVector,
    target_orientation: math.Fix32,
) void {
    var targeted_values = self.*;
    targeted_values.angle_from_ground = self.target_angle_from_ground;
    targeted_values.distance_from_object = self.target_distance_from_object;
    targeted_values.target_position = add3dHeight(target_position);
    targeted_values.target_orientation = target_orientation;
    self.* = self.lerp(targeted_values, target_follow_speed);
}

pub fn getPosition(self: Camera) math.Vector3d {
    const target_looking_direction = math.FlatVector{
        .x = self.target_orientation.sin(),
        .z = self.target_orientation.cos(),
    };
    const direction_to_camera = target_looking_direction.negate();
    const camera_right = direction_to_camera.rotateRightBy90Degrees().toVector3d();
    const offset_from_object = direction_to_camera
        .toVector3d()
        .rotate(camera_right, self.angle_from_ground)
        .multiplyScalar(self.distance_from_object);
    return self.target_position.add(offset_from_object);
}

/// Add a Y offset to the specified target so it is rendered in the bottom part of the screen.
fn add3dHeight(target_position: math.FlatVector) math.Vector3d {
    return target_position.addY(fp(3));
}

/// Takes an optional distance limit to prevent walls from covering the cameras target object.
fn getViewMatrix(self: Camera, max_distance_from_target: ?math.Fix64) math.Matrix {
    const direction_to_camera =
        self.getPosition().subtract(self.target_position).normalize();
    const right_direction = math.Vector3d.y_axis.crossProduct(direction_to_camera).normalize();
    const up_direction = direction_to_camera.crossProduct(right_direction).normalize();
    const adjusted_camera_position =
        self.getAdjustedCameraPosition(max_distance_from_target).negate();
    return .{ .rows = .{
        .{
            right_direction.x.convertTo(f32),
            right_direction.y.convertTo(f32),
            right_direction.z.convertTo(f32),
            right_direction.dotProduct(adjusted_camera_position).convertTo(f32),
        },
        .{
            up_direction.x.convertTo(f32),
            up_direction.y.convertTo(f32),
            up_direction.z.convertTo(f32),
            up_direction.dotProduct(adjusted_camera_position).convertTo(f32),
        },
        .{
            direction_to_camera.x.convertTo(f32),
            direction_to_camera.y.convertTo(f32),
            direction_to_camera.z.convertTo(f32),
            direction_to_camera.dotProduct(adjusted_camera_position).convertTo(f32),
        },
        .{ 0, 0, 0, 1 },
    } };
}

fn getAdjustedCameraPosition(self: Camera, max_distance_from_target: ?math.Fix64) math.Vector3d {
    const offset_from_target = self.getPosition().subtract(self.target_position);
    const max_distance = max_distance_from_target orelse offset_from_target.length();
    const distance = offset_from_target.length().min(max_distance).convertTo(math.Fix32);
    const prevent_seeing_trough_walls_factor = fp(0.8);
    const updated_offset = offset_from_target.normalize()
        .multiplyScalar(distance.mul(prevent_seeing_trough_walls_factor));
    return self.target_position.add(updated_offset);
}

fn getProjectionMatrix(screen_dimensions: ScreenDimensions) math.Matrix {
    const field_of_view = std.math.degreesToRadians(45);
    const ratio = @as(f32, @floatFromInt(screen_dimensions.w)) / @as(
        f32,
        @floatFromInt(screen_dimensions.h),
    );
    const near = 0.01;
    const far = 3000.0;
    const f = 1.0 / std.math.tan(field_of_view / 2.0);
    return .{ .rows = .{
        .{ f / ratio, 0, 0, 0 },
        .{ 0, f, 0, 0 },
        .{ 0, 0, (far + near) / (near - far), 2 * far * near / (near - far) },
        .{ 0, 0, -1, 0 },
    } };
}
