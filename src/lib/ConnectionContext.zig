const ConnectionContext = @This();
const std = @import("std");
const lib = @import("lib.zig");
const Runtime = lib.Runtime;
const Io = std.Io;
const Lua = lib.Lua;
const LVM = @import("runtime/LuaVM.zig");
const Parser = lib.HttpParser;
const EventQueue = lib.Util.Queue(Io.Event);
const HttpParser = lib.HttpParser;
const Router = lib.Router.Router(c_int, .{ .lua = true });
const Reader = lib.Util.Reader;
const Writer = lib.Util.Writer;
const RequestQueue = Io.Queue(struct { writer: Io.Writer, req: Parser.Request });
const connection_log = std.log.scoped(.connection);

const Context = struct { req: HttpParser.Request, runtime: *Runtime, stream: Io.net.Stream };

pub fn createConnectionTable(thread: *Lua, router: *Router, req: *const HttpParser.Request) void {
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

    thread.push("TODO: ADD PORT AGAIN");
    thread.setField(conn_table, "port");

    std.debug.assert(thread.getGlobal("rover") == .table);
    std.debug.assert(thread.getField(-1, "connection") == .table);
    thread.setMetaTable(conn_table);
    thread.pop(1);

    std.debug.assert(thread.getRawI(Lua.RegistryIndex, lfunc) == .func);
    connection_log.info("Router found handler: {d}", .{lfunc});
    thread.insert(conn_table);
}
pub fn execute(thread: *LVM.Thread, ctxt: *Context) void {
    const runtime = ctxt.runtime;
    var lua = thread.state;
    var nresults: usize = 0;
    switch (lua.resumeT(null, 1, &nresults) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        @panic(err);
    }) {
        .OK => {
            var sw = ctxt.stream.writer(runtime.io, runtime.allocator.alloc(u8, runtime.max_write) catch |e| return connection_log.err("{any}", .{e}));
            var writer = &sw.interface;
            defer {
                lua.unref(thread.ref);
                runtime.allocator.destroy(ctxt);
                runtime.allocator.free(writer.buffer);
            }
            std.debug.assert(nresults == 1);
            var l = &lua;

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

            writer.flush() catch unreachable;
        },
        .YIELDED => {
            //NOTE: Whatever function yielded is expeted to know how to also resume the function
        },
    }
}
pub fn luaConnectionHandler(thread: *LVM.Thread, userdata: *anyopaque) void {
    const ctxt: *Context = @ptrCast(@alignCast(userdata));
    const runtime = ctxt.runtime;
    var new_thread: LVM.Thread = .{
        .ref = thread.state.ref(),
        .state = thread.state.newThread() catch @panic("YOU OOMED LOL"),
    };

    //NOTE: Router is guranteed to run on a single thread because it runs on the LuaVm
    createConnectionTable(&new_thread.state, &runtime.router.?, &ctxt.req);
    execute(&new_thread, ctxt);
}
pub fn handle(runtime: *Runtime, stream: Io.net.Stream) void {
    const conn_handle = stream.socket.handle;
    defer stream.close(runtime.io);
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();

    var alloc = arena.allocator();

    //TODO: if connection is keep-alive, read again until timeout or close is sent by user
    //SEND ANOTHER READ
    var reader = stream.reader(runtime.io, alloc.alloc(u8, runtime.max_read) catch |e| return connection_log.err("{any}", .{e}));

    var buffered_Writer: Io.Writer.Allocating = .init(alloc);
    var parsed_bytes: usize = 0;
    var total_bytes_read: usize = 0;

    handle_request: while (true) {
        const limit = runtime.max_read - parsed_bytes;
        _ = reader.interface.stream(&buffered_Writer.writer, .limited(limit)) catch |e| {
            switch (e) {
                Io.Reader.StreamError.ReadFailed => return connection_log.err("{any}", .{reader.err}),
                Io.Reader.StreamError.WriteFailed => return connection_log.err("No more ememory", .{}),
                Io.Reader.StreamError.EndOfStream => break :handle_request,
            }
        };
        const buf = buffered_Writer.written();

        total_bytes_read += buf.len;

        log_info(conn_handle, "[fd: {d}] Reading connection\n{s}\n{s}\n{s}", .{ stream.socket.handle, "-" ** 50, buf, "-" ** 50 });
        const req = Parser.parse(buf, alloc, 64, parsed_bytes) catch |e| {
            switch (e) {
                Parser.ParseError.PartialRequest => {
                    parsed_bytes += buf.len;
                    continue :handle_request;
                },
                else => {
                    log_err(conn_handle, "Failed to read connection: {any}", .{e});
                    return;
                },
            }
        };

        parsed_bytes = 0;
        _ = buffered_Writer.writer.consumeAll();
        log_info(conn_handle, "Getting handler for path {s} with method {s}", .{ req.path, req.method });
        log_info(conn_handle, "Total Bytes read: {d}", .{total_bytes_read});
        log_info(conn_handle, "Request Size: {d}", .{req.size});

        const ctxt = runtime.allocator.create(Context) catch @panic("YOU OOMED LOL");
        ctxt.* = .{
            .req = req,
            .runtime = runtime,
            .stream = stream,
        };
        runtime.lvm.enqueueOne(runtime.io, .{
            .run = luaConnectionHandler,
            .userdata = @ptrCast(@alignCast(ctxt)),
            .thread = runtime.lvm.mainThread(),
        }) catch |e| @panic(@errorName(e));
    }
}
fn log_info(connection_handle: i32, comptime format: []const u8, args: anytype) void {
    connection_log.info("[connection fd: {d}]" ++ format, .{connection_handle} ++ args);
}
fn log_err(connection_handle: i32, comptime format: []const u8, args: anytype) void {
    connection_log.err("[connection fd: {d}]" ++ format, .{connection_handle} ++ args);
}
