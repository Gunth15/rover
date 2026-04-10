io: Io,
//connection entry point stream
stream: std.net.Stream,
lua: Lua,
connection_pool: ConnectionPool,
event_pool: EventPool,
future_pool: FuturePool,
memstack: MemStack,
read_size: usize,
max_req: usize,
const std = @import("std");
const lib = @import("lib/lib.zig");
const Io = lib.Io;
const Lua = lib.Lua;
const Parser = lib.HttpParser;
const ConnectionContext = @import("ConnectionContext.zig");
const MemStack = lib.MemStack;
const Future = @import("Future.zig");
const ConnectionPool = std.heap.MemoryPoolExtra(ConnectionContext, .{ .growable = false });
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });
const FuturePool = std.heap.MemoryPoolExtra(Future, .{ .growable = false });

const Runtime = @This();

pub fn addRoverIOLib(_: *Lua) void {}
const Dir = struct {
    handle: Io.Handle,
};

pub fn init(alloc: *std.mem.Allocator, addr: std.net.Address, max_conns: usize, max_futures: usize, max_memory: usize, req_read_size: usize, max_req_size: usize) !Runtime {
    return .{
        .stream = try addr.listen(),
        .io = .init(.{ .entries = @min(max_futures, std.math.maxInt(u16)) }),
        .lua = try Lua.init(.{ .allocator = alloc }),
        .connection_pool = .initPreheated(alloc.*, max_conns),
        .event_pool = .initPreheated(alloc.*, max_futures + 1),
        .future_pool = .initPreheated(alloc.*, max_futures + 1),
        .memstack = .init(alloc.*, max_memory, @divFloor(max_memory, max_conns)),
        .max_req_size = max_req_size,
        .req_read_size = req_read_size,
    };
}
pub fn deinit(r: *Runtime, alloc: std.mem.Allocator) void {
    r.stream.close();
    r.io.deinit();
    r.lua.deinit();
    r.memstack.deinit(alloc);
    r.connection_pool.deinit();
    r.event_pool.deinit();
    alloc.free(r.temp);
}

pub fn setupConnection(f: *Future, r: *Runtime, _: *ConnectionContext) void {
    const event = r.event_pool.create() catch {};
    event.* = .accept(&f, r.stream.handle);
    f.ctxt = event;
    r.io.submit(event) catch {};
}

pub fn acceptConnections(r: *Runtime, fut: *Future, event: *Io.Event) void {
    const cb = struct {
        fn wake(_: *Future, _: *Runtime, _: *ConnectionContext, _: *anyopaque) Future.State {
            std.debug.assert(event.status.complete == .accept);

            const handle = event.status.complete.accept.ret catch return .failed;

            const conn = r.connection_pool.create() catch return .failed;
            const thread = r.lua.newThread() catch return .failed;

            conn.* = ConnectionContext.init(handle, thread, r.memstack.acquire(), 4096, 1024) catch return .failed;

            //make this a function
            const future = r.future_pool.create() catch return .failed;
            const ev = r.event_pool.create() catch return .failed;

            conn.readAndStart(r.io, future, ev);
            //NOTE: never finishes as ong as server is running
            return .waiting;
        }
        fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, _: *anyopaque) void {
            return;
        }
    };
    event.* = .accept(fut, r.stream.handle);
    fut.* = .{
        //NOTE: conn is never utilized for accepting new connections
        .conn = @ptrFromInt(0),
        .ctxt = event,
        .vtable = .{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    r.io.submit(event) catch {};
}
pub fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, ctxt: *anyopaque) void {
    const event: Io.Event = @ptrCast(ctxt);
    std.debug.print("Failed to setup a connection, {any}", .{event});
}
