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
pub fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) Future.State {
    const event: *Io.Event = @ptrCast(ctxt);

    switch (event.status.complete) {
        //Create a conncetion
        .accept => |ret| {
            const handle = ret catch return .failed;

            const new_conn = r.connection_pool.create() catch return .failed;
            const thread = r.lua.newThread() catch return .failed;

            new_conn.* = ConnectionContext.init(handle, thread, r.memstack.acquire(), 4096, 1024) catch return .failed;

            //make this a function
            const future = r.future_pool.create() catch return .failed;
            const ev = r.event_pool.create() catch return .failed;

            const read_event = conn.read(future, ev);

            r.io.submit(read_event) catch {};
            return .finished;
        },
        //Read connection
        .read => |ret| {
            const read = ret catch return .failed;
            //TODO: handle zero bytes read
            const reader = conn.reader;
            reader.advance(read);

            const prev_bytes_read = conn.req_bytes_read;

            //TODO: make an assert, so reader cannot be larger than this
            const temp: [4096 * 4]u8 = undefined;

            const slice = reader.peek();
            //OPTIMIZE: I hope to replace this with a stateful http parser to remove the need
            //for a temporary buffer
            const buf_size = slice.first.len + slice.second.len;
            @memcpy(temp[0..slice.first.len], slice.first);
            @memcpy(temp[slice.first.len..buf_size], slice.second);
            const parsable = temp[0..buf_size];

            conn.total_bytes_read += read;
            conn.req_bytes_read += read;
            const req = Parser.parse(parsable, conn.slab, 64, prev_bytes_read) catch |e| {
                switch (e) {
                    error.PartialRequest => {
                        //TODO: if req_bytes_read == max_req_bytes or wrote != read, write log error and return 403, set read_bytes back to 0
                        conn.read(r.io, f, event);
                        return .waiting;
                    },
                    else => return .failed,
                }
            };

            reader.advanceHead(req.size);
            conn.req_bytes_read -= req.size;

            //TODO: if connection is keep-alive, read again until timeout or close is sent by user
            //SEND ANOTHER READ

            conn.startNewThread(r, req);
            conn.stopThread();
        },
        //Write to connection
        .writev => |ret| {
            const written = ret catch return .failed;
            const writer = conn.writer;
            writer.consume(written);

            if (writer.pending()) {
                conn.write(r.io, f, event);
                return .waiting;
            }

            return .finished;
        },
        //Close and deinitialize connection
        .close => {
            conn.deinit();
            r.event_pool.destroy(event);
            r.FuturePool.destroy(f);
            r.connection_pool.destroy(conn);
        },
        else => unreachable,
    }
    return .finished;
}
pub fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, ctxt: *anyopaque) void {
    const event: Io.Event = @ptrCast(ctxt);
    std.debug.print("Failed to setup a connection, {any}", .{event});
}
