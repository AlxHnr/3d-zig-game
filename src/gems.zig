//! Contains all the code related to gem collecting.

const collision = @import("collision.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");
const std = @import("std");
const util = @import("util.zig");
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;

pub const CollisionObject = struct {
    /// Unique identifier, distinct from all other collision objects.
    id: u64,
    boundaries: collision.Circle,
};

pub const Collection = struct {
    gems: std.ArrayList(InterpolatableGem),
    gem_texture: rl.Texture,
    /// Not owned by this collection.
    billboard_shader: rl.Shader,

    /// Keeps a reference to the given allocator and shader for its entire lifetime. Will own the
    /// given texture.
    pub fn create(
        allocator: std.mem.Allocator,
        gem_texture: rl.Texture,
        billboard_shader: rl.Shader,
    ) Collection {
        return Collection{
            .gems = std.ArrayList(InterpolatableGem).init(allocator),
            .gem_texture = gem_texture,
            .billboard_shader = billboard_shader,
        };
    }

    pub fn destroy(self: *Collection) void {
        self.gems.deinit();
        rl.UnloadTexture(self.gem_texture);
    }

    pub fn draw(
        self: Collection,
        camera: rl.Camera,
        collision_objects: []const CollisionObject,
        interval_between_previous_and_current_tick: f32,
    ) void {
        rl.BeginShaderMode(self.billboard_shader);
        for (self.gems.items) |gem| {
            gem.state_at_previous_tick.lerp(
                gem.state_at_next_tick,
                interval_between_previous_and_current_tick,
            ).draw(camera, self.gem_texture, collision_objects);
        }
        rl.EndShaderMode();
    }

    pub fn processElapsedTick(self: *Collection) void {
        var index: usize = 0;
        var gems_total = self.gems.items.len;
        while (index < gems_total) {
            var gem = &self.gems.items[index];
            gem.state_at_previous_tick = gem.state_at_next_tick;
            gem.state_at_next_tick.processElapsedTick();

            if (gem.state_at_next_tick.isExpired()) {
                _ = self.gems.orderedRemove(index);
                gems_total = gems_total - 1;
            } else {
                index = index + 1;
            }
        }
    }

    pub fn addGem(self: *Collection, position: util.FlatVector) !void {
        const gem = try self.gems.addOne();
        const gem_state = Gem.create(position);
        gem.* = InterpolatableGem{
            .state_at_next_tick = gem_state,
            .state_at_previous_tick = gem_state,
        };
    }

    /// Count how many gems collide with the given object. All colliding gems will be consumed.
    pub fn processCollision(
        self: *Collection,
        collision_object: CollisionObject,
        level_geometry: LevelGeometry,
    ) usize {
        var gems_collected: usize = 0;
        for (self.gems.items) |*gem| {
            if (gem.state_at_next_tick.processCollision(collision_object, level_geometry)) {
                gems_collected = gems_collected + 1;
            }
        }
        return gems_collected;
    }

    pub fn getGemTexture(self: Collection) rl.Texture {
        return self.gem_texture;
    }
};

const Gem = struct {
    /// Width and height of the gem in the game world.
    side_length: f32,
    boundaries: collision.Circle,
    /// This value will progress from 0 to 1 when the object gets picked up.
    pickup_animation_progress: ?f32,
    /// Contains the id of the object which collided with this gem. Only used when
    /// pickup_animation_progress is not null.
    collided_object_id: u64,

    fn create(position: util.FlatVector) Gem {
        return Gem{
            .side_length = 0.4,
            .boundaries = collision.Circle{
                .position = position,
                .radius = 1.2, // Larger than side_length to make picking up gems easier.
            },
            .pickup_animation_progress = null,
            .collided_object_id = 0,
        };
    }

    fn lerp(self: Gem, other: Gem, interval: f32) Gem {
        const self_progress = self.pickup_animation_progress orelse 0;
        const other_progress = other.pickup_animation_progress orelse 0;
        return Gem{
            .side_length = rm.Lerp(self.side_length, other.side_length, interval),
            .boundaries = self.boundaries.lerp(other.boundaries, interval),
            .pickup_animation_progress = if (self.pickup_animation_progress == null and
                other.pickup_animation_progress == null)
                null
            else
                rm.Lerp(self_progress, other_progress, interval),
            .collided_object_id = if (interval < 0.5)
                self.collided_object_id
            else
                other.collided_object_id,
        };
    }

    fn draw(
        self: Gem,
        camera: rl.Camera,
        texture: rl.Texture,
        collision_objects: []const CollisionObject,
    ) void {
        if (self.pickup_animation_progress) |progress| {
            const lerp_destination = for (collision_objects) |object| {
                if (object.id == self.collided_object_id) {
                    break object.boundaries.position;
                }
            } else self.boundaries.position;
            const position = self.boundaries.position.lerp(lerp_destination, progress);
            const position_3d =
                rl.Vector3{ .x = position.x, .y = self.side_length / 2, .z = position.z };
            const length = self.side_length * (1 - progress);
            rl.DrawBillboard(camera, texture, position_3d, length, rl.WHITE);
        } else {
            const position_3d = rl.Vector3{
                .x = self.boundaries.position.x,
                .y = self.side_length / 2,
                .z = self.boundaries.position.z,
            };
            rl.DrawBillboard(camera, texture, position_3d, self.side_length, rl.WHITE);
        }
    }

    fn processElapsedTick(self: *Gem) void {
        if (self.pickup_animation_progress) |*progress| {
            progress.* = progress.* + 0.02;
        }
    }

    /// If a collision was found it will return true and start the pickup animation.
    fn processCollision(self: *Gem, collision_object: CollisionObject, level_geometry: LevelGeometry) bool {
        const collision_object_position = collision_object.boundaries.position;
        if (self.pickup_animation_progress == null and
            self.boundaries.collidesWithCircle(collision_object.boundaries) != null and
            !level_geometry.collidesWithLine(self.boundaries.position, collision_object_position))
        {
            self.pickup_animation_progress = 0;
            self.collided_object_id = collision_object.id;
            return true;
        }
        return false;
    }

    fn isExpired(self: Gem) bool {
        return self.pickup_animation_progress orelse 0 > 1;
    }
};

const InterpolatableGem = struct {
    state_at_next_tick: Gem,
    state_at_previous_tick: Gem,
};
