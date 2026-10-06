io: Io,
server: ?Io.net.Server = null,
lvm: LVM,
router: ?Router = null,
router_lock: Io.RwLock = .init,
allocator: std.mem.Allocator,
max_read: usize,
max_write: usize,
const std = @import("std");
const lib = @import("../lib.zig");
const route = lib.Router;
const Parser = lib.HttpParser;
const Io = std.Io;
const Lua = lib.Lua;
const LVM = lib.LVM;
const Router = route.Router(c_int, .{ .lua = true });
const RequestQueue = Io.Queue(struct { writer: Io.Writer, req: Parser.Request });
const Connection = lib.Connnection;
const runtime_log = std.log.scoped(.runtime);
const ctrlC = lib.Util.ctrlC;
const testing = @import("testing/testing.zig");

pub const Thread = lib.LVM.Coroutine;
pub const Logger = lib.Logger;
const Runtime = @This();
const LibRover = @embedFile("../librover.lua");

pub fn init(alloc: std.mem.Allocator, io: Io, max_read: usize, max_write: usize) !Runtime {
    return Runtime{
        .io = io,
        .lvm = try .init(alloc, .{}),
        .allocator = alloc,
        .max_read = max_read,
        .max_write = max_write,
    };
}
pub fn deinit(r: *Runtime) void {
    if (r.server) |*server| server.deinit(r.io);
    if (r.router) |*router| router.deinit();
    r.lvm.deinit(r.io);
}
pub fn initVms(r: *Runtime, file: [:0]const u8) !void {
    const StartupData = struct {
        file: [:0]const u8,
        runtime: *Runtime,
        router_created: std.atomic.Value(bool) = .init(false),
        fn startfn(lua: *Lua, start_data: ?*anyopaque) void {
            const data: *@This() = @ptrCast(@alignCast(start_data));

            openLibsOnVms(lua, data.runtime);
            loadMainOnVms(lua, data.file);

            if (data.router_created.swap(true, .acq_rel))
                createRefs(lua)
            else {
                buildRouter(lua, data.runtime);
            }

            runLoadFunc(lua);
            findOrSetOnError(lua);
            findOrSetOnInvalidMethod(lua);
            findOrSetOnNotFound(lua);
        }
    };

    const data = try r.lvm.allocator.create(StartupData);
    data.* = .{
        .file = file,
        .runtime = r,
    };
    defer r.lvm.allocator.destroy(data);

    try r.lvm.start(r.io, StartupData.startfn, @ptrCast(data));
}

pub fn serve(r: *Runtime, addr: Io.net.IpAddress) !void {
    const io: Io = r.io;
    r.server = try addr.listen(io, .{ .reuse_address = true });
    var server = r.server.?;

    var group: Io.Group = .init;
    errdefer group.cancel(io);

    while (!ctrlC.isPressed()) {
        const stream = try server.accept(io);
        try group.concurrent(io, Connection.drain, .{ r, stream });
    }
    try group.await(io);
}

pub fn openLibRover(r: *Runtime, lua: *Lua) void {
    lua.push(r);
    lua.setField(Lua.RegistryIndex, "rover_runtime");

    lua.newTable();
    lua.setGlobal("rover");
    lua.loadString(LibRover) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("{s}", .{err}, 1);
    };
    lua.pcall(0, 0) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Error during initialization: {s}", .{err}, 1);
    };

    std.debug.assert(lua.getGlobal("require") == .func);
    lua.push("rover");

    lua.pcall(1, 1) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Failed requiring rover: {s}", .{err}, 1);
    };

    lib.LuaLibs.addLibs(lua);
}

