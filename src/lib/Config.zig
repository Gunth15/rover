const std = @import("std");
const Io = std.Io;
const lib = @import("lib.zig");
const Lua = lib.Lua;
const cli = lib.Util.parser;

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

// ---- A single source of settings ------------------------------------------
pub const Partial = struct {
    address: ?std.Io.net.IpAddress = null,
    memory: ?usize = null,
    max_read: ?usize = null,
    main_file: ?[:0]const u8 = null,
    single_threaded: ?bool = null,
    lua_threads: ?usize = null,

    pub inline fn merge(base: Partial, over: Partial) Partial {
        var out = base;
        inline for (std.meta.fields(Partial)) |f| {
            if (@field(over, f.name)) |v| @field(out, f.name) = v;
        }
        return out;
    }

    pub inline fn fromArgs(args: cli.Args) Partial {
        return .{
            .address = args.addr,
            .memory = args.memory,
            .max_read = args.read,
            .main_file = args.file,
            .single_threaded = args.single_threaded,
            .lua_threads = args.lua_threads,
        };
    }

    pub inline fn fromLua(io: std.Io, alloc: std.mem.Allocator, file_path: [:0]const u8) Error!Partial {
        const f = Io.Dir.cwd().openFile(io, file_path, .{ .path_only = true }) catch return .{};
        f.close(io);

        var lua = Lua.init(.{ .allocator = &alloc }) catch return error.LuaError;
        defer lua.deinit();

        lua.doFile(file_path) catch {
            const msg = lua.to(Lua.String, -1) catch "unknown error";
            std.log.err("Error loading config file {s}: {s}", .{ file_path, msg });
            return error.LuaError;
        };

        var p: Partial = .{};

        if (try readGlobal(&lua, Lua.String, "ADDRESS", .string)) |s| {
            p.address = std.Io.net.IpAddress.parseLiteral(s) catch return error.InvalidAddress;
        }
        if (try readGlobal(&lua, Lua.Integer, "MEMORY", .number)) |n| {
            p.memory = std.math.cast(usize, n) orelse return error.OutOfRange;
        }
        if (try readGlobal(&lua, Lua.Integer, "MAX_READ", .number)) |n| {
            p.max_read = std.math.cast(usize, n) orelse return error.OutOfRange;
        }
        if (try readGlobal(&lua, Lua.String, "MAIN_FILE", .string)) |s| {
            // Copy out of Lua-owned memory before lua.deinit().
            p.main_file = try alloc.dupeZ(u8, s);
        }
        if (try readGlobal(&lua, Lua.Bool, "SINGLE_THREADED", .bool)) |b| {
            p.single_threaded = b;
        }
        if (try readGlobal(&lua, Lua.Integer, "LUA_THREADS", .number)) |n| {
            p.lua_threads = std.math.cast(usize, n) orelse return error.OutOfRange;
        }
        return p;
    }
};

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

inline fn defaults() Partial {
    return .{
        .address = std.Io.net.IpAddress.parse("127.0.0.1", 8080) catch unreachable,
        .memory = null,
        .max_read = 4096,
        .main_file = "main.lua",
        .single_threaded = false,
        .lua_threads = std.Thread.getCpuCount() catch 1,
    };
}

pub fn load(
    config_path: [:0]const u8,
    cli_partial: Partial,
) Error!Config {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const lua_partial = try Partial.fromLua(io, a, config_path);
    const merged = defaults().merge(lua_partial).merge(cli_partial);

    return .{
        .arena = arena,
        .address = merged.address.?,
        .memory = merged.memory,
        .max_read = merged.max_read.?,
        .main_file = try a.dupeZ(u8, merged.main_file.?),
        .single_threaded = merged.single_threaded.?,
        .lua_threads = if (merged.single_threaded.?) 1 else merged.lua_threads.?,
    };
}

pub fn deinit(config: *Config) void {
    config.arena.deinit();
}
