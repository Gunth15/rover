const std = @import("std");
const lib = @import("lib/lib.zig");
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");

const MAXCONNECTIONS = 200;
const MAXMEMORY = 4096 * 5;
const MAXEVENTS = MAXCONNECTIONS * 4;
const TOTALHEADERS = 10;
const READSIZE = 1024;
const MAXREADSIZE = 4096;
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var runtime: Runtime = .init(&alloc, addr, MAXCONNECTIONS, MAXEVENTS, MAXMEMORY, READSIZE, MAXREADSIZE);

    //load main file(allow user to define path to file)
    //run rover.load function
    //save global to be shared between threads

    //TODO: make signalfd()
    //add read event

    while (!SHUTDOWN) {
        //Flush io and try to handle immediately
        const event_queue = try runtime.io.flush(1);
        while (event_queue.dequeue()) |event| {
            const future: Future = @ptrCast(event.context);
            //TODO: handle state
            _ = future.wake(runtime);
        }
    }
}
