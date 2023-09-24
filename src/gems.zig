//! Contains all the code related to gem collecting.

const collision = @import("collision.zig");
const std = @import("std");
const math = @import("math.zig");
const LevelGeometry = @import("level_geometry.zig").LevelGeometry;
const BillboardData = @import("rendering.zig").BillboardRenderer.BillboardData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;

pub const CollisionObject = struct {
    /// Unique identifier, distinct from all other collision objects.
    id: u64,
    boundaries: collision.Circle,
    /// Height of the object colliding with the gem. Needed for animations.
    height: f32,
};

pub const Collection = struct {
    gems: std.ArrayList(InterpolatableGem),

    /// Keeps a reference to the given allocator.
    pub fn create(allocator: std.mem.Allocator) Collection {
        return Collection{ .gems = std.ArrayList(InterpolatableGem).init(allocator) };
    }

    pub fn destroy(self: *Collection) void {
        self.gems.deinit();
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

    /// Return the amount of billboards to be drawn after the last call to processElapsedTick().
    /// The returned value will be invalidated by another call to processElapsedTick().
    pub fn getBillboardCount(self: Collection) usize {
        return self.gems.items.len;
    }

    /// Populates the given slice with billboard data for rendering. The given slice must have
    /// enough space to fit all billboards in this collection. Use getBillboardCount() to retrieve
    /// the count for the current tick.
    pub fn populateBillboardData(
        self: Collection,
        data: []BillboardData,
        sprite_sheet_texture: SpriteSheetTexture,
        collision_objects: []const CollisionObject,
        interval_between_previous_and_current_tick: f32,
    ) void {
        std.debug.assert(self.gems.items.len <= data.len);
        for (self.gems.items, 0..) |gem_states, index| {
            data[index] = gem_states.state_at_previous_tick.lerp(
                gem_states.state_at_next_tick,
                interval_between_previous_and_current_tick,
            ).getBillboardData(collision_objects, sprite_sheet_texture);
        }
    }

    pub fn addGem(self: *Collection, position: math.FlatVector) !void {
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
};

const Gem = struct {
    /// Width of the gem in the game world.
    width: f32,
    boundaries: collision.Circle,

    /// This value will progress from 0 to 1. Only then the following values will be considered.
    spawn_animation_progress: f32,

    /// This value will progress from 0 to 1 when the object gets picked up.
    pickup_animation_progress: ?f32,
    /// Contains the id of the object which collided with this gem. Only used when
    /// pickup_animation_progress is not null.
    collided_object_id: u64,

    fn create(position: math.FlatVector) Gem {
        return Gem{
            .width = 0.4,
            .boundaries = collision.Circle{
                .position = position,
                .radius = 1.2, // Larger than width to make picking up gems easier.
            },
            .spawn_animation_progress = 0,
            .pickup_animation_progress = null,
            .collided_object_id = 0,
        };
    }

    fn lerp(self: Gem, other: Gem, t: f32) Gem {
        const self_progress = self.pickup_animation_progress orelse 0;
        const other_progress = other.pickup_animation_progress orelse 0;
        return Gem{
            .width = math.lerp(self.width, other.width, t),
            .boundaries = self.boundaries.lerp(other.boundaries, t),
            .spawn_animation_progress = math.lerp(
                self.spawn_animation_progress,
                other.spawn_animation_progress,
                t,
            ),
            .pickup_animation_progress = if (self.pickup_animation_progress == null and
                other.pickup_animation_progress == null)
                null
            else
                math.lerp(self_progress, other_progress, t),
            .collided_object_id = if (t < 0.5)
                self.collided_object_id
            else
                other.collided_object_id,
        };
    }

    fn getBillboardData(
        self: Gem,
        collision_objects: []const CollisionObject,
        sprite_sheet_texture: SpriteSheetTexture,
    ) BillboardData {
        const source = sprite_sheet_texture.getSpriteTexcoords(.gem);
        const sprite_aspect_ratio = sprite_sheet_texture.getSpriteAspectRatio(.gem);
        var billboard_data = BillboardData{
            .position = .{
                .x = self.boundaries.position.x,
                .y = self.width * sprite_aspect_ratio / 2,
                .z = self.boundaries.position.z,
            },
            .size = .{
                .w = self.width,
                .h = self.width * sprite_aspect_ratio,
            },
            .source_rect = .{ .x = source.x, .y = source.y, .w = source.w, .h = source.h },
        };
        if (self.spawn_animation_progress < 1) {
            const jump_heigth = 1.5;
            const length = self.width * self.spawn_animation_progress;
            const t = (self.spawn_animation_progress - 0.5) * 2;
            const y = (1 - t * t + length / 2) * jump_heigth;
            billboard_data.position = .{
                .x = self.boundaries.position.x,
                .y = y,
                .z = self.boundaries.position.z,
            };
        } else if (self.pickup_animation_progress) |progress| {
            const lerp_destination = for (collision_objects) |object| {
                if (object.id == self.collided_object_id) {
                    break math.Vector3d{
                        .x = object.boundaries.position.x,
                        .y = object.height / 2,
                        .z = object.boundaries.position.z,
                    };
                }
            } else self.boundaries.position.toVector3d();

            const lerp_start = math.Vector3d{
                .x = self.boundaries.position.x,
                .y = self.width * sprite_aspect_ratio / 2,
                .z = self.boundaries.position.z,
            };
            const lerped_position = lerp_start.lerp(lerp_destination, progress);
            billboard_data.position.x = lerped_position.x;
            billboard_data.position.y = lerped_position.y;
            billboard_data.position.z = lerped_position.z;
            billboard_data.size.w = self.width * (1 - progress);
            billboard_data.size.h = billboard_data.size.w * sprite_aspect_ratio;
        }
        return billboard_data;
    }

    fn processElapsedTick(self: *Gem) void {
        if (self.spawn_animation_progress < 1) {
            self.spawn_animation_progress = self.spawn_animation_progress + 0.02;
        } else if (self.pickup_animation_progress) |*progress| {
            progress.* = progress.* + 0.02;
        }
    }

    /// If a collision was found it will return true and start the pickup animation.
    fn processCollision(self: *Gem, collision_object: CollisionObject, level_geometry: LevelGeometry) bool {
        if (self.spawn_animation_progress < 1) {
            return false;
        }

        const collision_object_position = collision_object.boundaries.position;
        if (self.pickup_animation_progress == null and
            self.boundaries.collidesWithCircle(collision_object.boundaries) != null and
            !level_geometry.isSolidWallBetweenPoints(
            .{ self.boundaries.position, collision_object_position },
        )) {
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
