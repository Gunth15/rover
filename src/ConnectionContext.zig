addr: std.net.Address = undefined,
handle: Io.Handle = undefined,
rvec: [2]Io.Vec = undefined,
wvec: [2]Io.Vec = undefined,
reader: lib.Reader,
writer: lib.Writer,
slab: std.heap.FixedBufferAllocator,
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
    fn resumeT(t: *Thread) void {
        var nresults: usize = 0;
        const state = t.lthread.resumeT(null, 1, &nresults) catch @panic("Out of memory or some other runtime error, TODO: handle cases properly");
        std.debug.assert(state == .OK);
    }
    fn startT(t: *Thread, conn: *ConnectionContext, req: HttpParser.Request) void {
        //send connection
        const thread: *Lua = &t.lthread;

        std.debug.assert(thread.getGlobal("rover.routing.table") == .table);

        const alloc = conn.slab.allocator();
        const path_buf = alloc.alloc(u8, req.path.len + 1) catch @panic("No memory");
        @memcpy(path_buf[0..req.path.len], req.path);
        path_buf[req.path.len] = 0;
        defer alloc.free(path_buf);

        if (thread.getField(-1, @ptrCast(path_buf)) != .func) thread.fmtError("Invalid handler type", .{});

        thread.newTable();
        thread.push(req.headers.get("Host"));
        thread.setField(-2, "host");

        thread.push(req.method);
        thread.setField(-2, "method");

        //TODO: handle header differnelty
        //thread.push(req.headers);
        //thread.setField(-2,"headers");

        //TODO: Path info

        thread.push(req.path);
        thread.setField(-2, "request_path");

        //TODO: Scheme
        //thread.push(req.scheme);
        //thread.setField(-2, "scheme");

        thread.push(req.body);
        thread.setField(-2, "body");

        //TODO: Assigns
        //thread.push(req.scheme);

        //TODO: shared
        //thread.push(req.scheme);

        thread.push(conn.addr.getPort());
        thread.setField(-2, "port");

        t.resumeT();
    }
};
pub inline fn init(slab: std.mem.Allocator, mem_size: usize, reader_size: usize, writer_size: usize) !ConnectionContext {
    const conn_slab = std.heap.FixedBufferAllocator.init(
        try slab.alloc(u8, mem_size),
    );
    return .{
        .slab = conn_slab,
        .reader = try .init(slab, reader_size),
        .writer = try .init(slab, writer_size),
        .allocation_fail_count = 0,
    };
}
pub inline fn reset(conn: *ConnectionContext) !ConnectionContext {
    conn.addr = undefined;
    conn.slab.reset();
    conn.handle = undefined;
    conn.threads = .{};
    conn.reader.reset();
    conn.allocation_fail_count = 0;
}
pub fn start(conn: *ConnectionContext, lua: *Lua, req: HttpParser.Request) !Thread {
    var l = lua;
    const lthread = try l.newThread();
    const ref = l.ref();
    var thread: Thread = .{
        .arena = std.heap.ArenaAllocator.init(conn.slab.allocator()),
        .ref = ref,
        .lthread = lthread,
    };

    thread.startT(conn, req);
    return thread;
}
pub fn stop(conn: *ConnectionContext, lua: *Lua, thread: *Thread) void {
    //OPTIMIZE: Instead of getting a raw buffer from lua, return status, headers, and body
    defer {
        thread.arena.deinit();
        lua.unref(thread.ref);
    }

    const str = thread.lthread.to(Lua.String, 0) catch @panic("Return value is not a string");
    const wrote = conn.writer.fill(str);
    if (wrote != str.len) @panic("Full return string not written, TODO: handle this case");
}
///future and evet must outlive function
///rearms context to accept new connection handle and address
pub fn rearm(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event, server_handle: Io.Handle) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            std.debug.assert(ev.status == .complete);
            std.debug.assert(ev.status.complete == .accept);

            conn.handle = ev.status.complete.accept catch return .failed;
            conn.readAndStart(&r.io, f, ev);
            return .waiting;
        }
        fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, _: *anyopaque) void {
            return;
        }
    };
    event.* = .accept(fut, server_handle, &c.addr);
    fut.* = .{
        .conn = c,
        .ctxt = fut,
        .vtable = &.{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    io.submit(event) catch {};
}
///future and evet must outlive function
///Starts handling request if it receieves a full HTTP Request
fn readAndStart(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const Readcb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            std.debug.assert(ev.status.complete == .read);

            const read_bytes = ev.status.complete.read catch return .failed;

            //TODO: handle zero bytes read
            const reader = &conn.reader;
            reader.advance(read_bytes);

            const prev_bytes_read = conn.req_bytes_read;

            //TODO: make an assert, so reader cannot be larger than this
            var temp: [4096 * 4]u8 = undefined;

            const slice = reader.peek();
            //OPTIMIZE: I hope to replace this with a stateful http parser to remove the need
            //for a temporary buffer
            const buf_size = slice.first.len + slice.second.len;
            @memcpy(temp[0..slice.first.len], slice.first);
            @memcpy(temp[slice.first.len..buf_size], slice.second);
            const parsable = temp[0..buf_size];

            conn.total_bytes_read += read_bytes;
            conn.req_bytes_read += read_bytes;
            const req = Parser.parse(parsable, conn.slab.allocator(), 64, prev_bytes_read) catch |e| {
                switch (e) {
                    error.PartialRequest => {
                        //TODO: if req_bytes_read == max_req_bytes or wrote != read, write log error and return 403, set read_bytes back to 0
                        conn.readIo(&r.io, f, ev);
                        return .waiting;
                    },
                    else => return .failed,
                }
            };

            reader.consumeHead(req.size);
            conn.req_bytes_read -= req.size;

            //TODO: if connection is keep-alive, read again until timeout or close is sent by user
            //SEND ANOTHER READ

            var thread = conn.start(&r.lua, req) catch |e| @panic(@typeName(@TypeOf(e)));
            conn.stop(&r.lua, &thread);
            conn.write(&r.io, f, ev);
            return .waiting;
        }
        fn cancel(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) void {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            conn.close(&r.io, f, ev);
        }
    };
    fut.* = .{
        .conn = c,
        .ctxt = event,
        .vtable = &.{
            .wake = Readcb.wake,
            .cancel = Readcb.cancel,
        },
    };
    c.readIo(io, fut, event);
}
///future and event must outlive function
fn write(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            std.debug.assert(ev.status.complete == .writev);
            const written = ev.status.complete.writev catch return .failed;
            const writer = &conn.writer;
            writer.consume(written);

            if (writer.hasPendingBytes()) {
                conn.writeIo(&r.io, f, ev);
                return .waiting;
            }
            return .finished;
        }
        fn cancel(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) void {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            conn.close(&r.io, f, ev);
        }
    };
    fut.* = .{
        .conn = c,
        .ctxt = event,
        .vtable = &.{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    c.writeIo(io, fut, event);
}

///future and event must outlive function
fn close(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime, conn: *ConnectionContext, ptr: *anyopaque) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(ptr));
            std.debug.print("Connection closed", .{});
            conn.rearm(&r.io, f, ev, r.server.stream.handle);
            return .waiting;
        }
        fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, _: *anyopaque) void {
            return;
        }
    };
    fut.* = .{
        .conn = c,
        .ctxt = event,
        .vtable = &.{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    event.* = .close(fut, c.handle);
    io.submit(event) catch {};
}

inline fn readIo(conn: *ConnectionContext, io: *Io, future: *Future, event: *Io.Event) void {
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
    io.submit(event) catch {};
}