pub fn runTestMode(r: *Runtime, test_dir_path: []const u8) !void {
    try testing.runTestMode(r, test_dir_path);
}
fn runLoadFunc(lua: *Lua) void {
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    switch (lua.getField(-1, "load")) {
        .func => {
            lua.pcall(0, 0) catch {
                const err = lua.to(Lua.String, -1) catch unreachable;
                fatal("Unexpected error from rover.load: {s}", .{err}, 1);
            };
        },
        //Does not exist(this is ok)
        .nil => {},
        else => fatal("rover.load was not a function", .{}, 1),
    }
}
fn findOrSetOnInvalidMethod(lua: *Lua) void {
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    switch (lua.getField(-1, "on_invalid_method")) {
        .func => return,
        //Does not exist(this is ok)
        .nil => {
            lua.doString(
                \\return function(conn)
                \\return conn:send_bytes(405,"Method Not Allowed")
                \\end
            ) catch {
                const err = lua.to(Lua.String, -1) catch unreachable;
                fatal("Unexpected error from rover.on_invalid_method: {s}", .{err}, 1);
            };
            lua.setField(-3, "on_invalid_method");
        },
        else => fatal("rover.on_invalid_method was not a function", .{}, 1),
    }
}
fn findOrSetOnNotFound(lua: *Lua) void {
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    switch (lua.getField(-1, "on_not_found")) {
        .func => return,
        //Does not exist(this is ok)
        .nil => {
            lua.doString(
                \\return function(conn)
                \\return conn:send_bytes(404,"Page Not Found")
                \\end
            ) catch {
                const err = lua.to(Lua.String, -1) catch unreachable;
                fatal("Unexpected error from rover.on_not_found: {s}", .{err}, 1);
            };
            lua.setField(-3, "on_not_found");
        },
        else => fatal("rover.on_not_found was not a function", .{}, 1),
    }
}
fn findOrSetOnError(lua: *Lua) void {
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    switch (lua.getField(-1, "on_error")) {
        .func => return,
        //Does not exist(this is ok)
        .nil => {
            lua.doString(
                \\return function(err)
                \\print(err)
                \\return {
                \\  status = 500,
                \\  headers = {
                \\      ["Content-Length"] = 21,
                \\  },
                \\  body = "Internal Server Error",
                \\}
                \\end
            ) catch {
                const err = lua.to(Lua.String, -1) catch unreachable;
                fatal("Unexpected error from rover.on_not_found: {s}", .{err}, 1);
            };
            lua.setField(-3, "on_error");
        },
        else => fatal("rover.on_error was not a function", .{}, 1),
    }
}

