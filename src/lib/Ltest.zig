const std = @import("std");
const zio = @import("zio");
const lib = @import("lib.zig");
const Lua = lib.Lua;
const Runtime = lib.Runtime;
const testing = std.testing;

runtime: Runtime,
zio_rt: *zio.Runtime,

const Ltest = @This();
pub fn init() !Ltest {
    const rt = try zio.Runtime.init(testing.allocator, .{
        .thread_pool = .{
            .max_threads = 1,
        },
    });
    return .{
        .runtime = try .init(&testing.allocator, rt.io(), 4096, 4096),
        .zio_rt = rt,
    };
}
pub fn deinit(l: *Ltest) void {
    l.runtime.deinit();
    l.zio_rt.deinit();
}

pub fn testFunc(l: *Ltest, fname: [:0]const u8, comptime func: *const fn (*Lua) c_int, args: anytype) !void {
    var lua = l.runtime.lua;
    lua.register(fname, func);
    _ = lua.getGlobal(fname);
    const names = comptime std.meta.fieldNames(@TypeOf(args));
    inline for (names) |name| {
        const value = @field(args, name);
        lua.push(value);
    }
    lua.pcall(names.len, lib.Lua.MULTIRET) catch |e| {
        const err = lua.catchError();
        std.debug.print("\nLUA ERROR: {s}\n", .{err});
        return e;
    };
}
pub fn expectString(l: *Ltest, expected: []const u8) !void {
    var lua = l.runtime.lua;
    const actual = try lua.to(Lua.String, -1);
    try testing.expectEqualStrings(expected, actual);
}
pub fn expectNumber(l: *Ltest, expected: f64) !void {
    var lua = &l.runtime.lua;
    const actual = try lua.to(Lua.Number, -1);
    try testing.expectEqual(expected, actual);
}
pub fn expect(l: *Ltest) !void {
    var lua = &l.runtime.lua;
    const ok = try lua.to(Lua.Bool, -1);
    try testing.expect(ok);
}
pub fn expectTable(l: *Ltest, expected: anytype) !void {
    var lua = &l.runtime.lua;
    const T = @TypeOf(expected);
    const fields = std.meta.fields(T);

    if (lua.Luatype(-1) != .table) {
        std.debug.print("expectTable: top of stack is {s}, not a table\n", .{@tagName(lua.Luatype(-1))});
        return error.NotATable;
    }
    inline for (fields) |field| {
        const expected_value = @field(expected, field.name);
        const FieldType = @TypeOf(expected_value);

        _ = lua.getField(-1, field.name);

        switch (@typeInfo(FieldType)) {
            .pointer => |info| {
                if (info.size == .slice and info.child == u8) {
                    const actual = try lua.to(Lua.String, -1);
                    try testing.expectEqualStrings(expected_value, actual);
                } else {
                    const actual = try lua.to(FieldType, -1);
                    try testing.expectEqual(expected_value, actual);
                }
            },
            .float, .comptime_float => {
                const actual = try lua.to(Lua.Number, -1);
                try testing.expectEqual(@as(f64, expected_value), actual);
            },
            .int, .comptime_int => {
                const actual = try lua.to(Lua.Integer, -1);
                try testing.expectEqual(@as(Lua.Integer, @intCast(expected_value)), actual);
            },
            .bool => {
                const actual = try lua.to(Lua.Bool, -1);
                try testing.expectEqual(expected_value, actual);
            },
            .@"struct" => {
                try l.expectTable(expected_value);
            },
            else => @compileError("expectTable: unsupported field type " ++ @typeName(FieldType)),
        }
        lua.pop(1);
    }
}
