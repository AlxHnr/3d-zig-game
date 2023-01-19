//! Helpers for loading all known textures.

const std = @import("std");
const rl = @import("raylib");
const gl = @import("gl");
const Error = @import("error.zig").Error;

/// The ordinal values are passed to shaders to index array textures.
pub const Name = enum(u8) {
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

/// Returns the id of an OpenGL array texture containing all the textures in the `Name` enum. The
/// returned id binds to GL_TEXTURE_2D_ARRAY and has to be destroyed via glDeleteTextures(1, &id).
pub fn loadTextureArray() !c_uint {
    var id: c_uint = undefined;
    gl.genTextures(1, &id);
    if (id == 0) {
        return Error.FailedToLoadTextureFile;
    }
    errdefer gl.deleteTextures(1, &id);

    gl.bindTexture(gl.TEXTURE_2D_ARRAY, id);
    defer gl.bindTexture(gl.TEXTURE_2D_ARRAY, 0);

    const texture_width = 64; // Smaller and larger images get scaled to this.
    const texture_height = texture_width;
    setupMipMapLevel(0, texture_width, texture_height);
    setupMipMapLevel(1, 32, 32);
    setupMipMapLevel(2, 16, 16);
    setupMipMapLevel(3, 8, 8);
    setupMipMapLevel(4, 4, 4);
    setupMipMapLevel(5, 2, 2);
    setupMipMapLevel(6, 1, 1);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_NEAREST);

    for (std.enums.values(Name)) |value, index| {
        var path_buffer: [64]u8 = undefined;
        const texture_path = try std.fmt.bufPrintZ(path_buffer[0..], "assets/{s}.png", .{
            @tagName(value),
        });

        var image = rl.LoadImage(texture_path);
        if (image.data == null) {
            return Error.FailedToLoadTextureFile;
        }
        defer rl.UnloadImage(image);

        rl.ImageFormat(&image, @enumToInt(rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8));
        if (image.format != rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
            std.log.err("Image has wrong format, expected 8-bit RGBA: \"{s}\"\n", .{texture_path});
            return Error.FailedToLoadTextureFile;
        }
        if (image.width != texture_width or image.height != texture_height) {
            rl.ImageResizeNN(&image, texture_width, texture_height);
        }

        gl.texSubImage3D(
            gl.TEXTURE_2D_ARRAY,
            0,
            0,
            0,
            @intCast(c_int, index),
            texture_width,
            texture_height,
            1,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            image.data,
        );
    }

    gl.generateMipmap(gl.TEXTURE_2D_ARRAY);
    return id;
}

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

            const texture = rl.LoadTexture(texture_path);
            if (texture.id == 0) {
                var cleanup_iterator = textures.iterator();
                while (cleanup_iterator.next()) |mapping_to_destroy| {
                    if (mapping_to_destroy.key == mapping.key) {
                        break;
                    }
                    rl.UnloadTexture(mapping_to_destroy.value.*);
                }
                return Error.FailedToLoadTextureFile;
            }

            gl.bindTexture(gl.TEXTURE_2D, texture.id);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_NEAREST);
            gl.generateMipmap(gl.TEXTURE_2D);
            gl.bindTexture(gl.TEXTURE_2D, 0);
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

fn setupMipMapLevel(level: c_int, width: c_int, height: c_int) void {
    gl.texImage3D(
        gl.TEXTURE_2D_ARRAY,
        level,
        gl.RGBA8,
        width,
        height,
        @typeInfo(Name).Enum.fields.len,
        0,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        null,
    );
}
