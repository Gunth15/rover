const std = @import("std");
const lib = @import("lib/lib.zig");
const Io = lib.Io;
const HttpParser = lib.HttpParser;
const Ring = lib.Ring(Io.Event, .{});
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });

const MAXCONNECTIONS = 200;
const MAXEVENTS_PER_CONNECTION = 2;
const MAXEVENTS = MAXCONNECTIONS + MAXCONNECTIONS * MAXEVENTS_PER_CONNECTION;

const ConnectionContext = struct {
    //WARNING: Fields managed by handle_connection process
    handle: Io.Handle,
    req: HttpParser.Request,
    arena: std.heap.ArenaAllocator,
    lua: @compileError("TODO: add lua coroutine here"),

    //NOTE: handle_connection is treated as a separate process.
    //The state is treated as the message passed to the handle_connection process that tells it to continue operations on the connection.
    pub fn handle_connection(ctxt: *ConnectionContext, state: Io.CompletionReturn) void {
        switch (state) {
            .accept => |ret| {},
            .openat => |ret|{},
            .close => {
                //deinitialize everything
            },
            .send => |ret|{},
            .write => |ret| {},
            .read => |ret|{},
        }
    }
};

const ContextPool = std.heap.MemoryPoolExtra(ConnectionContext, .{ .growable = false });
const EventPool = std.heap.MemoryPoolExtra(Io.Event, .{ .growable = false });


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

    const events = try alloc.alloc(*Io.Event, MAXEVENTS);
    defer alloc.free(events);

    var io: Io = .init(.{});
    defer io.deinit();

    //event_loop
    switch () {
    }
    //  accept -> create new context and start new coroutine(stackless)
    //  else -> change context status and resume relevent coroutine

    io.flush(events);

    //do submit events-> consume completion handle events
}

