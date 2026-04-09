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
pub fn startNewThread(conn: *ConnectionContext, lua: *Lua, req: HttpParser.Request) !void {
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
pub fn endThread(conn: *ConnectionContext) []const u8 {
    //OPTIMIZE: Instead of getting a raw buffer from lua, return status, headers, and body
}

///future and event must outlive io submission
pub fn read(conn: *ConnectionContext, io: Io, future: *Future, event: *Io.Event) void {
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
///future and event must outlive io submission
pub fn write(conn: *ConnectionContext, io: Io, future: *Future, event: *Io.Event) void {
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
//WARNING: need to implement high level abstraction to go with Event for this to work
const SignalError = error{InvalidSignal} || Lua.TypeError;
fn getLuaSignal(ctxt: *ConnectionContext) SignalError!void {
    var lua = ctxt.lua;
    //Table structure(deisgned like a syscall)
    //{
    // string of type,
    // [data relvat to thet type IE a handle or a string]
    //}
    std.debug.assert(lua.Luatype(-1) == .table);
    std.debug.assert(lua.getRawI(-1, 0) == .string);
    const call_type = try lua.to([]const u8, -1);

    //if (std.ascii.eqlIgnoreCase(call_type, "accept")) return Io.Event.read(``, handle: either type, buffer: []u8, offset: u64)
    if (std.ascii.eqlIgnoreCase(call_type, "openat")) {
        //WARNING: Handle does not handles windows yet, so it is intpretted as just a int
        std.debug.assert(lua.getRawI(-2, 1) == .number);
        std.debug.assert(lua.getRawI(-3, 2) == .string);
        std.debug.assert(lua.getRawI(-4, 3) == .table);
        const handle = try lua.to(Lua.Integer, -3);
        const path = try lua.to(Lua.String, -2);
        const options = try lua.to(Io.OpenOptions, -1);
    }
    if (std.ascii.eqlIgnoreCase(call_type, "read")) {
        //WARNING: Handle does not handles windows yet, so it is intpretted as just a int
        std.debug.assert(lua.getRawI(-2, 1) == .number);
        std.debug.assert(lua.getRawI(-3, 2) == .number);
        const handle = try lua.to(Lua.Integer, -3);
        const offset = try lua.to(Io.OpenOptions, -1);

        //initialize to build return string
        try lua.initBuf(ctxt.lua_buf);
    }
    if (std.ascii.eqlIgnoreCase(call_type, "send")) {
        //WARNING: Handle does not handles windows yet, so it is intpretted as just a int
        std.debug.assert(lua.getRawI(-2, 1) == .number);
        std.debug.assert(lua.getRawI(-3, 2) == .string);
        std.debug.assert(lua.getRawI(-3, 3) == .table);
        const handle = try lua.to(Lua.Integer, -3);
        const string = try lua.to(Lua.String, -2);
        const options = try lua.to(Io.SendOptions, -1);
        return .{ .io_event = .{ .send = Io.Event.send(ctxt, handle, string, options) } };
    }
    if (std.ascii.eqlIgnoreCase(call_type, "write")) {
        //WARNING: Handle does not handles windows yet, so it is intpretted as just a int
        std.debug.assert(lua.getRawI(-2, 1) == .number);
        std.debug.assert(lua.getRawI(-3, 2) == .string);
        std.debug.assert(lua.getRawI(-3, 3) == .number);
        const handle = try lua.to(Lua.Integer, -3);
        const string = try lua.to(Lua.String, -2);
        const offset = try lua.to(Lua.Integer, -1);
        return .{ .io_event = .{ .write = Io.Event.write(ctxt, handle, string, offset) } };
    }
    if (std.ascii.eqlIgnoreCase(call_type, "close")) {
        //WARNING: Handle does not handles windows yet, so it is intpretted as just a int
        std.debug.assert(lua.getRawI(-2, 1) == .number);
        const handle = try lua.to(Lua.Integer, -1);
        return .{ .io_event = .{ .close = Io.Event.close(ctxt, handle) } };
    }

    return error.InvalidSignal;
}
