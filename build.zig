const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ring_size = b.option(usize, "io_ring_size", "Size of ring buffers used for internal I/O thread communication(default is 64)") orelse 64;

    //lib
    //future options should be added here
    const lib_options = b.addOptions();
    lib_options.addOption(usize, "io_ring_size", ring_size);

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addOptions("config", lib_options);
    const lib = b.addLibrary(.{ .name = "librover", .linkage = .static, .root_module = lib_module });
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
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
    });
    test_module.addOptions("config", lib_options);
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_test = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_test.step);

    //run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Rover");
    run_step.dependOn(&unit_tests.step);
    run_step.dependOn(&run_exe.step);
}
