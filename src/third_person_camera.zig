const std = @import("std");
const rl = @import("raylib");
const rm = @import("raylib-math");
const util = @import("util.zig");

const camera_follow_speed = 0.15;
const default_angle_from_ground = util.degreesToRadians(10);

/// Camera which smoothly follows an object and auto-rotates across the Y axis.
pub const Camera = struct {
    camera: rl.Camera,
    distance_from_object: f32,
    /// This value will be approached by processElapsedTick().
    target_distance_from_object: f32,
    angle_from_ground: f32,
    /// This value will be approached by processElapsedTick().
    target_angle_from_ground: f32,

    /// Initialize the camera to look down at the given object from behind.
    pub fn create(
        target_object_position: rl.Vector3,
        target_object_looking_direction: util.FlatVector,
    ) Camera {
        var camera = std.mem.zeroes(rl.Camera);
        camera.up = util.Constants.up;
        camera.fovy = 45;
        camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;
        camera.target = scaleTargetPosition(target_object_position);

        const distance_from_object = 10;
        const back_direction = target_object_looking_direction.negate();
        const unnormalized_direction = rm.Vector3RotateByAxisAngle(
            back_direction.toVector3(),
            back_direction.rotateRightBy90Degrees().toVector3(),
            default_angle_from_ground,
        );
        const offset_from_object =
            rm.Vector3Scale(rm.Vector3Normalize(unnormalized_direction), distance_from_object);
        camera.position = rm.Vector3Add(camera.target, offset_from_object);

        return Camera{
            .camera = camera,
            .distance_from_object = distance_from_object,
            .target_distance_from_object = distance_from_object,
            .angle_from_ground = default_angle_from_ground,
            .target_angle_from_ground = default_angle_from_ground,
        };
    }

    /// Interpolate between this cameras state and another cameras state based on the given interval
    /// from 0 to 1.
    pub fn lerp(self: Camera, other: Camera, interval: f32) Camera {
        const i = std.math.clamp(interval, 0, 1);

        var camera = self.camera;
        camera.position = rm.Vector3Lerp(self.camera.position, other.camera.position, i);
        camera.target = rm.Vector3Lerp(self.camera.target, other.camera.target, i);

        return Camera{
            .camera = camera,
            .distance_from_object = rm.Lerp(
                self.distance_from_object,
                other.distance_from_object,
                i,
            ),
            .target_distance_from_object = rm.Lerp(
                self.target_distance_from_object,
                other.target_distance_from_object,
                i,
            ),
            .angle_from_ground = rm.Lerp(self.angle_from_ground, other.angle_from_ground, i),
            .target_angle_from_ground = rm.Lerp(
                self.target_angle_from_ground,
                other.target_angle_from_ground,
                i,
            ),
        };
    }

    pub fn increaseDistanceToObject(self: *Camera, offset: f32) void {
        self.target_distance_from_object =
            std.math.max(self.target_distance_from_object + offset, 5);
    }

    /// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
    pub fn setAngleFromGround(self: *Camera, angle: f32) void {
        self.target_angle_from_ground = std.math.clamp(angle, 0, util.degreesToRadians(89));
    }

    pub fn resetAngleFromGround(self: *Camera) void {
        self.target_angle_from_ground = default_angle_from_ground;
    }

    pub fn get3DRay(self: Camera, mouse_position_on_screen: rl.Vector2) rl.Ray {
        return rl.GetMouseRay(mouse_position_on_screen, self.camera);
    }

    pub fn get3DRayFromTargetToSelf(self: Camera) rl.Ray {
        return rl.Ray{
            .position = self.camera.target,
            .direction = rm.Vector3Normalize(rm.Vector3Subtract(self.camera.position, self.camera.target)),
        };
    }

    /// Return a camera for rendering with raylib. Takes an optional distance limit to prevent walls
    /// from covering the cameras target object.
    pub fn getRaylibCamera(self: Camera, max_distance_from_target: ?f32) rl.Camera {
        if (max_distance_from_target) |max_distance| {
            const offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
            if (rm.Vector3Length(offset) < max_distance) {
                return self.camera;
            }

            var updated_camera = self.camera;
            updated_camera.position = rm.Vector3Add(
                self.camera.target,
                rm.Vector3Scale(rm.Vector3Normalize(offset), max_distance * 0.95),
            );
            return updated_camera;
        }
        return self.camera;
    }

    pub fn processElapsedTick(
        self: *Camera,
        target_object_position: rl.Vector3,
        target_object_looking_direction: util.FlatVector,
    ) void {
        self.updateAngleFromGround();
        const y_rotated_camera_offset =
            self.computeYRotatedCameraOffset(target_object_looking_direction);
        self.camera.target = rm.Vector3Lerp(
            self.camera.target,
            scaleTargetPosition(target_object_position),
            camera_follow_speed,
        );
        self.camera.position = rm.Vector3Add(self.camera.target, y_rotated_camera_offset);
        self.updateCameraDistanceFromObject();
    }

    fn updateAngleFromGround(self: *Camera) void {
        if (util.isEqualFloat(self.angle_from_ground, self.target_angle_from_ground)) {
            return;
        }
        self.angle_from_ground = rm.Lerp(
            self.angle_from_ground,
            self.target_angle_from_ground,
            camera_follow_speed,
        );

        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const flat_camera_direction = rm.Vector3Normalize(
            rl.Vector3{ .x = camera_offset.x, .y = 0, .z = camera_offset.z },
        );
        const rotation_axis =
            rl.Vector3{ .x = flat_camera_direction.z, .y = 0, .z = -flat_camera_direction.x };
        const rotated_camera_direction = rm.Vector3RotateByAxisAngle(
            flat_camera_direction,
            rotation_axis,
            -self.angle_from_ground,
        );
        self.camera.position = rm.Vector3Add(
            self.camera.target,
            rm.Vector3Scale(rotated_camera_direction, self.distance_from_object),
        );
    }

    fn computeYRotatedCameraOffset(
        self: Camera,
        target_object_looking_direction: util.FlatVector,
    ) rl.Vector3 {
        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const object_back_direction = target_object_looking_direction.negate();
        const rotation_step = camera_follow_speed * util.FlatVector.fromVector3(camera_offset)
            .computeRotationToOtherVector(object_back_direction);
        return rm.Vector3RotateByAxisAngle(camera_offset, util.Constants.up, rotation_step);
    }

    fn updateCameraDistanceFromObject(self: *Camera) void {
        if (util.isEqualFloat(self.distance_from_object, self.target_distance_from_object)) {
            return;
        }
        self.distance_from_object = rm.Lerp(
            self.distance_from_object,
            self.target_distance_from_object,
            camera_follow_speed,
        );

        const camera_offset = rm.Vector3Subtract(self.camera.position, self.camera.target);
        const rescaled_camera_offset =
            rm.Vector3Scale(rm.Vector3Normalize(camera_offset), self.distance_from_object);
        self.camera.position = rm.Vector3Add(self.camera.target, rescaled_camera_offset);
    }

    fn scaleTargetPosition(target_object_position: rl.Vector3) rl.Vector3 {
        return rm.Vector3Add(target_object_position, rm.Vector3Scale(util.Constants.up, 3));
    }
};
