addr: std.net.Address = undefined,
handle: Io.Handle,
reader: lib.Reader,
writer: lib.Writer,
threads: lib.Queue(Thread),
slab: std.heap.FixedBufferAllocator,
rvec: [2]Io.Vec,
wvec: [2]Io.Vec,
allocation_fail_count: usize = 0,
req_bytes_read: usize = 0,
total_bytes_read: usize = 0,

const ConnectionContext = @This();
const Runtime = @import("Runtime.zig");
const std = @import("std");
const lib = @import("lib/lib.zig");
const Future = @import("Future.zig");
const Io = lib.Io;
const Lua = lib.Lua;
const Parser = lib.HttpParser;
const EventQueue = lib.Queue(Io.Event);
const HttpParser = lib.HttpParser;

const Thread = struct {
    ref: c_int,
    lthread: Lua,
    //if you run out of memory before finishing a request, try to complete toher request first
    //if all of them require more memory than available, it's time to kill the conection
    arena: std.heap.ArenaAllocator,
    next: ?Thread,
};

pub inline fn init(handle: Io.Handle, slab: std.heap.FixedBufferAllocator, reader_size: usize, buf_size: usize) !ConnectionContext {
    return .{
        .handle = handle,
        .slab = slab,
        .threads = .{},
        .reader = .init(slab, reader_size),
        .allocation_fail_count = 0,
    };
}
pub inline fn deinit(conn: *ConnectionContext) void {
    //return resources used back to runtime
    conn.slab.reset();
    conn.memstack.returnBuf(conn.slab);
}
pub fn start(conn: *ConnectionContext, lua: *Lua, req: HttpParser.Request) !void {
    var l = lua;
    const lthread = try l.newThread();
    const ref = l.ref();
    const thread: Thread = .{
        .arena = std.heap.ArenaAllocator.init(conn.slab.allocator()),
        .ref = ref,
        .lthread = lthread,
    };

    //TODO: Handle chunck encoding/streamed bodies of request
    //and allow seting max header size

    //get the relavant handler from the routing table and run the handler
    //pass the connection as a argument to the lua function
    //expect to yield unless connection finishes in one go
    conn.Thread.append(conn.slab, thread);
}
pub fn stop(conn: *ConnectionContext, lua: *Lua) void {
    //OPTIMIZE: Instead of getting a raw buffer from lua, return status, headers, and body
    const thread = conn.threads.dequeue().?;
    defer {
        thread.arena.deinit();
        lua.unref(thread.ref);
    }

    const str = thread.lthread.to(Lua.String, 0) catch @panic("Return value is not a string");
    const wrote = conn.writer.fill(str);
    if (wrote != str.len) @panic("Full return string not written, TODO: handle this case");
}

///future and evet must outlive function
///Starts handling request if it receieves a full HTTP Request
pub fn readAndStart(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const Readcb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, _: *anyopaque) Future.State {
            std.debug.assert(event.status.complete == .read);

            const read_bytes = event.status.complete.read catch return .failed;

            //TODO: handle zero bytes read
            const reader = conn.reader;
            reader.advance(read_bytes);

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

            conn.total_bytes_read += read_bytes;
            conn.req_bytes_read += read_bytes;
            const req = Parser.parse(parsable, conn.slab, 64, prev_bytes_read) catch |e| {
                switch (e) {
                    error.PartialRequest => {
                        //TODO: if req_bytes_read == max_req_bytes or wrote != read, write log error and return 403, set read_bytes back to 0
                        conn.readIo(r.io, f, event);
                        return .waiting;
                    },
                    else => return .failed,
                }
            };

            reader.advanceHead(req.size);
            conn.req_bytes_read -= req.size;

            //TODO: if connection is keep-alive, read again until timeout or close is sent by user
            //SEND ANOTHER READ

            conn.start(r.lua, req);
            conn.stop(r.lua);
        }
        fn cancel(f: *Future, r: *Runtime, conn: *ConnectionContext, _: *anyopaque) void {
            conn.deinit();
            r.event_pool.deinit(event);
            r.future_pool.deinit(f);
            r.connection_pool.deinit(conn);
        }
    };
    fut.* = .{
        .conn = c,
        //NOTE: observe use of ctxt because I may not need it
        .ctxt = event,
        .vtable = .{
            .wake = Readcb.wake,
            .cancel = Readcb.cancel,
        },
    };
    c.readIo(io, fut, event);
}
///future and event must outlive function
pub fn write(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, _: *anyopaque) Future.State {
            std.debug.assert(event.status.complete == .writev);
            const written = event.status.complete.writev catch return .failed;
            const writer = conn.writer;
            writer.consume(written);

            if (writer.pending()) {
                conn.writeIo(r.io, f, event);
                return .waiting;
            }
            return .finished;
        }
        fn cancel(f: *Future, r: *Runtime, conn: *ConnectionContext, _: *anyopaque) void {
            conn.deinit();
            r.event_pool.deinit(event);
            r.future_pool.deinit(f);
            r.connection_pool.deinit(conn);
        }
    };
    fut.* = .{
        .conn = c,
        //NOTE: observe use of ctxt because I may not need it
        .ctxt = event,
        .vtable = .{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    c.writeIo(io, fut, event);
}

///future and event must outlive function
pub fn close(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, _: *anyopaque) Future.State {
            std.debug.print("Connection closed", .{});
            conn.deinit();
            r.event_pool.destroy(event);
            r.FuturePool.destroy(f);
            r.connection_pool.destroy(conn);
        }
        fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, _: *anyopaque) void {
            return;
        }
    };
    fut.* = .{
        .conn = c,
        //NOTE: observe use of ctxt because I may not need it
        .ctxt = event,
        .vtable = .{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    event.* = .close(fut, c.handle);
    io.submit(event);
}

inline fn readIo(conn: *ConnectionContext, io: Io, future: *Future, event: *Io.Event) void {
    const slice = conn.reader.free();
    conn.rvec = .{
        .{
            .ptr = slice.first.ptr,
            .len = slice.first.len,
        },
        .{
            .ptr = slice.second.ptr,
            .len = slice.second.len,
        },
    };
    event.* = Io.Event.read(future, conn.handle, &conn.rvec, 0);
    future.* = .{
        .conn = conn,
        .ctxt = conn,
        .vtable = .{
            .wake = Runtime.wake,
            .cancel = Runtime.cancel,
        },
    };
    io.submit(event) catch {};
}
inline fn writeIo(conn: *ConnectionContext, io: *Io, future: *Future, event: *Io.Event) void {
    const slice = conn.writer.pending();
    conn.wvec = .{
        .{
            .ptr = slice.first.ptr,
            .len = slice.first.len,
        },
        .{
            .ptr = slice.second.ptr,
            .len = slice.second.len,
        },
    };
    event.* = Io.Event.writev(future, conn.handle, &conn.wvec, 0);
    future.* = .{
        .conn = conn,
        .ctxt = conn,
        .vtable = .{
            .wake = Runtime.wake,
            .cancel = Runtime.cancel,
        },
    };
    io.submit(event) catch {};
}
