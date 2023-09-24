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

        for (std.enums.values(LayerId), 0..) |value, index| {
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
                @intCast(index),
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

pub const SpriteSheetTexture = struct {
    /// GL_TEXTURE_2D.
    id: c_uint,

    pub fn loadFromDisk() !SpriteSheetTexture {
        const file_path = "assets/8x8_padded_sprite_sheet.png";
        const image = try loadImageRGBA8(file_path);
        defer sdl.SDL_FreeSurface(image);

        if (image.w != texture_width or image.h != texture_height) {
            std.log.err("spritesheet dimensions are not {}x{}: \"{s}\"\n", .{
                texture_width, texture_height, file_path,
            });
            return Error.FailedToLoadTextureFile;
        }

        var id: c_uint = undefined;
        gl.genTextures(1, &id);
        if (id == 0) {
            return Error.FailedToLoadTextureFile;
        }
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
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
        gl.generateMipmap(gl.TEXTURE_2D);
        gl.bindTexture(gl.TEXTURE_2D, 0);

        return .{ .id = id };
    }

    pub fn destroy(self: *SpriteSheetTexture) void {
        gl.deleteTextures(1, &self.id);
    }

    pub const SpriteId = enum(u8) {
        gem,
        player_back_frame_0,
        player_back_frame_1,
        player_back_frame_2,
        player_front_frame_0,
        player_front_frame_1,
        player_front_frame_2,
        small_bush,
    };

    /// Values range from 0 to 1, where (0, 0) is the top left of the sprite sheet.
    pub const TextureCoordinates = struct { x: f32, y: f32, w: f32, h: f32 };

    pub fn getSpriteTexcoords(_: SpriteSheetTexture, sprite_id: SpriteId) TextureCoordinates {
        return sprite_texcoord_map.get(sprite_id);
    }

    /// Returns the aspect ratio (height / width) of the specified sprite.
    pub fn getSpriteAspectRatio(_: SpriteSheetTexture, sprite_id: SpriteId) f32 {
        return sprite_aspect_ratio_map.get(sprite_id);
    }

    /// Returns a question mark if the given codepoint is not supported or does not represent a
    /// printable character. All font characters have an aspect ratio of 1.
    pub fn getFontCharacterTexcoords(self: SpriteSheetTexture, codepoint: u21) TextureCoordinates {
        if (codepoint < '!' or codepoint > '~') {
            return self.getFontCharacterTexcoords('?');
        }
        return font_texcoord_map[codepoint - '!'];
    }

    const font_character_side_length = 8;

    /// Gap between consecutive characters in a sentence.
    pub const FontLetterSpacing = struct { horizontal: f32, vertical: f32 };

    pub fn getFontLetterSpacing(scaling_factor: f32) FontLetterSpacing {
        const character_padding_length = @as(f32, 1);
        const padding = (character_padding_length / @as(f32, font_character_side_length)) *
            scaling_factor;
        return .{ .horizontal = padding, .vertical = padding };
    }

    // Return a suitable character size for rendering without scaling artifacts. Takes whole
    // integers like 1, 2, 3, ...
    pub fn getFontSizeMultiple(step_factor: u8) u16 {
        return step_factor * font_character_side_length;
    }

    const texture_width = 512;
    const texture_height = 512;
    const font_character_count = 94;

    /// Source pixel coordinates with (0, 0) at the top left corner.
    const TextureSourceRectangle = struct { x: u16, y: u16, w: u16, h: u16 };

    const sprite_source_pixel_map = std.enums.directEnumArray(
        SpriteId,
        TextureSourceRectangle,
        @typeInfo(SpriteId).Enum.fields.len,
        .{
            .gem = .{ .x = 72, .y = 88, .w = 14, .h = 14 },
            .player_back_frame_0 = .{ .x = 0, .y = 48, .w = 16, .h = 32 },
            .player_back_frame_1 = .{ .x = 24, .y = 48, .w = 16, .h = 32 },
            .player_back_frame_2 = .{ .x = 48, .y = 48, .w = 16, .h = 32 },
            .player_front_frame_0 = .{ .x = 0, .y = 88, .w = 16, .h = 32 },
            .player_front_frame_1 = .{ .x = 24, .y = 88, .w = 16, .h = 32 },
            .player_front_frame_2 = .{ .x = 48, .y = 88, .w = 16, .h = 32 },
            .small_bush = .{ .x = 72, .y = 48, .w = 24, .h = 26 },
        },
    );
    const font_source_pixel_map = computeFontSourcePixelMap();

    /// Maps sprite ids to OpenGL texture coordinates ranging from 0 to 1, where (0, 0) is the top
    /// left of the sprite sheet.
    const sprite_texcoord_map = computeSpriteTexcoordMap();
    const font_texcoord_map = computeFontTexcoordMap();

    /// Maps sprite ids to (height / width).
    const sprite_aspect_ratio_map = computeSpriteAspectRatioMap();

    fn computeFontSourcePixelMap() [font_character_count]TextureSourceRectangle {
        var result: [font_character_count]TextureSourceRectangle = undefined;
        for (result, 0..) |_, index| {
            result[index] = .{
                .x = @as(u16, @mod(index, 32) * 16),
                .y = @as(u16, @divFloor(index, 32) * 16),
                .w = 8,
                .h = 8,
            };
        }
        return result;
    }

    fn computeSpriteTexcoordMap() std.EnumArray(SpriteId, TextureCoordinates) {
        var result: std.EnumArray(SpriteId, TextureCoordinates) = undefined;
        for (std.enums.values(SpriteId), 0..) |key, index| {
            result.set(key, toTexcoords(sprite_source_pixel_map[index]));
        }
        return result;
    }

    fn computeFontTexcoordMap() [font_character_count]TextureCoordinates {
        var result: [font_character_count]TextureCoordinates = undefined;
        for (result, 0..) |_, index| {
            result[index] = toTexcoords(font_source_pixel_map[index]);
        }
        return result;
    }

    fn toTexcoords(source: TextureSourceRectangle) TextureCoordinates {
        return .{
            .x = @as(f32, source.x) / texture_width,
            .y = @as(f32, source.y) / texture_height,
            .w = @as(f32, source.w) / texture_width,
            .h = @as(f32, source.h) / texture_height,
        };
    }

    fn computeSpriteAspectRatioMap() std.EnumArray(SpriteId, f32) {
        var result: std.EnumArray(SpriteId, f32) = undefined;
        for (std.enums.values(SpriteId), 0..) |key, index| {
            const ratio =
                @as(f32, sprite_source_pixel_map[index].h) /
                @as(f32, sprite_source_pixel_map[index].w);
            result.set(key, ratio);
        }
        return result;
    }
};

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
