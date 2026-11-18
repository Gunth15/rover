const std = @import("std");
const Io = std.Io;
const lib = @import("lib.zig");
const Lua = lib.Lua;

const Config = @This();

arena: std.heap.ArenaAllocator,
address: std.Io.net.IpAddress,
memory: ?usize,
max_read: usize,
main_file: [:0]const u8,
single_threaded: bool,
lua_threads: usize,

pub const Error = error{
    InvalidAddress,
    WrongType,
    OutOfRange,
    LuaError,
} || std.mem.Allocator.Error;

pub const default_path: [:0]const u8 = "config.lua";

/// Start from the built-in defaults. Call `applyFile` and then apply any
/// command-line overrides to resolve the final configuration.
pub fn init() Config {
    return .{
        .arena = .init(std.heap.page_allocator),
        .address = std.Io.net.IpAddress.parse("127.0.0.1", 8080) catch unreachable,
        .memory = null,
        .max_read = 4096,
        .main_file = "main.lua",
        .single_threaded = false,
        .lua_threads = std.Thread.getCpuCount() catch 1,
    };
}

pub fn deinit(config: *Config) void {
    config.arena.deinit();
}

/// Apply settings from a Lua config file over the current values.
/// A missing file leaves the configuration unchanged.
pub fn applyFile(config: *Config, file_path: [:0]const u8) Error!void {
    var threaded = std.Io.Threaded.init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const f = Io.Dir.cwd().openFile(io, file_path, .{ .path_only = true }) catch return;
    f.close(io);

    var alloc = config.arena.allocator();
    var lua = Lua.init(.{ .allocator = &alloc }) catch return error.LuaError;
    defer lua.deinit();

    lua.doFile(file_path) catch {
        const msg = lua.to(Lua.String, -1) catch "unknown error";
        std.log.err("Error loading config file {s}: {s}", .{ file_path, msg });
        return error.LuaError;
    };

    if (try readGlobal(&lua, Lua.String, "ADDRESS", .string)) |s| {
        config.address = std.Io.net.IpAddress.parseLiteral(s) catch return error.InvalidAddress;
    }
    if (try readGlobal(&lua, Lua.Integer, "MEMORY", .number)) |n| {
        config.memory = std.math.cast(usize, n) orelse return error.OutOfRange;
    }
    if (try readGlobal(&lua, Lua.Integer, "MAX_READ", .number)) |n| {
        config.max_read = std.math.cast(usize, n) orelse return error.OutOfRange;
    }
    if (try readGlobal(&lua, Lua.String, "MAIN_FILE", .string)) |s| {
        // Copy out of Lua-owned memory before lua.deinit().
        config.main_file = try config.arena.allocator().dupeSentinel(u8, s, 0);
    }
    if (try readGlobal(&lua, Lua.Bool, "SINGLE_THREADED", .bool)) |b| {
        config.single_threaded = b;
    }
    if (try readGlobal(&lua, Lua.Integer, "LUA_THREADS", .number)) |n| {
        config.lua_threads = std.math.cast(usize, n) orelse return error.OutOfRange;
    }
}

inline fn readGlobal(lua: *Lua, comptime T: type, name: [:0]const u8, expected: Lua.LuaType) Error!?T {
    const tag = lua.getGlobal(name);
    defer lua.pop(1);
    if (tag == .nil) return null;
    if (tag != expected) {
        std.log.err("Config value {s} has the wrong type", .{name});
        return error.WrongType;
    }
    return lua.to(T, -1) catch error.WrongType;
}

test "defaults are resolved without a config file" {
    var config = init();
    defer config.deinit();

    try std.testing.expectEqual(@as(?usize, null), config.memory);
    try std.testing.expectEqual(@as(usize, 4096), config.max_read);
    try std.testing.expectEqualStrings("main.lua", config.main_file);
    try std.testing.expect(!config.single_threaded);
}

test "missing config file leaves defaults intact" {
    var config = init();
    defer config.deinit();
    try config.applyFile("this-file-does-not-exist.lua");

    try std.testing.expectEqual(@as(usize, 4096), config.max_read);
    try std.testing.expectEqualStrings("main.lua", config.main_file);
}
