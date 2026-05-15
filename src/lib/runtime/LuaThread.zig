const std = @import("std");
const lib = @import("../lib.zig");
const Io = std.Io;
const Lua = lib.Lua;
const Thread = @This();
context: ?*anyopaque,
ref: c_int,
lua: Lua,
const runtime_log = std.log.scoped(.runtime);
pub fn init(
    lua: *Lua,
    conetxt: ?*anyopaque,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) !Thread {
    const l = try lua.newThread();
    return .{
        .context = conetxt,
        .ref = lua.ref(),
        .lua = l,
        .start = start,
    };
}
pub fn run(t: *Thread, writer: Io.Writer, args: usize, res: usize) Lua.StateStatus {
    const lua = t.lua;
    return lua.resumeT(null, args, res) catch |e| {
        switch (e) {
            Lua.CallError.AllocationError => writer.writeAll("Unable to allocate more memory"),
            Lua.CallError.RuntimeError => {
                const err = lua.to(Lua.String, -1) catch @panic("Error was not a string, cannot print.");
                writer.writeAll(err);
            },
            else => unreachable,
        }
    };
}
pub fn deinit(t: *Thread) !Thread {
    t.lua.unref(t.ref);
}
