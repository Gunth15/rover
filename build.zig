const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //lib
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "librover",
        .linkage = .static,
        .root_module = lib_module,
    });

    //libpco
    lib.addCSourceFile(.{ .file = b.path("./src/lib/httpparser/picohttpparser.c") });
    lib.addIncludePath(b.path("./src/lib/httpparser"));

    //link lua
    const lua_dep = b.dependency("lua", .{});
    const lua_lib = lua_dep.artifact("lua");
    lib.linkLibrary(lua_lib);
    b.installArtifact(lib);

    //exe
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.linkLibrary(lib);
    const exe = b.addExecutable(.{ .name = "rover", .root_module = exe_module });
    b.installArtifact(exe);

    //test
    const test_step = b.step("test", "Test Rover");
    const unit_tests = b.addTest(.{ .root_module = lib_module });
    const run_unit_test = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_test.step);

    //run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Rover");
    run_step.dependOn(&unit_tests.step);
    run_step.dependOn(&lib.step);
    run_step.dependOn(&run_exe.step);
}
