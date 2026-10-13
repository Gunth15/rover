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

pub const Libs = [_]Lua.LuaLib{
    .{ "log", log },
};
pub fn addLibs(lua: *Lua) void {
    assert(lua.getGlobal("rover") == .table);
    lua.newLib(&temp.Lib);
    lua.setField(-2, "template");

    lua.newLib(&json.Libs);
    lua.setField(-2, "json");

    lua.newLib(&Libs);
    lua.setField(-2, "logger");
}

pub fn log(lua: *Lua) c_int {
    var buff: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buff);
    const nargs = lua.getTop();
    if (nargs > 2) lua.fmtError("Expected 2 arguments", .{});

    const desc = lua.to(Lua.String, 1) catch return 0;
    writer.writeAll(desc) catch lua.fmtError("string too long(must be less than 4096)", .{});
    if (nargs == 2) {
        lua.check(2, .table);
        lua.insert(2);
        lua.push(null);

        while (lua.Next(2) != .nil) {
            const key = lua.to(Lua.String, -2) catch return 0;
            const value = lua.to(Lua.String, -1) catch return 0;

            writer.print("{s}={s}", .{ key, value }) catch lua.fmtError("string too long(must be less than 4096)", .{});
            lua.pop(1);
        }
    }

    //TODO: handle level
    lib.Logger.Instance.log(.DEBUG, writer.buffered(), .{});
    return 0;
}
