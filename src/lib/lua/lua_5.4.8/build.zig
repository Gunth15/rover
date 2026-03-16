const std = @import("std");
pub fn build(b: *std.Build) void {
    //lua.h luaconf.h lualib.h lauxlib.h lua.hpp
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_module = b.addModule("liblua", .{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
    });
    lib_module.addCMacro("LUA_COMPAT_5_3", "");
    const lib = b.addLibrary(.{ .name = "lua", .root_module = lib_module });
    //lapi.o lcode.o lctype.o ldebug.o ldo.o ldump.o lfunc.o lgc.o llex.o lmem.o lobject.o lopcodes.o lparser.o lstate.o lstring.o ltable.o ltm.o lundump.o lvm.o lzio.o
    //lauxlib.o lbaselib.o lcorolib.o ldblib.o liolib.o lmathlib.o loadlib.o loslib.o lstrlib.o ltablib.o lutf8lib.o linit.o
    lib.addCSourceFiles(.{
        .files = &.{
            "./src/lapi.c",
            "./src/lcode.c",
            "./src/lctype.c",
            "./src/ldebug.c",
            "./src/ldo.c",
            "./src/ldump.c",
            "./src/lfunc.c",
            "./src/lgc.c",
            "./src/llex.c",
            "./src/lmem.c",
            "./src/lobject.c",
            "./src/lopcodes.c",
            "./src/lparser.c",
            "./src/lstate.c",
            "./src/lstring.c",
            "./src/ltable.c",
            "./src/ltm.c",
            "./src/lundump.c",
            "./src/lvm.c",
            "./src/lzio.c",
            "./src/lauxlib.c",
            "./src/lbaselib.c",
            "./src/lcorolib.c",
            "./src/ldblib.c",
            "./src/liolib.c",
            "./src/lmathlib.c",
            "./src/loadlib.c",
            "./src/loslib.c",
            "./src/lstrlib.c",
            "./src/ltablib.c",
            "./src/lutf8lib.c",
            "./src/linit.c",
        },
    });
    lib.addIncludePath(b.path("src"));
    lib.linkLibC();
    b.installArtifact(lib);
}
