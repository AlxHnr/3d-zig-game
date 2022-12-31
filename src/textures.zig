//! Helpers for loading all known textures.

const std = @import("std");
const rl = @import("raylib");
const util = @import("util.zig");

pub const Name = enum {
    gem,
    grass,
    hedge,
    metal_fence,
    player,
    small_bush,
    stone_floor,
    wall,
    water_frame_0,
    water_frame_1,
    water_frame_2,
};
pub const Collection = struct {
    textures: std.EnumArray(Name, rl.Texture),

    pub fn loadFromDisk() !Collection {
        var textures = std.EnumArray(Name, rl.Texture).initUndefined();
        var iterator = textures.iterator();
        while (iterator.next()) |mapping| {
            var texture_path_buffer: [64]u8 = undefined;
            const texture_path = try std.fmt.bufPrintZ(
                texture_path_buffer[0..],
                "assets/{s}.png",
                .{@tagName(mapping.key)},
            );

            var image = rl.LoadImage(texture_path);
            if (image.data == null) {
                var cleanup_iterator = textures.iterator();
                while (cleanup_iterator.next()) |mapping_to_destroy| {
                    if (mapping_to_destroy.key == mapping.key) {
                        break;
                    }
                    rl.UnloadTexture(mapping_to_destroy.value.*);
                }
                return util.Error.FailedToLoadTextureFile;
            }

            const texture = textureFromImage(&image, mapping.key);
            mapping.value.* = texture;
        }

        return Collection{ .textures = textures };
    }

    pub fn destroy(self: *Collection) void {
        var iterator = self.textures.iterator();
        while (iterator.next()) |mapping| {
            rl.UnloadTexture(mapping.value.*);
        }
    }

    /// The returned texture should not be unloaded by the caller.
    pub fn get(self: Collection, name: Name) rl.Texture {
        return self.textures.get(name);
    }
};

/// Will consume the given image.
fn textureFromImage(image: *rl.Image, texture_name: Name) rl.Texture {
    defer rl.UnloadImage(image.*);

    // Apply some tricks to make the artwork look pixely from nearby but not grainy from the
    // distance.
    switch (texture_name) {
        else => return rl.LoadTextureFromImage(image.*),
        .hedge => rl.ImageResizeNN(image, image.width * 5, image.height * 5),
        .stone_floor => rl.ImageResizeNN(image, image.width * 10, image.height * 10),
    }
    var texture = rl.LoadTextureFromImage(image.*);
    rl.GenTextureMipmaps(&texture);
    rl.SetTextureFilter(texture, @enumToInt(rl.FILTER_BILINEAR));
    return texture;
}
