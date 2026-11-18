const std = @import("std");
const lib = @import("lib/lib.zig");
const zio = @import("zio");
const Lua = lib.Lua;
const Runtime = lib.Runtime;
const route = lib.Router;
const Router = route.Router(c_int, .{ .lua = true });
const parser = lib.Util.parser;
const Config = lib.Config;

var SHUTDOWN = false;

pub fn main(init: std.process.Init.Minimal) !void {
    switch (parser.parse(init.args)) {
        .command => |args| switch (args) {
            .help => |help_args| printHelp(help_args.topic),
            .run => |run_args| try run(run_args),
            .routes => |routes_args| try routes(routes_args),
            .tests => |tests_args| try tests(tests_args),
            .config => |config_args| try config(config_args),
        },
        .help => |topic| printHelp(topic),
        .invalid => std.process.exit(2),
    }
}

fn printHelp(topic: ?parser.Command) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const text = switch (topic orelse .help) {
        .help => parser.help_general,
        .run => parser.help_run,
        .routes => parser.help_routes,
        .tests => parser.help_tests,
        .config => parser.help_config,
    };
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

inline fn run(args: parser.RunArgs) !void {
    const config_path = args.config_path orelse Config.default_path;

    var conf = Config.init();
    defer conf.deinit();
    try conf.applyFile(config_path);

    if (args.main_file) |main_file| conf.main_file = main_file;
    if (args.memory) |memory| conf.memory = memory;
    if (args.max_read) |max_read| conf.max_read = max_read;
    if (args.address) |address| conf.address = address;
    if (args.single_threaded) |single_threaded| conf.single_threaded = single_threaded;
    if (args.lua_threads) |lua_threads| conf.lua_threads = lua_threads;
    if (conf.single_threaded) conf.lua_threads = 1;

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

    try runtime.initVms(conf.main_file, config_path);

    try lib.Logger.init(io, .{ .level = .TRACE });
    defer lib.Logger.Instance.deinit();

    //TODO: allow timout to be configurable
    try runtime.serve(conf.address, .fromMilliseconds(500));
}

inline fn routes(args: parser.RoutesArgs) !void {
    const config_path = args.config_path orelse Config.default_path;

    var conf = Config.init();
    defer conf.deinit();
    try conf.applyFile(config_path);
    if (args.main_file) |main_file| conf.main_file = main_file;

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

    try runtime.initVms(conf.main_file, config_path);
    defer runtime.deinit();

    try writer.interface.print("{s:<10} {s}\n", .{ "METHOD", "PATH" });
    try writer.interface.print("{s}\n", .{@as([50]u8, @splat('-'))});

    runtime.router.?.print(alloc, &writer.interface);
}

inline fn tests(args: parser.TestsArgs) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime: Runtime = try .init(alloc, io, .{});
    defer runtime.deinit();

    //TODO: test not working right now
    try runtime.runTestMode(args.test_dir orelse "test");
}

//TODO: make config file a genral setting
inline fn config(args: parser.ConfigArgs) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime: Runtime = try .init(alloc, io, .{});
    defer runtime.deinit();

    try runtime.initVms(null, args.config_path orelse Config.default_path);
    try runtime.printConfigFile();
}