fn createRefs(lua: *Lua) void {
    //find rover.routes()
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    if (lua.getField(-1, "routes") != .func) @panic("rover.routes is not a function");
    lua.pcall(0, 1) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Unrecoverable state reached: {s}", .{err}, 1);
    };
    switch (lua.Luatype(-1)) {
        .table => {},
        else => |ltype| fatal("Expected routing table from rover.routes but receieved {s}", .{@tagName(ltype)}, 1),
    }
    //save index
    const routing_table_idx = lua.getAbs(-1);

    var idx: isize = 1;
    while (lua.getI(routing_table_idx, idx) == .table) : (idx += 1) {
        //expected format {"/path", METHOD = func}
        const route_idx = lua.getAbs(-1);
        _ = switch (lua.getI(route_idx, 1)) {
            .string => lua.to(Lua.String, -1),
            else => |ltype| fatal("First index expected to be a string but receieved a {s}", .{@tagName(ltype)}, 1),
        } catch unreachable;

        const accepted_methods: [5][]const u8 = .{ "GET", "POST", "PUT", "PATCH", "DELETE" };
        for (accepted_methods) |method| {
            switch (lua.getField(route_idx, method)) {
                .func => _ = lua.ref(),
                .nil => continue,
                else => |ltype| fatal("{s} expected lua function, but receieved {s}\n", .{ method, @tagName(ltype) }, 1),
            }
        }
    }
    switch (lua.getI(routing_table_idx, idx)) {
        .nil => {},
        else => |ltype| fatal("Inavlid table entry at index {d}, expected a table containing a route and methods, but receieved {s}", .{ idx, @tagName(ltype) }, 1),
    }
}
fn buildRouter(lua: *Lua, r: *Runtime) void {
    //find rover.routes()
    if (lua.getGlobal("rover") != .table) @panic("rover could not be found");
    if (lua.getField(-1, "routes") != .func) @panic("rover.routes is not a function");
    lua.pcall(0, 1) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Unrecoverable state reached: {s}", .{err}, 1);
    };
    switch (lua.Luatype(-1)) {
        .table => {},
        else => |ltype| fatal("Expected routing table from rover.routes but receieved {s}", .{@tagName(ltype)}, 1),
    }
    //save index
    const routing_table_idx = lua.getAbs(-1);

    //create routing table
    r.router = Router.init(
        r.allocator,
        false,
        null,
        null,
    ) catch fatal("Fatal Error, Could not create router, out of memory", .{}, 1);
    const router = &r.router.?;
    var idx: isize = 1;
    while (lua.getI(routing_table_idx, idx) == .table) : (idx += 1) {
        //expected format {"/path", METHOD = func}
        const route_idx = lua.getAbs(-1);
        const path = switch (lua.getI(route_idx, 1)) {
            .string => lua.to(Lua.String, -1),
            else => |ltype| fatal("First index expected to be a string but receieved a {s}", .{@tagName(ltype)}, 1),
        } catch unreachable;

        const accepted_methods: [5][]const u8 = .{ "GET", "POST", "PUT", "PATCH", "DELETE" };
        for (accepted_methods) |method| {
            switch (lua.getField(route_idx, method)) {
                .func => {
                    const ref = lua.ref();
                    router.regiser(method, path, ref) catch |e| {
                        switch (e) {
                            route.RegistrationError.CatchAllIsNotTerminal => fatal("Improper catch-all route {s}, catch-all must be at preceeded by \'\\\'", .{path}, 1),
                            route.RegistrationError.AlreadyExist => fatal("{s} already exist", .{path}, 1),
                            route.RegistrationError.MultipleWilCardsPerSegment => fatal("{s} has multiple wilcards in one segment", .{path}, 1),
                            route.RegistrationError.CatchAllConflict => fatal("{s} catch-all conflicts with existing routes", .{path}, 1),
                            route.RegistrationError.OutOfMemory => fatal("Out of memory", .{}, 1),
                            route.RegistrationError.UnamedWildCard => fatal("Wildcards are required to be named. {s} is not", .{path}, 1),
                            route.RegistrationError.WildCardChildNotAllowed => fatal("{s} is a child of an existing wilcard, which is not allowed", .{path}, 1),
                            route.RegistrationError.WildCardConflict => fatal("Wildcard in {s} conflicts with existing path(s)", .{path}, 1),
                            route.RegistrationError.InvalidMethod => fatal("Impossible error, method not suppported", .{}, 1),
                        }
                    };
                },
                .nil => continue,
                else => |ltype| fatal("{s} expected lua function, but receieved {s}\n", .{ method, @tagName(ltype) }, 1),
            }
        }
    }
    switch (lua.getI(routing_table_idx, idx)) {
        .nil => {},
        else => |ltype| fatal("Inavlid table entry at index {d}, expected a table containing a route and methods, but receieved {s}", .{ idx, @tagName(ltype) }, 1),
    }
}
fn openLibsOnVms(lua: *Lua, runtime: *Runtime) void {
    lua.openLibs();
    runtime.openLibRover(lua);
}
fn loadMainOnVms(lua: *Lua, file: [:0]const u8) void {
    std.debug.assert(lua.getGlobal("rover") == .table);
    //load main file(allow user to define path to file)
    lua.loadFile(file) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("{s}", .{err}, 1);
    };
    lua.pcall(0, 0) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Error during initialization: {s}", .{err}, 1);
    };
}

inline fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    runtime_log.err(fmt, args);
    std.process.exit(status);
}
