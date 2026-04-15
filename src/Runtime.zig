io: Io,
//connection entry point stream
server: std.net.Server = undefined,
lua: Lua,
//TODO: Connections no longer need to be pooled because they are reused
//same for the event and future used by the conncetion
connection_pool: ConnectionPool,
event_pool: EventPool,
future_pool: FuturePool,
slab: std.heap.FixedBufferAllocator,
conn_slab_size: usize,
max_req: usize,
max_resp: usize,
const std = @import("std");
const lib = @import("lib/lib.zig");
const Io = lib.Io;
const Lua = lib.Lua;
const Parser = lib.HttpParser;
const ConnectionContext = @import("ConnectionContext.zig");
const Future = @import("Future.zig");
const ConnectionPool = std.heap.MemoryPoolExtra(ConnectionContext, .{ .growable = false });
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });
const FuturePool = std.heap.MemoryPoolExtra(Future, .{ .growable = false });

const Runtime = @This();

pub fn addRoverIOLib(_: *Lua) void {}
const Dir = struct {
    handle: Io.Handle,
};

pub fn init(alloc: *const std.mem.Allocator, max_conns: usize, max_futures: usize, max_memory: usize, max_req_size: usize, max_resp_size: usize) !Runtime {
    return .{
        .io = try .init(.{ .entries = @min(max_futures, std.math.maxInt(u16)) }),
        .lua = try Lua.init(.{ .allocator = alloc }),
        .connection_pool = try .initPreheated(alloc.*, max_conns),
        .event_pool = try .initPreheated(alloc.*, max_futures + 2),
        .future_pool = try .initPreheated(alloc.*, max_futures + 1),
        .slab = std.heap.FixedBufferAllocator.init(try alloc.alloc(u8, max_memory)),
        .conn_slab_size = @divFloor(max_conns, max_memory),
        .max_req = max_req_size,
        .max_resp = max_resp_size,
    };
}
pub fn deinit(r: *Runtime) void {
    r.server.deinit();
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
            r.max_req,
            r.max_resp,
        );
        conn.rearm(&r.io, future, event, r.server.stream.handle);
    }
}

pub fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, ctxt: *anyopaque) void {
    const event: Io.Event = @ptrCast(ctxt);
    std.debug.print("Failed to setup a connection, {any}", .{event});
}
