const ConnectionContext = @This();
const std = @import("std");
const lib = @import("lib.zig");
const Runtime = lib.Runtime;
const Logger = &lib.Logger.Instance;
const Io = std.Io;
const Lua = lib.Lua;
const LVM = lib.LVM;
const operations = lib.operation;
const Parser = lib.HttpParser;
const EventQueue = lib.Util.Queue(Io.Event);
const HttpParser = lib.HttpParser;
const Router = lib.Router.Router(c_int, .{ .lua = true });
const Reader = lib.Util.Reader;
const Writer = lib.Util.Writer;
const RequestQueue = Io.Queue(struct { writer: Io.Writer, req: Parser.Request });
const connection_log = std.log.scoped(.connection);

const INTERNAL_SERVER_ERROR =
    \\HTTP/1.1 500 Internal Server Error\r\n
    \\Content-Type: text/plain; charset=utf-8\r\n
    \\Content-Length: 21\r\n
    \\Connection: close\r\n
    \\\r\n
    \\Internal Server Error
;

//TODO: need better allocation scheme
pub const Sequence = struct {
    id: u32,
    req: HttpParser.Request,
    resp: Io.Writer.Allocating,
    ctxt: *Context,
    arena: std.heap.ArenaAllocator,
};
pub const Context = struct {
    runtime: *Runtime,
    resp_queue: Io.Queue(*Sequence),
    stream: Io.net.Stream,
    in_flight: std.atomic.Value(u32),
};

const DOESNOTEXIST: c_int = -1;
const INVALIDMETHOD = -2;
pub fn createConnectionTable(thread: *Lua, router: *Router, req: *const HttpParser.Request) void {
    thread.createTable(0, 8);
    const conn_table = thread.getTop();

    const lfunc = router.search(thread, req.method, req.path) catch |e| switch (e) {
        error.DoesNotExist => DOESNOTEXIST,
        error.InvalidMethod => INVALIDMETHOD,
        error.OutOfMemory => @panic("Out OF MEMORY"),
    };
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

    thread.push("TODO: ADD PORT AGAIN");
    thread.setField(conn_table, "port");

    std.debug.assert(thread.getGlobal("rover") == .table);
    std.debug.assert(thread.getField(-1, "connection") == .table);
    thread.setMetaTable(conn_table);
    thread.pop(1);

    switch (lfunc) {
        INVALIDMETHOD => {
            Logger.log(.TRACE, "Invalid method, but royte does not exist in router", .{});
        },
        DOESNOTEXIST => {
            Logger.log(.TRACE, "Path does not exist in router", .{});
        },
        else => {
            std.debug.assert(thread.getRawI(Lua.RegistryIndex, lfunc) == .func);
            Logger.log(.TRACE, "Found handle in router", struct { function_handler: c_int }{ .function_handler = lfunc });
        },
    }
    thread.insert(conn_table);
}
pub fn execute(inst: *LVM.Instance, s: *anyopaque) void {
    const seq: *Sequence = @ptrCast(@alignCast(s));
    const ctxt = seq.ctxt;
    const runtime = ctxt.runtime;
    var lua = inst.coro.state;
    var nresults: usize = 0;
    switch (lua.resumeT(null, 1, &nresults) catch {
        const err_ptr = lua.getAbs(-1);
        std.debug.assert(lua.getGlobal("rover") == .table);
        std.debug.assert(lua.getField(-1, "on_error") == .func);
        lua.insert(err_ptr);
        lua.pop(1);
        lua.pcall(1, 1) catch {
            const err = lua.to(Lua.String, -1) catch unreachable;
            @panic(err);
        };

        return queueResponse(seq, &lua);
    }) {
        .OK => {
            std.debug.assert(nresults == 1);
            return queueResponse(seq, &lua);
        },
        .YIELDED => {
            const op = operations.Operation.decode(&lua, seq.arena.allocator(), nresults) catch @panic("TODO: handle errors");
            op.dispatch(
                inst,
                runtime.io,
                seq.arena.allocator(),
                execute,
                seq,
                Sequence,
            );
        },
    }
}

pub fn luaConnectionHandler(instance: *LVM.Instance, userdata: *anyopaque) void {
    const thread = instance.coro.state;
    const seq: *Sequence = @ptrCast(@alignCast(userdata));
    const ctxt = seq.ctxt;
    const runtime = ctxt.runtime;

    createConnectionTable(@constCast(&thread), &runtime.router.?, &seq.req);
    execute(instance, seq);
}

