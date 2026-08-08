const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
const compile = lib.Engine.compile;

pub const Lib = [_]Lua.LuaLib{
    .{ "load", load },
};
fn load(lua: *Lua) c_int {
    if (lua.getTop() != 2) lua.fmtError("Expected 2 argument", .{});
    lua.check(1, .string);
    lua.check(2, .string);

    const name = lua.to(Lua.String, 1) catch unreachable;
    const text = lua.to(Lua.String, 2) catch unreachable;

    var arena = alloc: {
        const alloc = lua.getAlloc() orelse std.heap.c_allocator;
        break :alloc std.heap.ArenaAllocator.init(alloc);
    };
    defer arena.deinit();

    var r = std.Io.Reader.fixed(text);
    var allocating_writer = std.Io.Writer.Allocating.init(arena.allocator());

    //TODO: Handle errors
    compile(name, &r, &allocating_writer.writer) catch {};
    lua.loadString(allocating_writer.written()) catch {};
    lua.pcall(1, 0) catch {};

    return 0;
}
