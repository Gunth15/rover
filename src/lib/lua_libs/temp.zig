const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
const compile = lib.Engine.compile;

pub const Lib = [_]Lua.LuaLib{
    .{ "load", load },
};
fn load(lua: *Lua) c_int {
    if (lua.getTop() != 1) lua.fmtError("Expected 1 argument", .{});
    lua.check(1, .string);

    const text = lua.to(Lua.String, 1) catch unreachable;

    var arena = alloc: {
        const alloc = lua.getAlloc() orelse std.heap.c_allocator;
        break :alloc std.heap.ArenaAllocator.init(alloc);
    };
    defer arena.deinit();
    var alloc = arena.allocator();

    var r = std.Io.Reader.fixed(text);
    var allocating_writer = std.Io.Writer.Allocating.init(alloc);

    //TODO: Handle errors
    compile(&r, &allocating_writer.writer) catch {};
    const strz = alloc.dupeZ(u8, allocating_writer.written()) catch lua.fmtError("Out out of memory", .{});
    lua.loadString(strz) catch {};
    lua.pcall(0, 1) catch {};

    return 1;
}
