const std = @import("std");
const lib = @import("lib/lib.zig");
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");

const MAXCONNECTIONS = 64;
const MAXMEMORY = 4096 * 5;
const MAXEVENTS = MAXCONNECTIONS * 2;
const TOTALHEADERS = 10;
const READSIZE = 1024;
const MAXREADSIZE = 4096;
var SHUTDOWN = false;

const HELP =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage: All-in-one system for making speedy web apps in Lua
    \\
    \\Commands:
    \\  Run         Runs your lua program. Assumes main.lua if file not specified
    \\Options:
    \\  -f, -file   Specify which file to use
    \\
;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks()) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }
    const alloc = debug_allocator.allocator();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var runtime: Runtime = try .init(
        &alloc,
        MAXCONNECTIONS,
        MAXEVENTS,
        MAXMEMORY,
        READSIZE,
        MAXREADSIZE,
    );
    defer runtime.deinit();

    //load main file(allow user to define path to file)
    runtime.lua.newTable();
    runtime.lua.setGlobal("rover");
    try runtime.lua.loadFile("./examples/simple/main.lua");
    _ = try runtime.lua.pcall(0, 0);

    if (runtime.lua.getGlobal("rover") != .table) @panic("rover could not be found");
    if (runtime.lua.getField(-1, "routes") != .func) @panic("rover.routes is not a function");

    runtime.lua.pcall(0, 1);
    //TODO:: check type too
    runtime.lua.setGlobal("rover.rouing_table");

    //run rover.load function
    //save global to be shared between threads

    //TODO: make signalfd()
    //add read event

    try runtime.serve(addr, MAXCONNECTIONS);
    while (!SHUTDOWN) {
        //Flush io and try to handle immediately
        var event_queue = try runtime.io.flush(1);
        while (event_queue.dequeue()) |event| {
            var future: *Future = @ptrCast(@alignCast(event.context));
            //TODO: handle state
            _ = future.wake(&runtime);
        }
    }
}
