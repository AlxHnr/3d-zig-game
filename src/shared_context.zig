const DialogController = @import("dialog.zig").Controller;
const Enemy = @import("enemy.zig").Enemy;
const Gem = @import("gem.zig");
const ObjectIdGenerator = @import("util.zig").ObjectIdGenerator;
const SpatialCollection = @import("spatial_partitioning/collection.zig").Collection;
const std = @import("std");

pub const SharedContext = struct {
    object_id_generator: ObjectIdGenerator,

    /// Values from this rng should only be consumed by deterministic code which bases its entire
    /// logic only on the inputs specified in `game_unit.InputButton`. The goal here is to make the
    /// entire engine reproducible across different systems and being able to replay entire games
    /// just by storing user inputs. This is greatly simplifies netcode.
    rng: std.rand.Xoroshiro128,

    enemy_collection: EnemyCollection,
    gem_collection: GemCollection,

    pub const EnemyCollection = SpatialCollection(Enemy, 25);
    pub const GemCollection = SpatialCollection(Gem, 100);

    pub fn create(allocator: std.mem.Allocator) SharedContext {
        return .{
            .object_id_generator = ObjectIdGenerator.create(),
            .rng = std.rand.Xoroshiro128.init(0),
            .enemy_collection = EnemyCollection.create(allocator),
            .gem_collection = GemCollection.create(allocator),
        };
    }

    pub fn destroy(self: *SharedContext) void {
        self.gem_collection.destroy();
        self.enemy_collection.destroy();
    }
};
