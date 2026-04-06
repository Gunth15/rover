addr: std.net.Address = undefined,
port: u16,
handle: Io.Handle,
buf: std.ArrayList(u8),
requests: std.ArrayList(Request) = .empty,
slab: std.heap.FixedBufferAllocator,
allocation_fail_count: usize = 0,

const ConnectionContext = @This();
const Runtime = @import("Runtime.zig");
const std = @import("std");
const lib = @import("lib/lib.zig");
const Io = lib.Io;
const Lua = lib.Lua;
const Parser = lib.HttpParser;
const EventQueue = lib.Queue(Io.Event);
const HttpParser = lib.HttpParser;

const Request = struct {
    ref: c_int,
    lthread: Lua,
    parsed_req: HttpParser.Request,
    //if you run out of memory before finishing a request, try to complete toher request first
    //if all of them require more memory than available, it's time to kill the conection
    arena: std.heap.ArenaAllocator,
    fn deinit(req: *Request) void {
        req.arena.deinit();
    }
};

pub fn init(handle: Io.Handle, slab: std.heap.FixedBufferAllocator) !ConnectionContext {
    return .{
        .handle = handle,
        .slab = slab,
        .requests = .empty,
        .allocation_fail_count = 0,
    };
}
pub fn deinit(conn: *ConnectionContext, r: *Runtime) void {
    //return resources used back to runtime
    r.memstack.returnBuf(conn.slab);
    r.lua.unref(conn.ref);
}
pub fn startNewRequests(conn: *ConnectionContext, lua: *Lua, req: HttpParser.Request) !void {

    //if the size of request does not equal the size of the buffer, assume there are multiple request
    var total_size: usize = 0;
    while (total_size < conn.buf.items.len) {
        //TODO: Handle chunck encoding/streamed bodies of request
        //and allow seting max header size
        conn.requests.append(conn.slab, conn.newRequest(lua, req));
        total_size += request.size;
    }

    for (conn.requests.items) |req| {
        //get the relavant handler from the routing table and run the handler
        //pass the connection as a argument to the lua function
        //expect to yield unless connection finishes in one go
    }
}
fn newRequest(conn: *ConnectionContext, lua: *Lua, req: Parser.Request) !Request {
    var l = lua;
    const thread = try l.newThread();
    const ref = l.ref();
    return .{
        .parsed_req = req,
        .arena = std.heap.ArenaAllocator.init(conn.slab.allocator()),
        .ref = ref,
        .lthread = thread,
    };
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
