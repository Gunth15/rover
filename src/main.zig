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
    \\  run                 Runs a Lua program(defaults to main.lua)
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

inline fn startRuntime(args: parser.Args) Runtime {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks() != 0) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }

    const alloc = debug_allocator.allocator();

    const rt = try zio.Runtime.init(alloc, .{
        .thread_pool = .{
            .max_threads = 1,
        },
    });
    defer rt.deinit();
    const io = rt.io();
    if (args.help) {
        std.Io.File.stdout().writeStreamingAll(io, HELPRUN) catch {};
        return;
    }

    var runtime: Runtime = try .init(
        &alloc,
        io,
        args.read,
        args.write,
    );

    runtime.lua.openLibs();
    runtime.openLibRover();
    runtime.loadMain(args.file);

    //TODO: get user defined error handler
    runtime.buildRouter();
    runtime.runLoadFunc();

    return runtime;
}

inline fn run(args: parser.Args) !void {
    var runtime = startRuntime(args);
    defer runtime.deinit();

    runtime.lua.openLibs();
    runtime.openLibRover();
    runtime.loadMain(args.file);
    //TODO: get user defined error handler
    runtime.buildRouter();
    runtime.runLoadFunc();

    //TODO: make signalfd()
    try runtime.serve(args.addr);
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

    var runtime: Runtime = undefined;
    runtime.lua = Lua.init(.{}) catch fatal("Fatal: Could not initialize lua", .{}, 1);
    runtime.loadMain(args.file);
    runtime.lua.openLibs();
    runtime.buildRouter(alloc);

    try writer.interface.print("{s:<10} {s}\n", .{ "METHOD", "PATH" });
    try writer.interface.print("{s}\n", .{"─" ** 50});

    print(&runtime.router.root, alloc, &writer.interface);
}
fn print(node: *Router.RNode, alloc: std.mem.Allocator, writer: *std.Io.Writer) void {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(alloc);

    printNode(node, &builder, alloc, writer);
}
fn printNode(node: *Router.RNode, builder: *std.ArrayList(u8), alloc: std.mem.Allocator, writer: *std.Io.Writer) void {
    builder.appendSlice(alloc, node.path.slice()) catch {};
    defer builder.items.len -= node.path.len();

    var it = node.handles.iterator();
    while (it.next()) |entry| {
        const method = entry.key_ptr.*;
        const method_col = switch (method) {
            .GET => "\x1b[32m",
            .POST => "\x1b[33m",
            .PUT => "\x1b[34m",
            .PATCH => "\x1b[36m",
            .DELETE => "\x1b[31m",
        };
        const path_col = switch (node.path) {
            .named => "\x1b[33m",
            .catch_all => "\x1b[35m",
            else => "",
        };
        writer.print("{s}{s:<10}\x1b[0m {s}{s}\x1b[0m\n", .{
            method_col, @tagName(method),
            path_col,   builder.items,
        }) catch unreachable;
    }
    for (node.children.items) |child| {
        printNode(child, builder, alloc, writer);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = parser.parse(init.args);
    switch (args.command) {
        .help => return help(),
        .run => return run(args),
        .routes => return routes(args),
    }
}
