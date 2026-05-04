io: Io,
//connection entry point stream
server: std.net.Server = undefined,
lua: Lua,
router: Router,
//TODO: Connections no longer need to be pooled because they are reused
//same for the event and future used by the conncetion
connection_pool: ConnectionPool,
event_pool: EventPool,
future_pool: FuturePool,
slab: std.heap.FixedBufferAllocator,
conn_slab_size: usize,
max_read: usize,
max_write: usize,
const std = @import("std");
const lib = @import("lib/lib.zig");
const route = lib.Router;
const Parser = lib.HttpParser;
const Io = lib.Io;
const Lua = lib.Lua;
const Router = route.Router(Lua.Function);
const ConnectionContext = @import("ConnectionContext.zig");
const Future = @import("Future.zig");
const ConnectionPool = std.heap.MemoryPoolExtra(ConnectionContext, .{ .growable = false });
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });
const FuturePool = std.heap.MemoryPoolExtra(Future, .{ .growable = false });
const runtime_log = @import("std").log.scoped(.runtime);

const Runtime = @This();

pub fn addRoverIOLib(_: *Lua) void {}
const Dir = struct {
    handle: Io.Handle,
};

pub fn init(alloc: *const std.mem.Allocator, max_conns: usize, max_futures: usize, max_memory_per_connection: usize, max_read: usize, max_write: usize) !Runtime {
    const add = std.math.add;
    const mul = std.math.mul;
    const mem_per_conn = try add(usize, max_memory_per_connection, try add(usize, max_write, max_read));
    const max_memory = try mul(usize, max_conns, mem_per_conn);
    const io = try std.math.ceilPowerOfTwo(usize, max_futures);
    return .{
        .io = try .init(.{ .entries = @min(io, std.math.maxInt(u16)) }),
        .lua = try Lua.init(.{ .allocator = alloc }),
        .router = undefined,
        .connection_pool = try .initPreheated(alloc.*, max_conns),
        .event_pool = try .initPreheated(alloc.*, io + 1),
        .future_pool = try .initPreheated(alloc.*, io + 1),
        .slab = std.heap.FixedBufferAllocator.init(try alloc.alloc(u8, max_memory)),
        .conn_slab_size = mem_per_conn,
        .max_read = max_read,
        .max_write = max_write,
    };
}
pub fn deinit(r: *Runtime) void {
    r.server.deinit();
    r.router.deinit();
    r.io.deinit();
    r.lua.deinit();
    r.slab.reset();
    r.connection_pool.deinit();
    r.event_pool.deinit();
}

pub fn serve(r: *Runtime, addr: std.net.Address, connections: usize) !void {
    const alloc = r.slab.allocator();
    r.server = try addr.listen(.{});
    for (0..connections) |_| {
        const conn: *ConnectionContext = try r.connection_pool.create();
        const event = try r.event_pool.create();
        const future = try r.future_pool.create();
        conn.* = try .init(
            alloc,
            r.conn_slab_size,
            r.max_read,
            r.max_write,
        );
        conn.rearm(&r.io, future, event, r.server.stream.handle);
    }
}

pub fn loadMain(r: *Runtime, file: [:0]const u8) void {
    const lua = &r.lua;
    //load main file(allow user to define path to file)
    lua.newTable();
    lua.setGlobal("rover");
    lua.loadFile(file) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Error loading file: {s}", .{err}, 1);
    };
    lua.pcall(0, 0) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Error during initialization: {s}", .{err}, 1);
    };
}

pub fn buildRouter(r: *Runtime, alloc: std.mem.Allocator) void {
    const lua = &r.lua;

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
        alloc,
        false,
        null,
        null,
    ) catch fatal("Fatal Error, Could not create router, out of memory", .{}, 1);
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
                    const function = lua.to(Lua.Function, -1) catch unreachable;
                    r.router.regiser(method, path, function) catch |e| {
                        switch (e) {
                            route.RegistrationError.CatchAllIsNotTerminal => fatal("Improper catch-all route {s}, catch-all must be at preceeded by \'\\\'", .{path}, 1),
                            route.RegistrationError.AlreadyExist => fatal("{s} already exist", .{path}, 1),
                            route.RegistrationError.MultipleWilCardsPerSegment => fatal("{s} has multiple wilcards in one segment", .{path}, 1),
                            route.RegistrationError.CatchAllConflict => fatal("{s} catch-all conflicts with existing routes", .{path}, 1),
                            route.RegistrationError.OutOfMemory => fatal("Out of memory", .{}, 1),
                            route.RegistrationError.UnamedWildCard => fatal("Wildcards are required to be named. {s} is not", .{path}, 1),
                            route.RegistrationError.WildCardChildNotAllowed => fatal("{s} contains a wildcard and conflicts with existing paths", .{path}, 1),
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
pub fn runLoadFunc(r: *Runtime) void {
    var lua = r.lua;

    std.debug.assert(lua.getGlobal("rover") != .table);
    if (lua.getField(-1, "load") != .func) fatal("rover.load was not a function", .{}, 1);
    lua.pcall(0, 0) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        fatal("Unexpected error from rover.load: {s}", .{err}, 1);
    };
}

pub fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, ctxt: *anyopaque) void {
    const event: Io.Event = @ptrCast(ctxt);
    std.debug.print("Failed to setup a connection, {any}", .{event});
}

inline fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    runtime_log.err(fmt, args);
    std.process.exit(status);
}
