const std = @import("std");
const lib = @import("lib/lib.zig");
const zio = @import("zio");
const Lua = lib.Lua;
const Runtime = lib.Runtime;
const route = lib.Router;
const Router = route.Router(c_int, .{ .lua = true });
const parser = lib.Util.parser;
const Config = lib.Config;
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
    \\  tests               Runs test out of the test directory(defaults to ./test)
    \\  config              Print the current configuration
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
    \\  -m, --memory <bytes>      Limits memory allocations made by the entire process.
    \\  -c, --config <path>       Specify config file
    \\  -r, --read <bytes>        Max read buffer per connection (rounded to power of two)
    \\  -f, --file <path>         Lua script to execute
    \\  -a, --addr <addr:port>    Address to bind (e.g. 127.0.0.1:8080)
    \\  -s, --single_threaded     Runs server in single threaded mode
    \\  -l, --lua_threads         Number of threads dedicated to lua workers
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

const HELPTEST =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover tests [options]
    \\
    \\Options:
    \\  -d, --dir <dir>         Directory to look for test
    \\  -h, --help              Show this help message
    \\
;
const HELPCONFIG =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover config 
    \\
    \\Options:
    \\  -c, --config <path>       Specify config file
;

pub fn main(init: std.process.Init.Minimal) !void {
    const args = parser.parse(init.args);
    switch (args.command) {
        .help => return help(),
        .run => return run(args),
        .routes => return routes(args),
        .tests => return tests(args),
        .config => return config(args),
    }
}

inline fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    main_log.err(fmt, args);
    std.process.exit(status);
}

inline fn run(args: parser.Args) !void {
    if (args.help) {
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.File.stdout().writeStreamingAll(threaded.io(), HELPRUN) catch {};
    }

    var conf = try Config.load(args.config, .fromArgs(args));
    defer conf.deinit();

    lib.Util.ctrlC.init();

    var debug_allocator = std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
    }).init;
    if (conf.memory) |memory| debug_allocator.requested_memory_limit = memory;

    defer {
        if (debug_allocator.detectLeaks() != 0) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }

    const alloc = debug_allocator.allocator();

    var threaded = if (conf.single_threaded) std.Io.Threaded.init_single_threaded else std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime: Runtime = try .init(alloc, io, .{
        .max_read = conf.max_read,
        .lvm_opts = .{
            .vm_count = conf.lua_threads,
            .is_concurrency = !conf.single_threaded,
        },
    });
    defer runtime.deinit();

    try runtime.initVms(conf.main_file, args.config);

    try lib.Logger.init(io, .{ .level = .TRACE });
    defer lib.Logger.Instance.deinit();

    //TODO: allow timout to be configurable
    try runtime.serve(conf.address, .fromMilliseconds(500));
}

inline fn help() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    std.Io.File.stdout().writeStreamingAll(io, HELP) catch {};
    return;
}

inline fn routes(args: parser.Args) !void {
    if (args.help) {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.File.stdout().writeStreamingAll(io, HELPROUTES) catch {};
    }

    var conf = try Config.load(args.config, .fromArgs(args));
    defer conf.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buff: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buff);
    defer writer.flush() catch {};

    var runtime: Runtime = try .init(alloc, io, .{});

    try runtime.initVms(conf.main_file, args.config);
    defer runtime.deinit();

    try writer.interface.print("{s:<10} {s}\n", .{ "METHOD", "PATH" });
    try writer.interface.print("{s}\n", .{@as([50]u8, @splat('-'))});

    runtime.router.?.print(alloc, &writer.interface);
}

inline fn tests(args: parser.Args) !void {
    if (args.help) {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.File.stdout().writePositionalAll(io, HELPTEST, 0) catch {};
    }

    var conf = try Config.load(args.config, .fromArgs(args));
    defer conf.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime: Runtime = try .init(alloc, io, .{});
    defer runtime.deinit();

    //TODO: test file needs to be converted in conf
    //TODO: test not working right now
    try runtime.runTestMode("test");
}

//TODO: make config file a genral setting
inline fn config(args: parser.Args) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (args.help) std.Io.File.stdout().writePositionalAll(io, HELPCONFIG, 0) catch {};

    var runtime: Runtime = try .init(alloc, io, .{});
    defer runtime.deinit();

    try runtime.initVms(null, args.config);
    try runtime.printConfigFile();
}
