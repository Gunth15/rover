addr: std.net.Address = undefined,
handle: Io.Handle = undefined,
req_threads: std.ArrayList(Thread),
rvec: [2]Io.Vec = undefined,
wvec: [2]Io.Vec = undefined,
reader: Reader,
writer: Writer,
slab: std.heap.FixedBufferAllocator,
allocation_fail_count: usize = 0,
req_bytes_read: usize = 0,
total_bytes_read: usize = 0,

const ConnectionContext = @This();
const std = @import("std");
const lib = @import("lib.zig");
const Runtime = lib.Runtime;
const Future = lib.Future;
const Io = lib.Io;
const Lua = lib.Lua;
const Parser = lib.HttpParser;
const EventQueue = lib.Queue(Io.Event);
const HttpParser = lib.HttpParser;
const Router = lib.Router.Router(c_int, .{ .lua = true });
const Reader = lib.Util.Reader;
const Writer = lib.Util.Writer;
const connection_log = std.log.scoped(.connection);

const Thread = struct {
    ref: c_int,
    lthread: Lua,
    arena: std.heap.ArenaAllocator,
    fn resumeT(t: *Thread) void {
        var nresults: usize = 0;
        switch (t.lthread.resumeT(null, 1, &nresults) catch {
            const err = t.lthread.to(Lua.String, -1) catch unreachable;
            @panic(err);
        }) {
            .OK => {
                //cleanup thread

            },
            .YIELDED => {
                //assumes a future was sent somwhere
            },
        }
    }
    fn startT(t: *Thread, conn: *ConnectionContext, router: *Router, req: HttpParser.Request) void {
        //send connection
        const thread: *Lua = &t.lthread;

        connection_log.info("[fd: {d}] Getting handler for path {s} with method {s}", .{ conn.handle, req.path, req.method });

        //create connection table
        thread.newTable();
        const conn_table = thread.getTop();

        const lfunc = router.search(thread, req.method, req.path) catch @panic("Router error");
        thread.setField(-2, "assigns");

        thread.push(req.headers.get("Host"));
        thread.setField(-2, "host");

        thread.push(req.minor_version);
        thread.setField(-2, "minor");

        thread.push(req.method);
        thread.setField(-2, "method");

        //TODO: handle headers better when I make my own parser
        thread.newTable();
        var iter = req.headers.iterator();
        while (iter.next()) |entry| {
            thread.push(entry.value_ptr.*);
            thread.setField(-2, entry.key_ptr.*);
        }
        thread.setField(conn_table, "headers");

        thread.push(req.path);
        thread.setField(conn_table, "request_path");

        thread.push(conn.addr.getPort());
        thread.setField(conn_table, "port");

        std.debug.assert(thread.getGlobal("rover") == .table);
        std.debug.assert(thread.getField(-1, "connection") == .table);
        thread.setMetaTable(conn_table);
        thread.pop(1);

        std.debug.assert(thread.getRawI(Lua.RegistryIndex, lfunc) == .func);
        connection_log.info("[fd: {d}] Router found handler: {d}", .{ conn.handle, lfunc });
        thread.insert(conn_table);
        t.resumeT();
    }
};
pub inline fn init(slab: std.mem.Allocator, mem_size: usize, reader_size: usize, writer_size: usize) !ConnectionContext {
    var conn_slab = std.heap.FixedBufferAllocator.init(
        try slab.alloc(u8, mem_size),
    );
    const alloc = conn_slab.allocator();
    return .{
        .slab = conn_slab,
        .reader = try .init(alloc, reader_size),
        .writer = try .init(alloc, writer_size),
        .allocation_fail_count = 0,
        .req_threads = try .initCapacity(alloc, 4),
    };
}
pub inline fn reset(conn: *ConnectionContext) void {
    const writer_size = conn.writer.buf.len;
    const reader_size = conn.reader.buf.len;
    conn.addr = undefined;
    conn.handle = undefined;
    conn.slab.reset();
    const alloc = conn.slab.allocator();
    //shoud never fail
    conn.reader = Reader.init(alloc, reader_size) catch unreachable;
    conn.writer = Writer.init(alloc, writer_size) catch unreachable;
    conn.allocation_fail_count = 0;
    conn.req_bytes_read = 0;
    conn.total_bytes_read = 0;
}
pub fn start(conn: *ConnectionContext, lua: *Lua, router: *Router, req: HttpParser.Request) !Thread {
    const lthread = try lua.newThread();
    const ref = lua.ref();
    var thread: Thread = .{
        .arena = std.heap.ArenaAllocator.init(conn.slab.allocator()),
        .ref = ref,
        .lthread = lthread,
    };

    thread.startT(conn, router, req);
    return thread;
}
pub fn stop(conn: *ConnectionContext, lua: *Lua, thread: *Thread) void {
    //OPTIMIZE: Instead of getting a raw buffer from lua, return status, headers, and body
    defer {
        thread.arena.deinit();
        lua.unref(thread.ref);
    }

    var payload_size: usize = 0;

    const version = "HTTP/1.1 ";
    payload_size += conn.writer.fill(version);

    var l = &thread.lthread;
    //TODO: make this a check for something
    std.debug.assert(l.Luatype(-1) == .table);
    const ret_table = l.getTop();

    std.debug.assert(l.getField(ret_table, "status") == .number);
    const status = l.to(Lua.Integer, -1) catch unreachable;
    var status_buf: [3]u8 = undefined;
    const sb = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch @panic("Invalid status code");
    payload_size += conn.writer.fill(sb);

    std.debug.assert(l.getField(ret_table, "headers") == .table);
    l.push(null);
    while (l.Next(-2) != .nil) {
        const key = l.to(Lua.String, -2) catch unreachable;
        const value = l.to(Lua.String, -1) catch unreachable;
        payload_size += conn.writer.fill(key);
        payload_size += conn.writer.fill(":");
        payload_size += conn.writer.fill(value);
        payload_size += conn.writer.fill("\r\n");
        l.pop(1);
    }
    payload_size += conn.writer.fill("\r\n");

    std.debug.assert(l.getField(ret_table, "body") == .string);
    const body = l.to(Lua.String, -1) catch unreachable;
    payload_size += conn.writer.fill(body);

    if (payload_size < (conn.writer.end - conn.writer.start)) @panic("Full return string not written, TODO: handle this case");
}
///future and evet must outlive function
///rearms context to accept new connection handle and address
pub fn rearm(c: *ConnectionContext, io: *Io, fut: *Future, event: *Io.Event, server_handle: Io.Handle) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            std.debug.assert(ev.status == .complete);
            std.debug.assert(ev.status.complete == .accept);

            const conn = f.conn;

            conn.handle = ev.status.complete.accept catch |e| {
                connection_log.err("[fd: {d}] Failed to accept new connection: {any}", .{ conn.handle, e });
                return .failed;
            };
            connection_log.info("[fd: {d}] New connection started", .{conn.handle});
            conn.readAndStart(&r.io, f, ev);
            return .waiting;
        }
        fn cancel(f: *Future, r: *Runtime) void {
            const conn = f.conn;
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            conn.rearm(&r.io, f, ev, r.server.stream.handle);
            return;
        }
    };
    event.* = .accept(fut, server_handle, &c.addr);
    fut.* = .{
        .conn = c,
        .ctxt = event,
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
        fn wake(f: *Future, r: *Runtime) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            std.debug.assert(ev.status == .complete);
            std.debug.assert(ev.status.complete == .read);
            const conn = f.conn;

            const read_bytes = ev.status.complete.read catch |e| {
                connection_log.err("[fd: {d}] Failed to read connection: {any}", .{ conn.handle, e });
                return .failed;
            };

            //TODO: handle zero bytes read
            const reader = &conn.reader;
            reader.advance(read_bytes);

            const prev_bytes_read = conn.req_bytes_read;

            //TODO: make an assert, so reader cannot be larger than this
            var temp: [4096 * 4]u8 = undefined;

            const slice = reader.peek();
            //OPTIMIZE: I hope to replace this with a stateful http parser to remove the need for a temporary buffer
            const buf_size = slice.first.len + slice.second.len;
            @memcpy(temp[0..slice.first.len], slice.first);
            @memcpy(temp[slice.first.len..buf_size], slice.second);
            const parsable = temp[0..buf_size];

            conn.total_bytes_read += read_bytes;
            conn.req_bytes_read += read_bytes;

            connection_log.info("[fd: {d}] Reading connection\n{s}\n{s}\n{s}", .{ conn.handle, "-" ** 50, parsable, "-" ** 50 });
            connection_log.info("[fd: {d}] Bytes read so far: {d}", .{ conn.handle, conn.req_bytes_read });
            const req = Parser.parse(parsable, conn.slab.allocator(), 64, prev_bytes_read) catch |e| {
                switch (e) {
                    error.PartialRequest => {
                        //TODO: if req_bytes_read == max_req_bytes or wrote != read, write log error and return 403, set read_bytes back to 0
                        connection_log.info("[fd: {d}] Http request partialy read, preping another read", .{conn.handle});
                        conn.readIo(&r.io, f, ev);
                        return .waiting;
                    },
                    else => {
                        connection_log.err("[fd: {d}] Failed to read connection: {any}", .{ conn.handle, e });
                        return .failed;
                    },
                }
            };

            reader.consumeHead(req.size);
            conn.req_bytes_read -= req.size;
            connection_log.info("[fd: {d}] Total Bytes read: {d}", .{ conn.handle, conn.total_bytes_read });
            connection_log.info("[fd: {d}] Request Size: {d}", .{ conn.handle, req.size });

            //TODO: if connection is keep-alive, read again until timeout or close is sent by user
            //SEND ANOTHER READ

            connection_log.info("[fd: {d}] Starting new lua thread", .{conn.handle});
            var thread = conn.start(&r.lua, &r.router, req) catch |e| @panic(@typeName(@TypeOf(e)));
            connection_log.info("[fd: {d}] Shutting down lua thread", .{conn.handle});
            conn.stop(&r.lua, &thread);
            conn.write(&r.io, f, ev);
            return .waiting;
        }
        fn cancel(f: *Future, r: *Runtime) void {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            f.conn.close(&r.io, f, ev);
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
        fn wake(f: *Future, r: *Runtime) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            std.debug.assert(ev.status == .complete);
            std.debug.assert(ev.status.complete == .writev);

            const conn = f.conn;
            connection_log.info("[fd: {d}] Writing new connection", .{conn.handle});
            const written = ev.status.complete.writev catch |e| {
                connection_log.err("[fd: {d}] Error writing to connection: {any}", .{ conn.handle, e });
                return .failed;
            };
            const writer = &conn.writer;
            writer.consume(written);

            if (writer.hasPendingBytes()) {
                conn.writeIo(&r.io, f, ev);
                return .waiting;
            }
            conn.close(&r.io, f, ev);
            return .waiting;
        }
        fn cancel(f: *Future, r: *Runtime) void {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            f.conn.close(&r.io, f, ev);
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
        fn wake(f: *Future, r: *Runtime) Future.State {
            const ev: *Io.Event = @ptrCast(@alignCast(f.ctxt));
            const conn = f.conn;

            connection_log.info("[fd: {d}] Connection closed", .{conn.handle});

            conn.reset();
            conn.rearm(&r.io, f, ev, r.server.stream.handle);
            return .waiting;
        }
        fn cancel(_: *Future, _: *Runtime) void {
            //close never fails
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
