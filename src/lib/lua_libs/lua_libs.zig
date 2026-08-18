const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
const json = @import("json.zig");
const temp = @import("temp.zig");
const assert = std.debug.assert;

test {
    _ = @import("json.zig");
    _ = @import("temp.zig");
}

pub fn addLibs(lua: *Lua) void {
    assert(lua.getGlobal("rover") == .table);
    lua.newLib(&temp.Lib);
    lua.setField(-2, "template");

    lua.newLib(&json.Libs);
    lua.setField(-2, "json");
}
