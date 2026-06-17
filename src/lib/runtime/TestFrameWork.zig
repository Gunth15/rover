core: ?*Worker,
bench: ?*Worker,
fuzz: ?*Worker,

const std = @import("std");
const lib = @import("../lib.zig");
const Runtime = lib.Runtime;
const Lua = lib.Lua;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Libs = [_]Lua.LuaLib{
    .{ "run", run },
    .{ "bench", bench },
    .{ "fuzz", fuzz },
};
const Worker = struct {
    state: Lua,
    next: ?*Worker,
    input_types: std.ArrayList(Lua.LuaType),
};

pub fn initFrameWork(l: *Lua) void {}
