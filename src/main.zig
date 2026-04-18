const std = @import("std");
const lib = @import("lib/lib.zig");
const Lua = @import("lib/lib.zig").Lua;
const Future = @import("Future.zig");
const Runtime = @import("Runtime.zig");
const main_log = @import("std").log.scoped(.start_up);

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
    \\Usage: rover run [options]
    \\
    \\Options:
    \\ -c, --connections    Specify Maximum number of connections
    \\ -m, --memory         Specify Maximum extra memory for a single connection
    \\ -i, --io             The amount of I/O related events expected 
    \\ -r, --read           Max read buffer size per connection
    \\ -w, --write          Max write buffer size per connection
    \\ -f, --file <file>    Specify the Lua file to use
    \\ -h, --help           Print the help screen for the run command
    \\
;

pub fn fatal(comptime fmt: []const u8, args: anytype, status: u8) noreturn {
    main_log.err(fmt, args);
    std.process.exit(status);
}

const Args = struct {
    command: enum { run, help } = .help,
    file: [:0]const u8 = "main.lua",
    help: bool = false,
    connections: usize = 500,
    io: usize = 600,
    read: usize = 4096,
    write: usize = 4096,
    memory: usize = 1024,
};
pub fn parse() Args {
    var args: Args = .{};
    var iter = std.process.args();
    _ = iter.next();
    const command = iter.next() orelse return args;
    if (std.mem.eql(u8, "help", command)) args.command = .help else if (std.mem.eql(u8, "run", command)) args.command = .run else {
        main_log.err("Unknown command: {s}\n", .{command});
        return args;
    }

    while (iter.next()) |arg| {
        const flag = std.mem.sliceTo(arg, 0);
        switch (args.command) {
            .help => {},
            .run => {
                if (std.mem.eql(u8, flag, "-f") or std.mem.eql(u8, flag, "--file")) args.file = iter.next() orelse {
                    main_log.err("No file specified\n", .{});
                    args.help = true;
                    return args;
                } else {
                    args.help = true;
                    main_log.err("Unknown argument {s}", .{flag});
                }
            },
        }
    }
    return args;
}

pub fn main() !void {
    const args = parse();
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer {
        if (debug_allocator.detectLeaks()) {
            std.debug.print("LEAKED MEMORY\n", .{});
        }
    }

    if (args.command == .help) {
        _ = std.fs.File.stdout().write(HELP) catch {};
        return;
    }
    if (args.command == .run and args.help) {
        _ = std.fs.File.stdout().write(HELPRUN) catch {};
        return;
    }
    const alloc = debug_allocator.allocator();
    const file = args.file;

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
