//! Helpers for loading all known textures.

const std = @import("std");
const rl = @import("raylib");
const util = @import("util.zig");

pub const Name = enum { floor, gem, player, wall };
pub const RaylibAssets = struct { texture: rl.Texture, material: rl.Material };

pub const Collection = struct {
    asset_mappings: std.EnumArray(Name, RaylibAssets),

    pub fn loadFromDisk() util.RaylibError!Collection {
        const paths = getNameToPathMappings();
        var asset_mappings = std.EnumArray(Name, RaylibAssets).initUndefined();

        var iterator = asset_mappings.iterator();
        while (iterator.next()) |mapping| {
            const texture = rl.LoadTexture(paths.get(mapping.key));
            if (texture.id == 0) {
                var cleanup_iterator = asset_mappings.iterator();
                while (cleanup_iterator.next()) |mapping_to_destroy| {
                    if (mapping_to_destroy.key == mapping.key) {
                        break;
                    }
                    rl.UnloadMaterial(mapping_to_destroy.value.material);
                }
                return util.RaylibError.FailedToLoadTextureFile;
            }

            var material = rl.LoadMaterialDefault();
            rl.SetMaterialTexture(&material, @enumToInt(rl.MATERIAL_MAP_DIFFUSE), texture);
            mapping.value.* = RaylibAssets{ .texture = texture, .material = material };
        }

        return Collection{ .asset_mappings = asset_mappings };
    }

    pub fn destroy(self: *Collection) void {
        var iterator = self.asset_mappings.iterator();
        while (iterator.next()) |mapping| {
            rl.UnloadMaterial(mapping.value.material);
        }
    }

    /// The returned assets should not be freed by the caller.
    pub fn get(self: Collection, name: Name) RaylibAssets {
        return self.asset_mappings.get(name);
    }

    fn getNameToPathMappings() std.EnumArray(Name, [:0]const u8) {
        var paths = std.EnumArray(Name, [:0]const u8).initUndefined();
        paths.set(Name.floor, "assets/floor.png");
        paths.set(Name.gem, "assets/gem.png");
        paths.set(Name.player, "assets/player.png");
        paths.set(Name.wall, "assets/wall.png");
        return paths;
    }
};