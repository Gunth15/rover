const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const translate_c = b.dependency("translate_c", .{});

    //c imports defenitions
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/vendor/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const lib = buildLibRover(b, &t, target, optimize);
    b.installArtifact(lib);

    //exe
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "c", .module = t.mod },
            .{ .name = "lib", .module = lib.root_module },
        },
    });
    const exe = b.addExecutable(.{
        .name = "rover",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    //test
    const test_step = b.step("test", "Test Rover");
    const unit_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_unit_test = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_test.step);

    //run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Rover");
    run_step.dependOn(&unit_tests.step);
    run_step.dependOn(&lib.step);
    run_step.dependOn(&run_exe.step);
}

fn buildLibRover(
    b: *std.Build,
    t: *const Translator,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = t.mod,
            },
        },
    });

    //lua
    mod.addCSourceFiles(.{
        .root = b.path("src/vendor/lua_5.4.8/src"),
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

    //pico
    mod.addCSourceFile(.{
        .file = b.path("src/vendor/httpparser/picohttpparser.c"),
    });

    //sqlite
    mod.addCSourceFile(.{ .file = b.path("./src/vendor/sqlite-amalgamation-3540100/sqlite3.c") });

    return b.addLibrary(.{ .name = "rover", .linkage = .static, .root_module = mod });
}
