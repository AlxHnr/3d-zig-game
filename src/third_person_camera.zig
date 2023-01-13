const std = @import("std");
const rl = @import("raylib");
const math = @import("math.zig");
const collision = @import("collision.zig");

const camera_follow_speed = 0.15;
const default_angle_from_ground = math.degreesToRadians(10);

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
        target_object_position: math.FlatVector,
        target_object_looking_direction: math.FlatVector,
    ) Camera {
        var camera = std.mem.zeroes(rl.Camera);
        camera.up = .{ .x = 0, .y = 1, .z = 0 };
        camera.fovy = 45;
        camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;
        camera.target = add3dHeigth(target_object_position).toVector3();

        const distance_from_object = 10;
        const back_direction = target_object_looking_direction.negate();
        const offset_from_object =
            back_direction.toVector3d()
            .rotate(back_direction.rotateRightBy90Degrees().toVector3d(), default_angle_from_ground)
            .normalize().scale(distance_from_object);
        camera.position = add3dHeigth(target_object_position).add(offset_from_object).toVector3();

        return Camera{
            .camera = camera,
            .distance_from_object = distance_from_object,
            .target_distance_from_object = distance_from_object,
            .angle_from_ground = default_angle_from_ground,
            .target_angle_from_ground = default_angle_from_ground,
        };
    }

    /// Interpolate between this cameras state and another cameras state.
    pub fn lerp(self: Camera, other: Camera, t: f32) Camera {
        var camera = self.camera;
        camera.position = math.Vector3d.fromVector3(self.camera.position)
            .lerp(math.Vector3d.fromVector3(other.camera.position), t).toVector3();
        camera.target = math.Vector3d.fromVector3(self.camera.target)
            .lerp(math.Vector3d.fromVector3(other.camera.target), t).toVector3();

        return Camera{
            .camera = camera,
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

    pub fn increaseDistanceToObject(self: *Camera, offset: f32) void {
        self.target_distance_from_object =
            std.math.max(self.target_distance_from_object + offset, 5);
    }

    /// Angle between 0 and 1.55 (89 degrees). Will be clamped into this range.
    pub fn setAngleFromGround(self: *Camera, angle: f32) void {
        self.target_angle_from_ground = std.math.clamp(angle, 0, math.degreesToRadians(89));
    }

    pub fn resetAngleFromGround(self: *Camera) void {
        self.target_angle_from_ground = default_angle_from_ground;
    }

    pub fn get3DRay(self: Camera, mouse_position_on_screen: rl.Vector2) collision.Ray3d {
        const raylib_ray = rl.GetMouseRay(mouse_position_on_screen, self.camera);
        return .{
            .start_position = math.Vector3d.fromVector3(raylib_ray.position),
            .direction = math.Vector3d.fromVector3(raylib_ray.direction),
        };
    }

    pub fn get3DRayFromTargetToSelf(self: Camera) collision.Ray3d {
        return .{
            .start_position = math.Vector3d.fromVector3(self.camera.target),
            .direction = math.Vector3d.fromVector3(self.camera.position)
                .subtract(math.Vector3d.fromVector3(self.camera.target))
                .normalize(),
        };
    }

    /// Return a camera for rendering with raylib. Takes an optional distance limit to prevent walls
    /// from covering the cameras target object.
    pub fn getRaylibCamera(self: Camera, max_distance_from_target: ?f32) rl.Camera {
        if (max_distance_from_target) |max_distance| {
            const camera_target = math.Vector3d.fromVector3(self.camera.target);
            const offset = math.Vector3d.fromVector3(self.camera.position)
                .subtract(camera_target);
            if (offset.lengthSquared() < max_distance * max_distance) {
                return self.camera;
            }

            var updated_camera = self.camera;
            updated_camera.position =
                camera_target.add(offset.normalize().scale(max_distance * 0.95)).toVector3();
            return updated_camera;
        }
        return self.camera;
    }

    pub fn getDirectionToTarget(self: Camera) math.FlatVector {
        const position = math.FlatVector.fromVector3(self.camera.position);
        const target = math.FlatVector.fromVector3(self.camera.target);
        return target.subtract(position).normalize();
    }

    pub fn processElapsedTick(
        self: *Camera,
        target_object_position: math.FlatVector,
        target_object_looking_direction: math.FlatVector,
    ) void {
        self.updateAngleFromGround();
        const y_rotated_camera_offset =
            self.computeYRotatedCameraOffset(target_object_looking_direction);
        const camera_target = math.Vector3d.fromVector3(self.camera.target)
            .lerp(add3dHeigth(target_object_position), camera_follow_speed);
        self.camera.target = camera_target.toVector3();
        self.camera.position = camera_target.add(y_rotated_camera_offset).toVector3();
        self.updateCameraDistanceFromObject();
    }

    fn updateAngleFromGround(self: *Camera) void {
        if (math.isEqual(self.angle_from_ground, self.target_angle_from_ground)) {
            return;
        }
        self.angle_from_ground = math.lerp(
            self.angle_from_ground,
            self.target_angle_from_ground,
            camera_follow_speed,
        );

        const camera_position = math.Vector3d.fromVector3(self.camera.position);
        const camera_target = math.Vector3d.fromVector3(self.camera.target);
        const camera_offset = camera_position.subtract(camera_target);
        const flat_camera_direction = camera_offset.toFlatVector().normalize();
        const rotation_axis = flat_camera_direction.negate().rotateRightBy90Degrees();
        const rotated_camera_direction =
            flat_camera_direction.toVector3d().rotate(
            rotation_axis.toVector3d(),
            -self.angle_from_ground,
        );
        self.camera.position =
            camera_target.add(rotated_camera_direction.scale(self.distance_from_object))
            .toVector3();
    }

    fn computeYRotatedCameraOffset(
        self: Camera,
        target_object_looking_direction: math.FlatVector,
    ) math.Vector3d {
        const camera_position = math.Vector3d.fromVector3(self.camera.position);
        const camera_target = math.Vector3d.fromVector3(self.camera.target);
        const camera_offset = camera_position.subtract(camera_target);
        const object_back_direction = target_object_looking_direction.negate();
        const rotation_step = camera_follow_speed * camera_offset.toFlatVector()
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
            camera_follow_speed,
        );

        const camera_position = math.Vector3d.fromVector3(self.camera.position);
        const camera_target = math.Vector3d.fromVector3(self.camera.target);
        const camera_offset = camera_position.subtract(camera_target);
        const rescaled_camera_offset = camera_offset.normalize().scale(self.distance_from_object);
        self.camera.position = camera_target.add(rescaled_camera_offset).toVector3();
    }

    fn add3dHeigth(target_object_position: math.FlatVector) math.Vector3d {
        return target_object_position.toVector3d().add(math.Vector3d.y_axis.scale(3));
    }
};
