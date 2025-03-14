//! Helpers for loading all known textures.

const Error = @import("error.zig").Error;
const Fix32 = @import("math.zig").Fix32;
const fp = Fix32.fp;
const gl = @import("gl");
const rendering = @import("rendering.zig");
const sdl = @import("sdl.zig");
const std = @import("std");

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
            const texture_path = try std.fmt.bufPrintZ(&path_buffer, "assets/{s}.png", .{
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
            @typeInfo(LayerId).@"enum".fields.len,
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
        const file_path = "assets/8x8_padded_spritesheet.png";
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
        black_magician_with_book,
        blue_frozen_statue,
        blue_grey_dragon,
        dialog_box_bottom_center,
        dialog_box_bottom_left,
        dialog_box_bottom_right,
        dialog_box_center_center,
        dialog_box_center_left,
        dialog_box_center_right,
        dialog_box_top_center,
        dialog_box_top_left,
        dialog_box_top_right,
        gem,
        green_ghost_warrior,
        player_back_frame_0,
        player_back_frame_1,
        player_back_frame_2,
        player_front_frame_0,
        player_front_frame_1,
        player_front_frame_2,
        red_lava_worm,
        small_bush,
        white_block,
        yellow_floating_eye,
    };

    pub fn getSpriteSourceRectangle(
        _: SpriteSheetTexture,
        sprite_id: SpriteId,
    ) rendering.TextureSourceRectangle {
        return sprite_source_pixel_map[@intFromEnum(sprite_id)];
    }

    /// Returns the aspect ratio (height / width) of the specified sprite.
    pub fn getSpriteAspectRatio(_: SpriteSheetTexture, sprite_id: SpriteId) Fix32 {
        return sprite_aspect_ratio_map.get(sprite_id);
    }

    /// Returns a question mark if the given codepoint is not supported or does not represent a
    /// printable character. All font characters have an aspect ratio of 1.
    pub fn getFontCharacterSourceRectangle(
        _: SpriteSheetTexture,
        codepoint: u21,
    ) rendering.TextureSourceRectangle {
        return font_source_pixel_map[getCharacterIndex(codepoint)];
    }

    /// Gap between consecutive characters in a sentence.
    pub const FontLetterSpacing = struct { horizontal: Fix32, vertical: Fix32 };

    pub fn getFontLetterSpacing(_: SpriteSheetTexture, scaling_factor: Fix32) FontLetterSpacing {
        const character_padding_length = fp(1);
        const padding = character_padding_length.div(fp(font_character_side_length)).mul(
            scaling_factor,
        );
        return .{ .horizontal = padding, .vertical = padding };
    }

    // Return a suitable character size for rendering without scaling artifacts. Takes whole
    // integers like 1, 2, 3, ...
    pub fn getFontSizeMultiple(_: SpriteSheetTexture, step_factor: u8) u16 {
        return step_factor * font_character_side_length;
    }

    const texture_width = 512;
    const texture_height = 512;
    const font_character_count = 94;
    const custom_character_count = 8; // Extra arrows in spritesheet.
    const font_character_side_length = 8;

    const sourceRectangle = rendering.TextureSourceRectangle.create;
    const sprite_source_pixel_map = std.enums.directEnumArray(
        SpriteId,
        rendering.TextureSourceRectangle,
        @typeInfo(SpriteId).@"enum".fields.len,
        .{
            .black_magician_with_book = sourceRectangle(72, 112, 23, 32),
            .blue_frozen_statue = sourceRectangle(0, 168, 32, 31),
            .blue_grey_dragon = sourceRectangle(32, 128, 32, 32),
            .dialog_box_bottom_center = sourceRectangle(120, 80, 8, 8),
            .dialog_box_bottom_left = sourceRectangle(104, 80, 8, 8),
            .dialog_box_bottom_right = sourceRectangle(136, 80, 8, 8),
            .dialog_box_center_center = sourceRectangle(120, 64, 8, 8),
            .dialog_box_center_left = sourceRectangle(104, 64, 8, 8),
            .dialog_box_center_right = sourceRectangle(136, 64, 8, 8),
            .dialog_box_top_center = sourceRectangle(120, 48, 8, 8),
            .dialog_box_top_left = sourceRectangle(104, 48, 8, 8),
            .dialog_box_top_right = sourceRectangle(136, 48, 8, 8),
            .gem = sourceRectangle(72, 88, 14, 13),
            .green_ghost_warrior = sourceRectangle(0, 128, 24, 31),
            .player_back_frame_0 = sourceRectangle(0, 48, 16, 30),
            .player_back_frame_1 = sourceRectangle(24, 48, 16, 30),
            .player_back_frame_2 = sourceRectangle(48, 48, 16, 30),
            .player_front_frame_0 = sourceRectangle(0, 88, 16, 30),
            .player_front_frame_1 = sourceRectangle(24, 88, 16, 30),
            .player_front_frame_2 = sourceRectangle(48, 88, 16, 30),
            .red_lava_worm = sourceRectangle(0, 208, 29, 31),
            .small_bush = sourceRectangle(72, 48, 24, 26),
            .white_block = sourceRectangle(488, 40, 8, 8),
            .yellow_floating_eye = sourceRectangle(40, 168, 16, 24),
        },
    );

    const font_source_pixel_map = blk: {
        const w = font_character_side_length;
        const h = font_character_side_length;

        var result: [font_character_count + custom_character_count]rendering.TextureSourceRectangle =
            undefined;
        for (result[0..font_character_count], 0..) |_, index| {
            result[index] = sourceRectangle(@mod(index, 32) * 16, @divFloor(index, 32) * 16, w, h);
        }
        result[getCharacterIndex(forceDecodeUtf8("←"))] = sourceRectangle(352, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↖"))] = sourceRectangle(368, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↑"))] = sourceRectangle(384, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↗"))] = sourceRectangle(400, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("→"))] = sourceRectangle(416, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↘"))] = sourceRectangle(432, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↓"))] = sourceRectangle(448, 48, w, h);
        result[getCharacterIndex(forceDecodeUtf8("↙"))] = sourceRectangle(464, 48, w, h);

        break :blk result;
    };

    /// Maps sprite ids to (height / width).
    const sprite_aspect_ratio_map = blk: {
        var result: std.EnumArray(SpriteId, Fix32) = undefined;
        for (std.enums.values(SpriteId), 0..) |key, index| {
            const ratio =
                Fix32.fp(sprite_source_pixel_map[index].h).div(
                Fix32.fp(sprite_source_pixel_map[index].w),
            );
            result.set(key, ratio);
        }
        break :blk result;
    };

    fn getCharacterIndex(codepoint: u21) usize {
        if (codepoint >= '!' and codepoint <= '~') {
            return codepoint - '!';
        }
        return switch (codepoint) {
            forceDecodeUtf8("←") => font_character_count + 0,
            forceDecodeUtf8("↖") => font_character_count + 1,
            forceDecodeUtf8("↑") => font_character_count + 2,
            forceDecodeUtf8("↗") => font_character_count + 3,
            forceDecodeUtf8("→") => font_character_count + 4,
            forceDecodeUtf8("↘") => font_character_count + 5,
            forceDecodeUtf8("↓") => font_character_count + 6,
            forceDecodeUtf8("↙") => font_character_count + 7,
            else => getCharacterIndex('?'),
        };
    }

    fn forceDecodeUtf8(bytes: []const u8) u21 {
        return std.unicode.utf8Decode(bytes) catch unreachable;
    }
};

fn loadImageRGBA8(image_path: [*:0]const u8) !*sdl.SDL_Surface {
    const image = sdl.IMG_Load(image_path);
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
