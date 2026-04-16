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
        .name = "rover",
        .linkage = .static,
        .root_module = lib_module,
    });

    //libpco
    const pico_lib = b.addLibrary(.{
        .name = "pico",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    pico_lib.addCSourceFile(.{ .file = b.path("./src/lib/httpparser/picohttpparser.c") });
    lib.linkLibrary(pico_lib);
    lib.addIncludePath(b.path("./src/lib/httpparser"));

    //liblua
    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lua_lib.addCSourceFiles(.{
        .root = b.path("src/lib/lua/lua_5.4.8/src"),
        .files = &.{
            "lapi.c",     "lcode.c",    "lctype.c",   "ldebug.c",  "ldo.c",
            "ldump.c",    "lfunc.c",    "lgc.c",      "llex.c",    "lmem.c",
            "lobject.c",  "lopcodes.c", "lparser.c",  "lstate.c",  "lstring.c",
            "ltable.c",   "ltm.c",      "lundump.c",  "lvm.c",     "lzio.c",
            "lauxlib.c",  "lbaselib.c", "lcorolib.c", "ldblib.c",  "liolib.c",
            "lmathlib.c", "loadlib.c",  "loslib.c",   "lstrlib.c", "ltablib.c",
            "lutf8lib.c", "linit.c",
        },
        .flags = &.{"-DLUA_COMPAT_5_3"},
    });
    lua_lib.addIncludePath(b.path("src/lib/lua/lua_5.4.8/src"));

    lib.linkLibrary(lua_lib);
    lib.addIncludePath(b.path("src/lib/lua/lua_5.4.8/src"));

    //exe
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.linkLibrary(lib);
    const exe = b.addExecutable(.{ .name = "rover", .root_module = exe_module });
    exe.addIncludePath(b.path("./src/lib/httpparser"));
    exe.addIncludePath(b.path("src/lib/lua/lua_5.4.8/src"));
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
