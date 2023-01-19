const std = @import("std");
const raylib = @import("third-party/raylib-zig/lib.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("3d-zig-game", "src/main.zig");
    exe.addIncludePath("third-party/raylib-zig/raylib/src");
    exe.addPackagePath("gl", "third_party/gl.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("SDL2");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    raylib.link(exe, false);
    raylib.addAsPackage("raylib", exe);
    raylib.math.addAsPackage("raylib-math", exe);

    const tests = b.addTest("src/test.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    raylib.link(tests, false);
    raylib.addAsPackage("raylib", tests);
    raylib.math.addAsPackage("raylib-math", tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);
}