pub fn handle(runtime: *Runtime, stream: Io.net.Stream) void {
    var buff: [256]*Sequence = undefined;
    defer stream.close(runtime.io);

    var ctxt: Context = .{
        .runtime = runtime,
        .stream = stream,
        .resp_queue = .init(&buff),
        .in_flight = .init(0),
    };

    var read_fut = runtime.io.concurrent(read_loop, .{ @ptrCast(&ctxt), stream }) catch {
        readWriteLoop(&ctxt, stream);
        ctxt.resp_queue.close(runtime.io);
        return;
    };

    var write_fut = runtime.io.concurrent(write_loop, .{ @ptrCast(&ctxt), stream }) catch |e| @panic(@errorName(e));

    read_fut.await(runtime.io) catch |e| catchReadError(&ctxt, e, stream);

    ctxt.resp_queue.close(runtime.io);

    write_fut.await(runtime.io) catch |e| {
        Logger.log(.ERROR, "Failed to write to connection", struct { reason: @TypeOf(e) }{ .reason = e });
    };
}

fn readWriteLoop(ctxt: *Context, stream: std.Io.net.Stream) void {
    const runtime = ctxt.runtime;
    const alloc = runtime.allocator;
    var rbuff: [4096]u8 = undefined;
    var reader = stream.reader(runtime.io, &rbuff);

    var wbuff: [4096]u8 = undefined;
    var writer = stream.writer(runtime.io, &wbuff);

    var buffered_Writer: Io.Writer.Allocating = .init(alloc);
    defer buffered_Writer.deinit();

    var next_id: u32 = 0;
    while (true) {
        const maybe_req = readOnce(runtime, &reader, &buffered_Writer) catch |e| return catchReadError(ctxt, e, stream);
        const req = maybe_req orelse return;

        _ = buffered_Writer.writer.consumeAll();

        Logger.log(.TRACE, "Finished parsing request", struct { handle: Io.net.Socket.Handle, total_bytes_read: usize, request_size: usize }{ .handle = stream.socket.handle, .total_bytes_read = buffered_Writer.written().len, .request_size = req.size });
        Logger.log(.DEBUG, "New request", struct { method: []const u8, path: []const u8, request_size: usize }{ .method = req.method, .path = req.path, .request_size = req.size });

        var seq: Sequence = Sequence{
            .arena = .init(alloc),
            .resp = undefined,
            .ctxt = ctxt,
            .id = next_id,
            .req = req,
        };

        runtime.lvm.run(
            runtime.io,
            luaConnectionHandler,
            @ptrCast(@alignCast(&seq)),
        ) catch |e| @panic(@errorName(e));

        //Should be one element on queue
        _ = ctxt.resp_queue.getOneUncancelable(runtime.io) catch unreachable;
        writer.interface.writeAll(seq.resp.toOwnedSlice() catch |e| @panic(@errorName(e))) catch |e| @panic(@errorName(e));
        writer.interface.flush() catch |e| @panic(@errorName(e));
        next_id += 1;
    }
}

fn queueResponse(request: *Sequence, lua: *Lua) void {
    var l = lua;
    var aw = Io.Writer.Allocating.init(request.arena.allocator());
    var writer = &aw.writer;

    const ret_table = l.getTop();
    std.debug.assert(l.getField(ret_table, "status") == .number);
    const status = l.to(Lua.Integer, -1) catch unreachable;
    writer.print("HTTP/1.1 {d} TODO\r\n", .{status}) catch unreachable;

    std.debug.assert(l.getField(ret_table, "headers") == .table);
    l.push(null);
    while (l.Next(-2) != .nil) {
        const key = l.to(Lua.String, -2) catch unreachable;
        const value = l.to(Lua.String, -1) catch unreachable;
        l.pop(1);
        writer.print("{s}:{s}\r\n", .{ key, value }) catch unreachable;
    }

    _ = writer.write("\r\n") catch unreachable;

    if (l.getField(ret_table, "body") == .string) {
        const body = l.to(Lua.String, -1) catch unreachable;
        _ = writer.write(body) catch unreachable;
    }
    _ = request.ctxt.in_flight.fetchSub(1, .acquire);
    request.resp = aw;
    request.ctxt.resp_queue.putOne(request.ctxt.runtime.io, request) catch |e| @panic(@errorName(e));
}

