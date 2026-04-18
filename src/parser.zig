const std = @import("std");
const parser_log = @import("std").log.scoped(.parser);

pub const Args = struct {
    command: enum { run, help } = .help,
    file: [:0]const u8 = "main.lua",
    help: bool = false,
    connections: usize = 500,
    io: usize = 600,
    read: usize = 4096,
    write: usize = 4096,
    memory: usize = 1024,
    addr: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080),
};
pub fn parse() Args {
    var args: Args = .{};
    var iter = std.process.args();
    _ = iter.next();
    const command = iter.next() orelse return args;
    if (std.mem.eql(u8, "help", command)) args.command = .help else if (std.mem.eql(u8, "run", command)) args.command = .run else {
        parser_log.err("Unknown command: {s}\n", .{command});
        return args;
    }

    while (iter.next()) |arg| {
        const flag = std.mem.sliceTo(arg, 0);
        switch (args.command) {
            .help => {},
            .run => {
                if (isarg(flag, "-f", "--file")) args.file = iter.next() orelse {
                    return parseErr("No file specified\n", .{});
                } else if (isarg(flag, "-c", "--connections")) {
                    const connections = iter.next() orelse return parseErr("Max concurrent connections not specified\n", .{});
                    args.connections = std.fmt.parseInt(usize, connections, 10) catch return parseErr("{s} is not a unsigned integer\n", .{connections});
                } else if (isarg(flag, "-m", "--memory")) {
                    const memory = iter.next() orelse return parseErr("Extra memory not specified\n", .{});
                    args.memory = std.fmt.parseInt(usize, memory, 10) catch return parseErr("{s} is not a unsigned integer\n", .{memory});
                } else if (isarg(flag, "-i", "--io")) {
                    const io = iter.next() orelse return parseErr("Io events number not specified\n", .{});
                    args.io = std.fmt.parseInt(usize, io, 10) catch return parseErr("{s} is not a unsigned integer\n", .{io});
                } else if (isarg(flag, "-r", "--read")) {
                    const read = iter.next() orelse return parseErr("Read buffer size not specified\n", .{});
                    args.read = std.fmt.parseInt(usize, read, 10) catch return parseErr("{s} is not a unsigned integer\n", .{read});
                } else if (isarg(flag, "-w", "--write")) {
                    const write = iter.next() orelse return parseErr("Write buffer size not specified\n", .{});
                    args.write = std.fmt.parseInt(usize, write, 10) catch return parseErr("{s} is not a unsigned integer\n", .{write});
                } else if (isarg(flag, "-a", "--addr")) {
                    const addr = iter.next() orelse return parseErr("No address provided\n", .{});
                    args.addr = std.net.Address.parseIpAndPort(addr) catch return parseErr("{s} is not a valid address\n", .{addr});
                } else return parseErr("Unknown argument {s}", .{flag});
            },
        }
    }
    return args;
}
inline fn isarg(flag: [:0]const u8, short: [:0]const u8, long: [:0]const u8) bool {
    return std.mem.eql(u8, flag, short) or std.mem.eql(u8, flag, long);
}
inline fn parseErr(args: Args, comptime fmt: []const u8, fmt_args: anytype) Args {
    parser_log.err(fmt, .{fmt_args});
    args.help = true;
    return args;
}
