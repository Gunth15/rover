const std = @import("std");
const lib = @import("lib/lib.zig");
const Io = lib.Io;
const Lua = lib.Lua;
const HttpParser = lib.HttpParser;

const ContextPool = std.heap.MemoryPoolExtra(ConnectionContext, .{ .growable = false });
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });
const ConnectionContext = struct {
    //WARNING: Fields managed by handle_connection process
    handle: Io.Handle,
    req: HttpParser.Request,
    arena: std.heap.ArenaAllocator,
    lua: Lua,
    next: ?*ConnectionContext,

    const Messgage = union(enum) {
        io: Io.CompletionReturn,
        sql: void,
        any: *anyopaque,
    };
    pub fn rec() !void {}
    pub fn resume_ctxt(ctxt: *ConnectionContext, msg: Io.CompletionReturn) void {
        switch (msg) {
            .accept => |ret| {},
            .openat => |ret| {},
            .close => {
                //deinitialize everything
            },
            .send => |ret| {},
            .write => |ret| {},
            .read => |ret| {},
        }
    }
};

const MAXCONNECTIONS = 200;
const MAXEVENTS_PER_CONNECTION = 1;
const MAXEVENTS = MAXCONNECTIONS * MAXEVENTS_PER_CONNECTION;
var SHUTDOWN = false;

//TODO: use coroutines instead
pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks()) {
            std.debug.print("LEAKED MEMORY", .{});
        }
    }
    const alloc = debug_allocator.allocator();

    var event_pool: EventPool() = try .initPreheated(alloc, MAXEVENTS);
    defer event_pool.deinit();

    var context_pool: ContextPool = try .initPreheated(alloc, MAXCONNECTIONS);
    defer context_pool.deinit();

    var io: Io = .init(.{});
    defer io.deinit();

    const lua = try Lua.init(.{ .allocator = &alloc });
    defer lua.deinit();

    //TODO: make signalfd()
    //add read event

    //event_loop
    while (!SHUTDOWN) {
        //Flush io and try to handle immediately
        const events = try io.flush(1);
        while (events.next) |event| {
            if (event.status.complete == .accept) {
                var state: Lua = @ptrCast(@alignCast(event.context));
                var ctxt = try context_pool.create();
                ctxt.lua = try state.newThread();
            }
            var ctxt: ConnectionContext = @ptrCast(@alignCast(event.context));
            ctxt.resume_ctxt(event.status.complete);
        }

        //Flush sql buffer
        //while (events.next) |event {}

    }

    //do submit events-> consume completion handle events
}
