const Enemy = @import("enemy.zig");
const MakeCellIndex = @import("spatial_partitioning/cell_index.zig").Index;
const MakeCellRange = @import("spatial_partitioning/cell_range.zig").Range;
const MakeSpatialGrid = @import("spatial_partitioning/grid.zig").Grid;
const fp = @import("math.zig").Fix32.fp;
const assert = @import("std").debug.assert;

pub const Grid = MakeSpatialGrid(Enemy, cell_size, .insert_only);
pub const CellIndex = MakeCellIndex(cell_size);
pub const CellRange = MakeCellRange(cell_size);

pub const PeerGrid = MakeSpatialGrid(Enemy.PeerInfo, peer_grid_cell_size, .insert_only);
pub const PeerCellIndex = MakeCellIndex(peer_grid_cell_size);
pub const PeerCellRange = MakeCellRange(peer_grid_cell_size);

pub const cell_size = 24;
pub const peer_grid_cell_size = 8;
comptime {
    // Ensure that enemy threads don't interfere with each other.
    assert(@mod(cell_size, peer_grid_cell_size) == 0);
}

pub const estimated_enemies_per_cell = blk: {
    const estimated_enemies_per_side =
        fp(peer_grid_cell_size).div(Enemy.peer_overlap_radius).ceil();
    break :blk estimated_enemies_per_side.mul(estimated_enemies_per_side).ceil()
        .mul(fp(2)) // Safety margin.
        .convertTo(usize);
};