const ReadOnceError = error{OutOfMemory} || std.Io.net.Stream.Reader.Error || Parser.ParseError;
inline fn readOnce(runtime: *Runtime, reader: *Io.net.Stream.Reader, alloc_w: *Io.Writer.Allocating) !?Parser.Request {
    read_loop: while (true) {
        const bytes_read = alloc_w.written().len;
        const limit = runtime.max_read - bytes_read;
        _ = reader.interface.stream(&alloc_w.writer, .limited(limit)) catch |e| switch (e) {
            Io.Reader.StreamError.ReadFailed => return reader.err.?,
            Io.Reader.StreamError.WriteFailed => return ReadOnceError.OutOfMemory,
            Io.Reader.StreamError.EndOfStream => return null,
        };
        const buf = alloc_w.written();

        return Parser.parse(buf, runtime.allocator, 64, bytes_read) catch |e| switch (e) {
            error.PartialRequest => continue :read_loop,
            else => return e,
        };
    }
}
inline fn catchReadError(ctxt: *Context, e: ReadOnceError, stream: Io.net.Stream) void {
    const runtime = ctxt.runtime;
    switch (e) {
        //TODO: Handle parse errors
        ReadOnceError.OutOfMemory => {
            //This will make sure the queue is emptied
            //before attempting to write to the stream
            //to avoid corruption
            ctxt.resp_queue.close(runtime.io);
            var errbuff: [4096]u8 = undefined;
            var ew = stream.writer(runtime.io, &errbuff);
            ew.interface.writeAll(INTERNAL_SERVER_ERROR) catch {};
            Logger.log(.ERROR, "Out of Memory", .{});
            ew.interface.flush() catch {};
        },
        else => Logger.log(.ERROR, "Failed to read connection", struct { reason: ReadOnceError }{ .reason = e }),
    }
}

fn read_loop(ctxt: *Context, stream: Io.net.Stream) ReadOnceError!void {
    //TODO: if connection is keep-alive, read again until timeout or close is sent by user
    //SEND ANOTHER READ
    const runtime = ctxt.runtime;
    const alloc = runtime.allocator;
    var buff: [4096]u8 = undefined;
    var reader = stream.reader(runtime.io, &buff);

    var next_id: u32 = 0;

    var buffered_Writer: Io.Writer.Allocating = .init(alloc);
    defer buffered_Writer.deinit();

    while (true) {
        Logger.log(.TRACE, "Reading connection", struct { handle: Io.net.Socket.Handle }{ .handle = stream.socket.handle });
        const req = try readOnce(runtime, &reader, &buffered_Writer) orelse return;

        _ = buffered_Writer.writer.consumeAll();
        Logger.log(.TRACE, "Finished parsing request", struct { handle: Io.net.Socket.Handle, total_bytes_read: usize, request_size: usize }{ .handle = stream.socket.handle, .total_bytes_read = buffered_Writer.written().len, .request_size = req.size });
        Logger.log(.DEBUG, "New request", struct { method: []const u8, path: []const u8, request_size: usize }{ .method = req.method, .path = req.path, .request_size = req.size });

        const seq = try alloc.create(Sequence);
        seq.* = Sequence{
            .arena = .init(alloc),
            .resp = undefined,
            .ctxt = ctxt,
            .id = next_id,
            .req = req,
        };
        _ = ctxt.in_flight.fetchAdd(1, .monotonic);
        runtime.lvm.run(
            runtime.io,
            luaConnectionHandler,
            @ptrCast(@alignCast(seq)),
        ) catch |e| @panic(@errorName(e));

        next_id += 1;
    }
    //NOTE: spin-lock
    while (ctxt.in_flight.load(.acquire) != 0) continue;
}
fn write_loop(ctxt: *Context, stream: Io.net.Stream) !void {
    var buff: [4096]u8 = undefined;
    var sbuff: [256]*Sequence = undefined;
    const runtime = ctxt.runtime;
    const alloc = ctxt.runtime.allocator;

    var writer = stream.writer(runtime.io, &buff);
    var curr_seq_number: u32 = 0;
    while (true) {
        const len = ctxt.resp_queue.get(runtime.io, &sbuff, 1) catch break;
        for (sbuff[0..len]) |seq| {
            defer {
                seq.arena.deinit();
                alloc.destroy(seq);
            }
            if (seq.id != curr_seq_number) ctxt.resp_queue.putOne(runtime.io, seq) catch break;
            try writer.interface.writeAll(try seq.resp.toOwnedSlice());

            curr_seq_number += 1;
        }
        try writer.interface.flush();
    }
}
