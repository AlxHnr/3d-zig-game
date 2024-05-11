const ScreenDimensions = @import("util.zig").ScreenDimensions;
const collision = @import("collision.zig");
const math = @import("math.zig");
const simulation = @import("simulation.zig");
const std = @import("std");

/// Camera which smoothly follows an object and auto-rotates across the Y axis.
pub const Camera = struct {
    target_position: math.Vector3d,
    target_orientation: f32,

    distance_from_object: f32,
    /// This value will be approached by processElapsedTick().
    target_distance_from_object: f32,
    angle_from_ground: f32,
    /// This value will be approached by processElapsedTick().
    target_angle_from_ground: f32,

    const target_follow_speed = simulation.kphToGameUnitsPerTick(32.4);
    const default_angle_from_ground = std.math.degreesToRadians(10);
    const default_distance_from_object = 10;

    /// Initialize the camera to look down at the given object from behind.
    pub fn create(target_position: math.FlatVector, target_orientation: f32) Camera {
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
    pub fn lerp(self: Camera, other: Camera, t: f32) Camera {
        return .{
            .target_position = self.target_position.lerp(other.target_position, t),
            .target_orientation = math.lerp(self.target_orientation, other.target_orientation, t),
            .distance_from_object = math.lerp(
                self.distance_from_object,
                other.distance_from_object,
                t,
            ),
            .target_distance_from_object = math.lerp(
                self.target_distance_from_object,
                other.target_distance_from_object,
                t,
            ),
            .angle_from_ground = math.lerp(self.angle_from_ground, other.angle_from_ground, t),
            .target_angle_from_ground = math.lerp(
                self.target_angle_from_ground,
                other.target_angle_from_ground,
                t,
            ),
        };
    }

    pub fn getViewProjectionMatrix(
        self: Camera,
        screen_dimensions: ScreenDimensions,
        /// Optional distance limit to prevent walls from covering the cameras target object.
        max_distance_from_target: ?f32,
    ) math.Matrix {
        return getProjectionMatrix(screen_dimensions)
            .multiply(self.getViewMatrix(max_distance_from_target));
    }

    pub fn getDirectionToTarget(self: Camera) math.Vector3d {
        return self.target_position.subtract(self.getPosition()).normalize();
    }

    pub fn increaseDistanceToObject(self: *Camera, offset: f32) void {
        self.target_distance_from_object =
            @max(self.target_distance_from_object + offset, 5);
    }

    /// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
    pub fn setAngleFromGround(self: *Camera, angle: f32) void {
        self.target_angle_from_ground = std.math.clamp(
            angle,
            0,
            std.math.degreesToRadians(89),
        );
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
        max_distance_from_target: ?f32,
    ) collision.Ray3d {
        const clip_ray = math.Vector3d{
            .x = @as(f32, @floatFromInt(mouse_x)) / @as(f32, @floatFromInt(screen_dimensions.width)) * 2 - 1,
            .y = 1 - @as(f32, @floatFromInt(mouse_y)) / @as(f32, @floatFromInt(screen_dimensions.height)) * 2,
            .z = 0,
        };
        const view_ray = getProjectionMatrix(screen_dimensions)
            .invert().multiplyVector4d(.{ clip_ray.x, clip_ray.y, -1, 0 });
        const unnormalized_direction = self.getViewMatrix(max_distance_from_target)
            .invert().multiplyVector4d(.{ view_ray[0], view_ray[1], -1, 0 });
        return .{
            .start_position = self.getAdjustedCameraPosition(max_distance_from_target),
            .direction = math.Vector3d.normalize(.{
                .x = unnormalized_direction[0],
                .y = unnormalized_direction[1],
                .z = unnormalized_direction[2],
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
        target_orientation: f32,
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
            .x = std.math.sin(self.target_orientation),
            .z = std.math.cos(self.target_orientation),
        };
        const direction_to_camera = target_looking_direction.negate();
        const camera_right = direction_to_camera.rotateRightBy90Degrees().toVector3d();
        const offset_from_object = direction_to_camera
            .toVector3d()
            .rotate(camera_right, self.angle_from_ground)
            .scale(self.distance_from_object);
        return self.target_position.add(offset_from_object);
    }

    /// Add a Y offset to the specified target so it is rendered in the bottom part of the screen.
    fn add3dHeight(target_position: math.FlatVector) math.Vector3d {
        return target_position.toVector3d().add(math.Vector3d.y_axis.scale(3));
    }

    /// Takes an optional distance limit to prevent walls from covering the cameras target object.
    fn getViewMatrix(self: Camera, max_distance_from_target: ?f32) math.Matrix {
        const direction_to_camera = self.getPosition().subtract(self.target_position).normalize();
        const right_direction = math.Vector3d.y_axis.crossProduct(direction_to_camera).normalize();
        const up_direction = direction_to_camera.crossProduct(right_direction).normalize();
        const adjusted_camera_position =
            self.getAdjustedCameraPosition(max_distance_from_target).negate();
        return .{ .rows = .{
            .{
                right_direction.x,
                right_direction.y,
                right_direction.z,
                right_direction.dotProduct(adjusted_camera_position),
            },
            .{
                up_direction.x,
                up_direction.y,
                up_direction.z,
                up_direction.dotProduct(adjusted_camera_position),
            },
            .{
                direction_to_camera.x,
                direction_to_camera.y,
                direction_to_camera.z,
                direction_to_camera.dotProduct(adjusted_camera_position),
            },
            .{ 0, 0, 0, 1 },
        } };
    }

    fn getAdjustedCameraPosition(self: Camera, max_distance_from_target: ?f32) math.Vector3d {
        const offset_from_target = self.getPosition().subtract(self.target_position);
        const max_distance = max_distance_from_target orelse offset_from_target.length();
        const distance = @min(offset_from_target.length(), max_distance);
        const prevent_seeing_trough_walls_factor = 0.95;
        const updated_offset = offset_from_target.normalize()
            .scale(distance * prevent_seeing_trough_walls_factor);
        return self.target_position.add(updated_offset);
    }

    fn getProjectionMatrix(screen_dimensions: ScreenDimensions) math.Matrix {
        const field_of_view = std.math.degreesToRadians(45);
        const ratio = @as(f32, @floatFromInt(screen_dimensions.width)) / @as(
            f32,
            @floatFromInt(screen_dimensions.height),
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
};
