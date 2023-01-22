//! Helpers for loading all known textures.

const std = @import("std");
const gl = @import("gl");
const Error = @import("error.zig").Error;
const sdl = @import("sdl.zig");

/// Array of tileable/wrapping textures.
pub const TileableArrayTexture = struct {
    /// GL_TEXTURE_2D_ARRAY.
    id: c_uint,

    /// The ordinal values of these enums can be passed to shaders to index array texture layers.
    pub const LayerId = enum(u8) {
        grass,
        hedge,
        metal_fence,
        stone_floor,
        wall,
        water_frame_0,
        water_frame_1,
        water_frame_2,
    };

    pub fn loadFromDisk() !TileableArrayTexture {
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
        gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);

        for (std.enums.values(LayerId)) |value, index| {
            var path_buffer: [64]u8 = undefined;
            const texture_path = try std.fmt.bufPrintZ(path_buffer[0..], "assets/{s}.png", .{
                @tagName(value),
            });

            var image = try loadImageRGBA8(texture_path);
            defer sdl.SDL_FreeSurface(image);

            image = try scale(image, texture_path, texture_width, texture_height);

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
                image.*.pixels,
            );
        }

        gl.generateMipmap(gl.TEXTURE_2D_ARRAY);
        return .{ .id = id };
    }

    pub fn destroy(self: *TileableArrayTexture) void {
        gl.deleteTextures(1, &self.id);
    }

    fn setupMipMapLevel(level: c_int, width: c_int, height: c_int) void {
        gl.texImage3D(
            gl.TEXTURE_2D_ARRAY,
            level,
            gl.RGBA8,
            width,
            height,
            @typeInfo(LayerId).Enum.fields.len,
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            null,
        );
    }
};

pub const Name = enum(u8) {
    gem,
    player,
    small_bush,
};

pub const Collection = struct {
    textures: std.EnumArray(Name, c_uint),

    pub fn loadFromDisk() !Collection {
        var textures = std.EnumArray(Name, c_uint).initUndefined();
        var iterator = textures.iterator();
        while (iterator.next()) |mapping| {
            errdefer {
                var cleanup_iterator = textures.iterator();
                while (cleanup_iterator.next()) |mapping_to_destroy| {
                    if (mapping_to_destroy.key == mapping.key) {
                        break;
                    }
                    gl.deleteTextures(1, mapping_to_destroy.value);
                }
            }

            var texture_path_buffer: [64]u8 = undefined;
            const texture_path = try std.fmt.bufPrintZ(
                texture_path_buffer[0..],
                "assets/{s}.png",
                .{@tagName(mapping.key)},
            );

            const image = try loadImageRGBA8(texture_path);
            defer sdl.SDL_FreeSurface(image);

            var id: c_uint = undefined;
            gl.genTextures(1, &id);
            if (id == 0) {
                return Error.FailedToLoadTextureFile;
            }
            errdefer gl.deleteTextures(1, &id);

            gl.bindTexture(gl.TEXTURE_2D, id);
            gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                image.w,
                image.h,
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                image.*.pixels,
            );
            configureCurrentTexture(gl.TEXTURE_2D);
            gl.generateMipmap(gl.TEXTURE_2D);
            gl.bindTexture(gl.TEXTURE_2D, 0);

            mapping.value.* = id;
        }

        return Collection{ .textures = textures };
    }

    pub fn destroy(self: *Collection) void {
        var iterator = self.textures.iterator();
        while (iterator.next()) |mapping| {
            gl.deleteTextures(1, mapping.value);
        }
    }

    /// The returned texture should not be unloaded by the caller.
    pub fn get(self: Collection, name: Name) c_uint {
        return self.textures.get(name);
    }
};

fn configureCurrentTexture(texture_type: c_uint) void {
    gl.texParameteri(texture_type, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(texture_type, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.texParameteri(texture_type, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(texture_type, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
}

fn loadImageRGBA8(image_path: [*:0]const u8) !*sdl.SDL_Surface {
    var image = sdl.IMG_Load(image_path);
    if (image == null) {
        std.log.err("failed to load image file: {s}: \"{s}\"", .{
            sdl.SDL_GetError(), image_path,
        });
        return Error.FailedToLoadTextureFile;
    }
    defer sdl.SDL_FreeSurface(image);

    const formatted_image = sdl.SDL_ConvertSurfaceFormat(image, sdl.SDL_PIXELFORMAT_RGBA32, 0);
    if (formatted_image == null) {
        std.log.err("failed to convert image to RGBA8: {s}: \"{s}\"", .{
            sdl.SDL_GetError(), image_path,
        });
        return Error.FailedToLoadTextureFile;
    }

    return formatted_image;
}

/// Will consume the given surface on success.
fn scale(
    image: *sdl.SDL_Surface,
    image_path: [*:0]const u8,
    new_width: u16,
    new_height: u16,
) !*sdl.SDL_Surface {
    if (image.w == new_width and image.h == new_height) {
        return image;
    }
    std.log.info("image size is not {}x{}, trying to rescale: \"{s}\"", .{
        new_width, new_height, image_path,
    });

    const scaled_surface = sdl.SDL_CreateRGBSurfaceWithFormat(
        0,
        new_width,
        new_height,
        image.format.*.BitsPerPixel,
        image.*.format.*.format,
    );
    if (scaled_surface == null) {
        std.log.err("failed to scale image to {}x{}: {s}: \"{s}\"", .{
            new_width, new_height, sdl.SDL_GetError(), image_path,
        });
        return Error.FailedToLoadTextureFile;
    }
    errdefer sdl.SDL_FreeSurface(scaled_surface);

    if (sdl.SDL_BlitScaled(image, null, scaled_surface, null) != 0) {
        std.log.err("failed to scale image to {}x{}: {s}: \"{s}\"", .{
            new_width, new_height, sdl.SDL_GetError(), image_path,
        });
        return Error.FailedToLoadTextureFile;
    }
    sdl.SDL_FreeSurface(image);
    return scaled_surface;
}
