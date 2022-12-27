//! Helpers for loading all known textures.

const std = @import("std");
const rl = @import("raylib");
const util = @import("util.zig");

pub const Name = enum { floor, gem, hedge, player, wall };
pub const RaylibAsset = struct { texture: rl.Texture, material: rl.Material };

pub const Collection = struct {
    asset_mappings: std.EnumArray(Name, RaylibAsset),

    pub fn loadFromDisk() !Collection {
        var asset_mappings = std.EnumArray(Name, RaylibAsset).initUndefined();
        var iterator = asset_mappings.iterator();
        while (iterator.next()) |mapping| {
            var asset_path_buffer: [64]u8 = undefined;
            const asset_path = try std.fmt.bufPrintZ(
                asset_path_buffer[0..],
                "assets/{s}.png",
                .{@tagName(mapping.key)},
            );

            const texture = rl.LoadTexture(asset_path);
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
            mapping.value.* = RaylibAsset{ .texture = texture, .material = material };
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
    pub fn get(self: Collection, name: Name) RaylibAsset {
        return self.asset_mappings.get(name);
    }
};
