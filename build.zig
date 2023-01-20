const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("3d-zig-game", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_image");
    exe.addPackagePath("gl", "third_party/gl.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest("src/test.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);
}
