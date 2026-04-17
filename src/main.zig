const std = @import("std");
const log = @import("std").log;
const lib = @import("lib/lib.zig");
const Lua = @import("lib/lib.zig").Lua;
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");

const MAXCONNECTIONS = 1;
const MAXMEMORY = 4096 * 3;
const MAXEVENTS = MAXCONNECTIONS * 2;
const TOTALHEADERS = 10;
const MAXREAD = 4096;
const MAXWRITE = 4096;
var SHUTDOWN = false;

const HELP =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage: All-in-one framework for making speedy web apps in Lua
    \\
    \\Commands:
    \\  run         Runs your lua program. Assumes main.lua if file not specified
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
        MAXREAD,
        MAXWRITE,
    );
    defer runtime.deinit();

    //load main file(allow user to define path to file)
    runtime.lua.newTable();
    runtime.lua.setGlobal("rover");
    try runtime.lua.loadFile("./examples/simple/main.lua");
    runtime.lua.pcall(0, 0) catch |e| {
        if (e == lib.Lua.CallError.RuntimeError) {
            const err = try runtime.lua.to(Lua.String, -1);
            std.debug.print("Runtime error: {s}\n", .{err});
        }
        return e;
    };

    //rover.routing_table = rover.routes()
    if (runtime.lua.getGlobal("rover") != .table) @panic("rover could not be found");
    if (runtime.lua.getField(-1, "routes") != .func) @panic("rover.routes is not a function");
    runtime.lua.pcall(0, 1) catch |e| {
        if (e == lib.Lua.CallError.RuntimeError) {
            const err = try runtime.lua.to(Lua.String, -1);
            std.debug.print("Runtime error: {s}\n", .{err});
        }
        std.debug.print("Unrecoverable Error: {any}\n", .{e});
        @panic("Unrecoverable state");
    };
    runtime.lua.setField(-2, "routing_table");
    runtime.lua.pop(1);

    const t = runtime.lua.getRawI(Lua.RegistryIndex, Lua.RegistryIndexMainThread);
    std.debug.print("registry type: {s}\n", .{@tagName(t)});

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
