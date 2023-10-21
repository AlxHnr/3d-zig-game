const MapGeometry = @import("map/geometry.zig").Geometry;
const MovingCircle = @import("game_unit.zig").MovingCircle;
const SpriteData = @import("rendering.zig").SpriteData;
const SpriteSheetTexture = @import("textures.zig").SpriteSheetTexture;
const collision = @import("collision.zig");
const math = @import("math.zig");
const simulation = @import("simulation.zig");
const std = @import("std");

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
        data: []SpriteData,
        spritesheet: SpriteSheetTexture,
        interval_between_previous_and_current_tick: f32,
    ) void {
        std.debug.assert(self.gems.items.len <= data.len);
        for (self.gems.items, 0..) |gem_states, index| {
            data[index] = gem_states.state_at_previous_tick.lerp(
                gem_states.state_at_next_tick,
                interval_between_previous_and_current_tick,
            ).getBillboardData(spritesheet);
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
        other: MovingCircle,
        map_geometry: MapGeometry,
    ) usize {
        var gems_collected: usize = 0;
        for (self.gems.items) |*gem| {
            if (gem.state_at_next_tick.processCollision(other, map_geometry)) {
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
    /// This value will progress from 0 to 1.
    spawn_animation_progress: f32,
    /// This value will progress from 0 to 1 when the object gets picked up.
    pickup_animation_progress: ?f32,

    const animation_speed = simulation.kphToGameUnitsPerTick(10);

    fn create(position: math.FlatVector) Gem {
        return Gem{
            .width = 0.4,
            .boundaries = collision.Circle{
                .position = position,
                .radius = 1.2, // Larger than width to make picking up gems easier.
            },
            .spawn_animation_progress = 0,
            .pickup_animation_progress = null,
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
        };
    }

    fn getBillboardData(self: Gem, spritesheet: SpriteSheetTexture) SpriteData {
        const source = spritesheet.getSpriteTexcoords(.gem);
        const sprite_aspect_ratio = spritesheet.getSpriteAspectRatio(.gem);
        var billboard_data = SpriteData{
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
            const jump_height = 1.5;
            const length = self.width * self.spawn_animation_progress;
            const t = (self.spawn_animation_progress - 0.5) * 2;
            const y = (1 - t * t + length / 2) * jump_height;
            billboard_data.position = .{
                .x = self.boundaries.position.x,
                .y = y,
                .z = self.boundaries.position.z,
            };
        } else if (self.pickup_animation_progress) |progress| {
            billboard_data.position.x = self.boundaries.position.x;
            billboard_data.position.y = self.width * sprite_aspect_ratio / 2;
            billboard_data.position.z = self.boundaries.position.z;
            billboard_data.size.w = self.width * (1 - progress);
            billboard_data.size.h = billboard_data.size.w * sprite_aspect_ratio;
        }
        return billboard_data;
    }

    fn processElapsedTick(self: *Gem) void {
        if (self.spawn_animation_progress < 1) {
            self.spawn_animation_progress += animation_speed;
        } else if (self.pickup_animation_progress) |*progress| {
            progress.* += animation_speed;
        }
    }

    /// If a collision was found it will return true and start the pickup animation.
    fn processCollision(self: *Gem, other: MovingCircle, map_geometry: MapGeometry) bool {
        if (self.spawn_animation_progress < 1 or
            self.pickup_animation_progress != null)
        {
            return false;
        }

        if (other.hasCollidedWithCircle(self.boundaries)) |position| {
            if (!map_geometry.isSolidWallBetweenPoints(self.boundaries.position, position)) {
                self.pickup_animation_progress = 0;
                return true;
            }
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
