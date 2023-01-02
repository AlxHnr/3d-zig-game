pub const BottomlessCube = struct {
    pub const vertices = computeVertices();

    /// Describes how texture coordinates are derived in the vertex shader. Each side of a
    /// transformed cube can have a different length. This enum is used to prevent texture
    /// stretching and ensure proper tiling/repetition.
    pub const texture_coord_scale_values = [30]TextureCoordScale{
        // Front side.
        .none_none,      .none_height,     .width_none,
        .none_height,    .width_height,    .width_none,

        // Left side.
        .thickness_none, .none_none,       .none_height,
        .thickness_none, .none_height,     .thickness_height,

        // Top side.
        .none_thickness, .width_none,      .none_none,
        .none_thickness, .width_thickness, .width_none,

        // Back side.
        .width_none,     .none_none,       .width_height,
        .width_height,   .none_none,       .none_height,

        // Right side.
        .none_none,      .none_height,     .thickness_none,
        .thickness_none, .none_height,     .thickness_height,
    };

    pub const TextureCoordScale = enum(u8) {
        none_none,
        width_none,
        width_height,
        none_height,
        thickness_none,
        thickness_height,
        width_thickness,
        none_thickness,
    };

    fn computeVertices() [90]f32 {
        const corners = [8][3]f32{
            .{ 0, 1, 0.5 },
            .{ 0, 0, 0.5 },
            .{ 1, 1, 0.5 },
            .{ 1, 0, 0.5 },
            .{ 0, 1, -0.5 },
            .{ 0, 0, -0.5 },
            .{ 1, 1, -0.5 },
            .{ 1, 0, -0.5 },
        };
        const corner_indices = [30]u3{
            0, 1, 2, 1, 3, 2, // Front side.
            0, 4, 5, 0, 5, 1, // Left side.
            0, 6, 4, 0, 2, 6, // Top side.
            4, 6, 5, 5, 6, 7, // Back side.
            2, 3, 6, 6, 3, 7, // Right side.
        };

        var result: [90]f32 = undefined;
        for (corner_indices) |corner_index, index| {
            result[index * 3 + 0] = corners[corner_index][0];
            result[index * 3 + 1] = corners[corner_index][1];
            result[index * 3 + 2] = corners[corner_index][2];
        }
        return result;
    }
};
