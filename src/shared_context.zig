const DialogController = @import("dialog.zig").Controller;
const Enemy = @import("enemy.zig").Enemy;
const GemCollection = @import("gems.zig").Collection;
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

    gem_collection: GemCollection,
    enemies: EnemyCollection,
    dialog_controller: DialogController,

    pub const EnemyCollection = SpatialCollection(Enemy, 7);

    pub fn create(allocator: std.mem.Allocator) !SharedContext {
        var gem_collection = GemCollection.create(allocator);
        errdefer gem_collection.destroy();

        var enemy_collection = try EnemyCollection.create(allocator);
        errdefer enemy_collection.destroy();

        var dialog_controller = try DialogController.create(allocator);
        errdefer dialog_controller.destroy();

        return .{
            .object_id_generator = ObjectIdGenerator.create(),
            .rng = std.rand.Xoroshiro128.init(0),
            .gem_collection = gem_collection,
            .enemies = enemy_collection,
            .dialog_controller = dialog_controller,
        };
    }

    pub fn destroy(self: *SharedContext) void {
        self.dialog_controller.destroy();
        self.enemies.destroy();
        self.gem_collection.destroy();
    }
};
