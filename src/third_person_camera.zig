const std = @import("std");
const math = @import("math.zig");
const collision = @import("collision.zig");

/// Camera which smoothly follows an object and auto-rotates across the Y axis.
pub const Camera = struct {
    position: math.Vector3d,
    target_position: math.Vector3d,

    distance_from_object: f32,
    /// This value will be approached by processElapsedTick().
    target_distance_from_object: f32,
    angle_from_ground: f32,
    /// This value will be approached by processElapsedTick().
    target_angle_from_ground: f32,

    const target_follow_speed = 0.15;
    const default_angle_from_ground = std.math.degreesToRadians(f32, 10);
    const default_distance_from_object = 10;

    /// Initialize the camera to look down at the given object from behind.
    pub fn create(
        target_object_position: math.FlatVector,
        target_object_looking_direction: math.FlatVector,
    ) Camera {
        const direction_to_camera = target_object_looking_direction.negate();
        const camera_right = direction_to_camera.rotateRightBy90Degrees().toVector3d();
        const offset_from_object =
            direction_to_camera
            .toVector3d()
            .rotate(camera_right, default_angle_from_ground)
            .scale(default_distance_from_object);

        return Camera{
            .position = add3dHeigth(target_object_position).add(offset_from_object),
            .target_position = add3dHeigth(target_object_position),
            .distance_from_object = default_distance_from_object,
            .target_distance_from_object = default_distance_from_object,
            .angle_from_ground = default_angle_from_ground,
            .target_angle_from_ground = default_angle_from_ground,
        };
    }

    /// Interpolate between this cameras state and another cameras state.
    pub fn lerp(self: Camera, other: Camera, t: f32) Camera {
        return Camera{
            .position = self.position.lerp(other.position, t),
            .target_position = self.target_position.lerp(other.target_position, t),
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
        screen_width: u16,
        screen_height: u16,
        /// Optional distance limit to prevent walls from covering the cameras target object.
        max_distance_from_target: ?f32,
    ) math.Matrix {
        return getProjectionMatrix(screen_width, screen_height)
            .multiply(self.getViewMatrix(max_distance_from_target));
    }

    pub fn getDirectionToTarget(self: Camera) math.Vector3d {
        return self.target_position.subtract(self.position).normalize();
    }

    pub fn increaseDistanceToObject(self: *Camera, offset: f32) void {
        self.target_distance_from_object =
            std.math.max(self.target_distance_from_object + offset, 5);
    }

    /// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
    pub fn setAngleFromGround(self: *Camera, angle: f32) void {
        self.target_angle_from_ground = std.math.clamp(
            angle,
            0,
            std.math.degreesToRadians(f32, 89),
        );
    }

    pub fn resetAngleFromGround(self: *Camera) void {
        self.target_angle_from_ground = default_angle_from_ground;
    }

    pub fn get3DRay(
        self: Camera,
        mouse_x: u16,
        mouse_y: u16,
        screen_width: u16,
        screen_height: u16,
        /// Optional value to account for walls covering the camera.
        max_distance_from_target: ?f32,
    ) collision.Ray3d {
        const clip_ray = math.Vector3d{
            .x = @intToFloat(f32, mouse_x) / @intToFloat(f32, screen_width) * 2 - 1,
            .y = 1 - @intToFloat(f32, mouse_y) / @intToFloat(f32, screen_height) * 2,
            .z = 0,
        };
        const view_ray = getProjectionMatrix(screen_width, screen_height)
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
            .direction = self.position.subtract(self.target_position).normalize(),
        };
    }

    pub fn processElapsedTick(
        self: *Camera,
        target_object_position: math.FlatVector,
        target_object_looking_direction: math.FlatVector,
    ) void {
        self.updateAngleFromGround();
        const y_rotated_camera_offset =
            self.computeYRotatedCameraOffset(target_object_looking_direction);
        self.target_position = self.target_position.lerp(
            add3dHeigth(target_object_position),
            target_follow_speed,
        );
        self.position = self.target_position.add(y_rotated_camera_offset);
        self.updateCameraDistanceFromObject();
    }

    fn updateAngleFromGround(self: *Camera) void {
        if (math.isEqual(self.angle_from_ground, self.target_angle_from_ground)) {
            return;
        }
        self.angle_from_ground = math.lerp(
            self.angle_from_ground,
            self.target_angle_from_ground,
            target_follow_speed,
        );

        const camera_offset = self.position.subtract(self.target_position);
        const flat_camera_direction = camera_offset.toFlatVector().normalize();
        const rotation_axis = flat_camera_direction.rotateRightBy90Degrees();
        const rotated_camera_direction =
            flat_camera_direction.toVector3d().rotate(
            rotation_axis.toVector3d(),
            self.angle_from_ground,
        );
        self.position =
            self.target_position.add(rotated_camera_direction.scale(self.distance_from_object));
    }

    fn computeYRotatedCameraOffset(
        self: Camera,
        target_object_looking_direction: math.FlatVector,
    ) math.Vector3d {
        const camera_offset = self.position.subtract(self.target_position);
        const object_back_direction = target_object_looking_direction.negate();
        const rotation_step = target_follow_speed * camera_offset.toFlatVector()
            .computeRotationToOtherVector(object_back_direction);
        return camera_offset.rotate(math.Vector3d.y_axis, rotation_step);
    }

    fn updateCameraDistanceFromObject(self: *Camera) void {
        if (math.isEqual(self.distance_from_object, self.target_distance_from_object)) {
            return;
        }
        self.distance_from_object = math.lerp(
            self.distance_from_object,
            self.target_distance_from_object,
            target_follow_speed,
        );

        const camera_offset = self.position.subtract(self.target_position);
        const rescaled_camera_offset = camera_offset.normalize().scale(self.distance_from_object);
        self.position = self.target_position.add(rescaled_camera_offset);
    }

    /// Add a Y offset to the specified target so it is rendered in the bottom part of the screen.
    fn add3dHeigth(target_object_position: math.FlatVector) math.Vector3d {
        return target_object_position.toVector3d().add(math.Vector3d.y_axis.scale(3));
    }

    /// Takes an optional distance limit to prevent walls from covering the cameras target object.
    fn getViewMatrix(self: Camera, max_distance_from_target: ?f32) math.Matrix {
        const direction_to_camera = self.position.subtract(self.target_position).normalize();
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
        const offset_from_target = self.position.subtract(self.target_position);
        const max_distance = max_distance_from_target orelse offset_from_target.length();
        const distance = std.math.min(offset_from_target.length(), max_distance);
        const prevent_seeing_trough_walls_factor = 0.95;
        const updated_offset = offset_from_target.normalize()
            .scale(distance * prevent_seeing_trough_walls_factor);
        return self.target_position.add(updated_offset);
    }

    fn getProjectionMatrix(screen_width: u16, screen_height: u16) math.Matrix {
        const field_of_view = std.math.degreesToRadians(f32, 45);
        const ratio = @intToFloat(f32, screen_width) / @intToFloat(f32, screen_height);
        const near = 0.01;
        const far = 1000.0;
        const f = 1.0 / std.math.tan(field_of_view / 2);
        return .{ .rows = .{
            .{ f / ratio, 0, 0, 0 },
            .{ 0, f, 0, 0 },
            .{ 0, 0, (far + near) / (near - far), 2 * far * near / (near - far) },
            .{ 0, 0, -1, 0 },
        } };
    }
};
