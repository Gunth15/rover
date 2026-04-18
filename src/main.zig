const std = @import("std");
const lib = @import("lib/lib.zig");
const Lua = @import("lib/lib.zig").Lua;
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");
const parser = @import("parser.zig");
const main_log = @import("std").log.scoped(.start_up);

var SHUTDOWN = false;

const HELP =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage: rover <command> [options]
    \\
    \\Commands:
    \\  run                 Runs a Lua program(defaults to main.lua)
    \\  help                Show all commands
;
const HELPRUN =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover run [options]
    \\
    \\Options:
    \\  -c, --connections <n>     Max number of concurrent connections
    \\  -m, --memory <bytes>      Per-connection memory (non-Lua). Excludes I/O buffers.
    \\                            Crashes on overflow.
    \\  -i, --io <n>              Expected I/O events (rounded to next power of two)
    \\  -r, --read <bytes>        Max read buffer per connection (rounded to power of two)
    \\  -w, --write <bytes>       Max write buffer per connection (rounded to power of two)
    \\  -f, --file <path>         Lua script to execute
    \\  -a, --addr <addr:port>    Address to bind (e.g. 127.0.0.1:8080)
    \\  -h, --help                Show this help message
    \\
;

inline fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    main_log.err(fmt, args);
    std.process.exit(status);
}

inline fn run(args: parser.Args) !void {
    if (args.help) {
        _ = std.fs.File.stdout().write(HELPRUN) catch {};
        return;
    }

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks()) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }
    const alloc = debug_allocator.allocator();
    const file = args.file;

    var runtime: Runtime = try .init(
        &alloc,
        args.connections,
        args.io,
        args.memory,
        args.read,
        args.write,
    );
    defer runtime.deinit();

    //load main file(allow user to define path to file)
    runtime.lua.newTable();
    runtime.lua.setGlobal("rover");
    runtime.lua.loadFile(file) catch {
        const err = try runtime.lua.to(Lua.String, -1);
        fatal("Error loading main.lua({s}): {s}", .{ file, err }, 1);
    };
    runtime.lua.pcall(0, 0) catch {
        const err = try runtime.lua.to(Lua.String, -1);
        fatal("Error initializing main.lua({s}): {s}", .{ file, err }, 1);
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

    //run rover.load function
    //save global to be shared between threads

    //TODO: make signalfd()
    //add read event

    try runtime.serve(args.addr, args.connections);
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
inline fn help() !void {
    _ = std.fs.File.stdout().write(HELP) catch {};
    return;
}

pub fn main() !void {
    const args = parser.parse();
    switch (args.command) {
        .help => help(),
        .run => run(args),
    }
}
