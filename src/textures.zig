//! Helpers for loading all known textures.

const std = @import("std");
const rl = @import("raylib");
const glad = @cImport(@cInclude("external/glad.h"));
const Error = @import("error.zig").Error;

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
                return Error.FailedToLoadTextureFile;
            }

            mapping.value.* = try textureFromImage(&image);
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
fn textureFromImage(image: *rl.Image) !rl.Texture {
    defer rl.UnloadImage(image.*);

    var texture = rl.LoadTextureFromImage(image.*);
    if (texture.id == 0) {
        return Error.FailedToLoadTextureFile;
    }

    glad.glBindTexture(glad.GL_TEXTURE_2D, texture.id);
    glad.glTexParameteri(glad.GL_TEXTURE_2D, glad.GL_TEXTURE_WRAP_S, glad.GL_REPEAT);
    glad.glTexParameteri(glad.GL_TEXTURE_2D, glad.GL_TEXTURE_WRAP_T, glad.GL_REPEAT);
    glad.glTexParameteri(glad.GL_TEXTURE_2D, glad.GL_TEXTURE_MAG_FILTER, glad.GL_NEAREST);
    glad.glTexParameteri(glad.GL_TEXTURE_2D, glad.GL_TEXTURE_MIN_FILTER, glad.GL_LINEAR_MIPMAP_NEAREST);
    glad.glBindTexture(glad.GL_TEXTURE_2D, 0);

    rl.GenTextureMipmaps(&texture);

    return texture;
}
