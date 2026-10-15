const std = @import("std");
const parser_log = @import("std").log.scoped(.parser);

pub const Args = struct {
    command: enum {
        run,
        help,
        routes,
        tests,
        config,
    } = .help,
    file: [:0]const u8 = "main.lua",
    config: [:0]const u8 = "config.lua",
    help: bool = false,
    connections: ?usize = null,
    read: usize = 4096,
    memory: ?usize = null,
    addr: std.Io.net.IpAddress = std.Io.net.IpAddress.parse("127.0.0.1", 8080) catch .{},
    single_threaded: bool = false,
    lua_threads: usize,
};
pub fn parse(cargs: std.process.Args) Args {
    var args: Args = .{
        .lua_threads = std.Thread.getCpuCount() catch 1,
    };

    var iter = cargs.iterate();
    _ = iter.next();
    const command = iter.next() orelse return args;
    if (std.mem.eql(u8, "help", command)) {
        args.command = .help;
    } else if (std.mem.eql(u8, "run", command)) {
        args.command = .run;
    } else if (std.mem.eql(u8, "routes", command)) {
        args.command = .routes;
    } else if (std.mem.eql(u8, "tests", command)) {
        args.command = .tests;
        args.file = "tests";
    } else if (std.mem.eql(u8, "config", command)) {
        args.command = .config;
    } else {
        parser_log.err("Unknown command: {s}\n", .{command});
        return args;
    }

    while (iter.next()) |arg| {
        const flag = std.mem.sliceTo(arg, 0);
        switch (args.command) {
            .help => {},
            .run => {
                if (isarg(flag, "-f", "--file")) args.file = iter.next() orelse {
                    return parseErr(args, "No file specified\n", .{});
                } else if (isarg(flag, "-c", "--config")) {
                    return parseErr(args, "No config specified\n", .{});
                } else if (isarg(flag, "-m", "--memory")) {
                    const memory = iter.next() orelse return parseErr(args, "Extra memory not specified\n", .{});
                    args.memory = std.fmt.parseInt(usize, memory, 0) catch return parseErr(args, "{s} is not a unsigned integer\n", .{memory});
                } else if (isarg(flag, "-r", "--read")) {
                    const read = iter.next() orelse return parseErr(args, "Read buffer size not specified\n", .{});
                    args.read = std.fmt.parseInt(usize, read, 0) catch return parseErr(args, "{s} is not a unsigned integer\n", .{read});
                } else if (isarg(flag, "-a", "--addr")) {
                    const addr = iter.next() orelse return parseErr(args, "No address provided\n", .{});
                    args.addr = std.Io.net.IpAddress.parseLiteral(addr) catch return parseErr(args, "{s} is not a valid address\n", .{addr});
                } else if (isarg(flag, "-h", "--help")) {
                    args.help = true;
                } else if (isarg(flag, "-s", "--single_threaded")) {
                    args.single_threaded = true;
                } else if (isarg(flag, "-l", "--lua_threads")) {
                    const thread_count = iter.next() orelse return parseErr(args, "Number of lua threads not specified\n", .{});
                    args.lua_threads = std.fmt.parseInt(usize, thread_count, 0) catch return parseErr(args, "{s} is not a unsigned integer\n", .{thread_count});
                } else return parseErr(args, "Unknown argument {s}", .{flag});
            },
            .routes => {
                if (isarg(flag, "-f", "--file")) args.file = iter.next() orelse {
                    return parseErr(args, "No file specified\n", .{});
                } else if (isarg(flag, "-h", "--help")) {
                    args.help = true;
                } else return parseErr(args, "Unknown argument {s}", .{flag});
            },
            .tests => {
                if (isarg(flag, "-d", "--dir")) args.file = iter.next() orelse {
                    return parseErr(args, "No directory specified\n", .{});
                } else if (isarg(flag, "-h", "--help")) {
                    args.help = true;
                } else return parseErr(args, "Unknown argument {s}", .{flag});
            },
            .config => {
                if (isarg(flag, "-c", "--config")) {
                    return parseErr(args, "No config specified\n", .{});
                }
            },
        }
    }
    return args;
}
inline fn isarg(flag: [:0]const u8, short: [:0]const u8, long: [:0]const u8) bool {
    return std.mem.eql(u8, flag, short) or std.mem.eql(u8, flag, long);
}
inline fn parseErr(args: Args, comptime fmt: []const u8, fmt_args: anytype) Args {
    parser_log.err(fmt, fmt_args);
    var a = args;
    a.help = true;
    return a;
}
