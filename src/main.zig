const std = @import("std");
const lib = @import("lib/lib.zig");
const Lua = @import("lib/lib.zig").Lua;
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");
const route = lib.Router;
const Router = route.Router(Lua.Function);
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
    \\  routes              Displays all routes
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

    var runtime: Runtime = try .init(
        &alloc,
        args.connections,
        args.io,
        args.memory,
        args.read,
        args.write,
    );
    defer runtime.deinit();

    runtime.lua.openLibs();
    runtime.loadMain(args.file);
    //TODO: get user defined error handler
    runtime.buildRouter(alloc);
    runtime.runLoadFunc();

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

inline fn routes(args: parser.Args) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.fs.File.stdout();
    var writer = stdout.writer(try alloc.alloc(u8, 4096));
    defer writer.end() catch {};

    if (args.help) {
        _ = writer.interface.write(HELPROUTES) catch {};
        return;
    }

    var runtime: Runtime = undefined;
    runtime.lua = Lua.init(.{}) catch fatal("Fatal: Could not initialize lua", .{}, 1);
    runtime.loadMain(args.file);
    runtime.lua.openLibs();
    runtime.buildRouter(alloc);

    try writer.interface.print("\n{s:<10} {s}\n", .{ "METHOD", "PATH" });
    try writer.interface.print("{s}\n", .{"─" ** 50});

    print(&runtime.router.root, alloc, &writer.interface);
}
fn print(node: *Router.RNode, alloc: std.mem.Allocator, writer: *std.io.Writer) void {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(alloc);

    printNode(node, &builder, alloc, writer);
}
fn printNode(node: *Router.RNode, builder: *std.ArrayList(u8), alloc: std.mem.Allocator, writer: *std.io.Writer) void {
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

pub fn main() !void {
    const args = parser.parse();
    switch (args.command) {
        .help => return help(),
        .run => return run(args),
        .routes => return routes(args),
    }
}
