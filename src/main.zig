const std = @import("std");
const lib = @import("lib/lib.zig");
const zio = @import("zio");
const Lua = lib.Lua;
const Runtime = lib.Runtime;
const route = lib.Router;
const Router = route.Router(c_int, .{ .lua = true });
const parser = lib.Util.parser;
const main_log = @import("std").log.scoped(.start_up);

var SHUTDOWN = false;

const HELP =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage: rover <command> [options]
    \\
    \\Commands:
    \\  run                 Runs a Rover program(defaults to main.lua)
    \\  help                Show all commands
    \\  routes              Displays all routes
    \\
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
const HELPROUTES =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover routes [options]
    \\
    \\Options:
    \\  -f, --file <path>         Lua script to execute
    \\  -h, --help                Show this help message
    \\
;

inline fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    main_log.err(fmt, args);
    std.process.exit(status);
}

inline fn run(args: parser.Args) !void {
    lib.Util.ctrlC.init();

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks() != 0) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }

    const alloc = debug_allocator.allocator();

    //TODO: allow swapable io implementation for portability and versatility
    //const rt = try zio.Runtime.init(alloc, .{
    //    .thread_pool = .{
    //        .max_threads = 1,
    //},
    //});
    //defer rt.deinit();
    //const io = rt.io();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (args.help) {
        std.Io.File.stdout().writeStreamingAll(io, HELPRUN) catch {};
    }

    var runtime: Runtime = try .init(
        &alloc,
        io,
        args.read,
        args.write,
        //TODO: Make queue_size an argument
        250,
    );
    defer runtime.deinit();
    try runtime.initVm();

    runtime.lvm.state.openLibs();
    runtime.openLibRover();
    runtime.loadMain(args.file);

    //TODO: get user defined error handler
    runtime.buildRouter();
    const not_found_func = runtime.runOnNotFoundFunc();
    runtime.router.?.not_found_handler = not_found_func;
    runtime.router.?.invalid_method_handler = not_found_func;
    runtime.runLoadFunc();

    var fut = try runtime.lvm.start(io);
    errdefer fut.cancel(io);

    try runtime.serve(args.addr);
    fut.await(io);
}

inline fn help() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();

    std.Io.File.stdout().writeStreamingAll(io, HELP) catch {};
    return;
}

inline fn routes(args: parser.Args) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    const io = threaded.io();

    var writer = std.Io.File.stdout().writer(io, try alloc.alloc(u8, 4096));
    defer writer.flush() catch {};

    if (args.help) {
        _ = writer.interface.write(HELPROUTES) catch {};
        return;
    }

    var runtime: Runtime = try .init(&alloc, io, 0, 0, 0);
    runtime.lvm.state.openLibs();
    runtime.openLibRover();
    runtime.loadMain(args.file);
    runtime.buildRouter();

    try writer.interface.print("{s:<10} {s}\n", .{ "METHOD", "PATH" });
    try writer.interface.print("{s}\n", .{"─" ** 50});

    runtime.router.?.print(alloc, &writer.interface);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = parser.parse(init.args);
    switch (args.command) {
        .help => return help(),
        .run => return run(args),
        .routes => return routes(args),
    }
}
