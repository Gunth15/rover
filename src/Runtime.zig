io: Io,
//connection entry point stream
stream: std.net.Stream,
lua: Lua,
connection_pool: ConnectionPool,
event_pool: EventPool,
future_pool: FuturePool,
memstack: MemStack,
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

//NOTE: IO is close to the runtime, so all Io related operations are here
pub fn addRoverIOLib(_: *Lua) void {}
const Dir = struct {
    handle: Io.Handle,
};
const File = struct {
    handle: Io.Handle,
    buff: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    fn wake(f: *Future, runtime: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) bool {}
    fn cancel(f: *Future, runtime: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) void {}
};

pub fn init(alloc: *std.mem.Allocator, addr: std.net.Address, max_conns: usize, max_futures: usize, max_memory: usize) !Runtime {
    return .{
        .stream = try addr.listen(),
        .io = .init(.{ .entries = @min(max_futures, std.math.maxInt(u16)) }),
        .lua = try Lua.init(.{ .allocator = alloc }),
        .connection_pool = .initPreheated(alloc.*, max_conns),
        .event_pool = .initPreheated(alloc.*, max_futures + 1),
        .future_pool = .initPreheated(alloc.*, max_futures + 1),
        .memstack = .init(alloc.*, max_memory, @divFloor(max_memory, max_conns)),
    };
}
pub fn deinit(r: *Runtime, alloc: std.mem.Allocator) void {
    r.stream.close();
    r.io.deinit();
    r.lua.deinit();
    r.memstack.deinit(alloc);
    r.connection_pool.deinit();
    r.event_pool.deinit();
}

pub fn setupConnection(f: *Future, r: *Runtime, _: *ConnectionContext) void {
    const event = r.event_pool.create() catch {};
    event.* = .accept(&f, r.stream.handle);
    f.ctxt = event;
    r.io.submit(event) catch {};
}
pub fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) Future.State {
    const event: *Io.Event = @ptrCast(ctxt);

    switch (event.status.complete) {
        //Create a conncetion
        .accept => |ret| {
            const handle = ret catch return .failed;

            const new_conn = r.connection_pool.create() catch return .failed;
            const thread = r.lua.newThread() catch return .failed;

            new_conn.* = .init(handle, thread, r.memstack.acquire());
            //NOTE: take read_size and max buf size as args
            new_conn.buf = .initCapacity(new_conn.slab.allocator(), 1024);

            //make this a function
            const future = r.future_pool.create() catch return .failed;
            const conn_event = r.event_pool.create() catch return .failed;
            conn_event.* = .read(future, new_conn.handle, new_conn.buf.allocatedSlice(), 0);
            future.* = .{ .conn = new_conn, .ctxt = conn_event, .vtable = .{
                .wake = wake,
                .cancel = cancel,
            } };

            r.io.submit(conn_event) catch {};
            return .finished;
        },
        //Read connection
        .read => |ret| {
            const read = ret catch return .failed;
            const buf = conn.buf;
            const total_read = buf.items.len + read;

            //Should never grow list
            std.debug.assert(buf.capacity <= total_read);
            buf.resize(conn.slab, total_read);
            const req = Parser.parse(buf.items, conn.slab, 64, total_read - read) catch |e| {
                switch (e) {
                    error.PartialRequest => {
                        buf.resize(conn.slab, buf.items.len + 1024);
                        event.* = .read(f, conn.handle, buf.allocatedSlice()[buf.items.len..], 0);
                        r.io.submit(event) catch {};
                        return .waiting;
                    },
                    else => return .failed,
                }
            };
            //TODO: if connection is keep-alive, read agin until timeout or close is sent by user
            conn.startNewRequests(r, read);
            return .finished;
        },
        //Write to connection
        .send => {},
        //Close and deinitialize connection
        .close => {
            c.deinit(r);
            r.connection_pool.destroy(c);
            r.event_pool.destroy(event);
        },
        else => unreachable,
    }
    return true;
}
pub fn cancel(f: *Future, _: *Runtime, _: *ConnectionContext, ctxt: *anyopaque) void {
    const err: Io.Event = @ptrCast(ctxt);
    std.debug.print("Failed to setup a connection, {any}", .{err});
}
