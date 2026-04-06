const std = @import("std");
const lib = @import("lib/lib.zig");
const Runtime = @import("Runtime.zig");

const MAXCONNECTIONS = 200;
const MAXMEMORY = 4096 * 5;
const MAXEVENTS = MAXCONNECTIONS * 4;
const TOTALHEADERS = 10;
var SHUTDOWN = false;

//TODO: use coroutines instead
pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks()) {
            std.debug.print("LEAKED MEMORY", .{});
        }
    }
    var alloc = debug_allocator.allocator();

    var runtime: Runtime = .init(&alloc,MAXCONNECTIONS, MAXEVENTS, MAXMEMORY);

    runtime.lua.openLibs();

    //load main file(allow user to define path to file)
    //run rover.load function
    //save global to be shared between threads

    //TODO: make signalfd()
    //add read event

    //event_loop
    while (!SHUTDOWN) {
        //Flush io and try to handle immediately
        const event_queue = try io.flush(1);
        while (event_queue.dequeue()) |event| {
            switch (event.status.complete) {
                .accept => |ret| {
                    var state: *Lua = @ptrCast(@alignCast(event.context));
                    //most of this can be moved to a method
                    var ctxt = try context_pool.create();
                    ctxt.handle = try ret;
                    ctxt.lua = try state.newThread();
                    ctxt.ref = lua.ref();
                    ctxt.arena = try std.heap.ArenaAllocator.init(alloc);
                    ctxt.read_buf = ctxt.arena.allocator().alloc(u8, BUFFSIZE);
                    ctxt.events = 1;

                    event.* = .read(ctxt, ctxt.handle, ctxt.buf, 0);
                    try io.submit(event);
                },
                .read => |ret| {
                    var ctxt: *ConnectionContext = @ptrCast(@alignCast(event.context));
                    const read = try ret;
                    ctxt.req = try HttpParser.parse(ctxt.buf[0..read], ctxt.arena, TOTALHEADERS, 0);
                    //TODO: think about how I can differentiate start connection read  and a read in a connection
                    ctxt.startThread();
                    //make new ref
                },
                .send => |ret| {
                    //send would be pushed when the lua function finishes
                    var ctxt: *ConnectionContext = @ptrCast(@alignCast(event.context));
                    const sent = try ret;
                    if (ctxt.send_buf.len > sent) {
                        ctxt.sent += sent;
                        event.* = .send(ctxt, ctxt.handle, ctxt.send_buf[ctxt.sent..], .{});
                        try io.submit(event);
                    } else {
                        event.* = .close(ctxt, ctxt.handle);
                        try io.submit(event);
                    }
                },
                .close => {
                    var ctxt: *ConnectionContext = @ptrCast(@alignCast(event.context));
                    ctxt.arena.deinit();
                    lua.unref(ctxt.ref);
                },
            }
        }

        //Flush sql buffer
        //while (events.next) |event {}

    }
}

const readcb = struct {
    handle: Io.Handle,
    buf: []u8,
    lbuf: *Lua.LuaBuffer,
    fn wake(f: *Future, lua: *Lua, ctxt: *anyopaque) void {
        const r: *readcb = @ptrCast(@alignCast(f.ptr));
        lua.

    }
    fn toFuture() Future {}
};
fn startRead(l: *Lua) Future {
    const args = l.getTop();
    if (args >= 2) l.fmtError("Expected 2 or more arguments %i where given", .{args});

    const handle = try l.to(Io.Handle, 1);
    const offset = try l.to(Io.OpenOptions, 2);
    const bufsize: usize = if (args == 3) l.to(usize, 3) else 4096;

    //initialize to build return string
    var r = try l.newUserData(readcb);
    try l.initBuf(r.lbuf);
    read.buf = l.newUserDataRaw(bufsize);


    //create event

    return .{
        .ptr = r,
        .vtable = .{
            .wake = readcb.wake,
        },
    };
}
fn finishRead(l: *Lua) Future {
    const args = l.getTop();
    if (args >= 2) l.fmtError("Expected 2 or more arguments %i where given", .{args});

    const handle = try l.to(Io.Handle, 1);
    const offset = try l.to(Io.OpenOptions, 2);
    const bufsize: usize = if (args == 3) l.to(usize, 3) else 4096;

    //initialize to build return string
    var r = try l.newUserData(readcb);
    try l.initBuf(r.lbuf);
    read.buf = l.newUserDataRaw(bufsize);


    //create event

    return .{
        .ptr = r,
        .vtable = .{
            .wake = readcb.wake,
        },
    };
}
