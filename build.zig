const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "3d-zig-game",
        .root_source_file = .{ .path = "src/main.zig" },
    });
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_image");
    exe.addAnonymousModule("gl", .{ .source_file = .{ .path = "third_party/gl.zig" } });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_source_file = .{ .path = "src/test.zig" } });
    const test_run_artifact = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run_artifact.step);
}
