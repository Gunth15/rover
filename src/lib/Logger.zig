const std = @import("std");
const lib = @import("lib.zig");
const Io = std.Io;
const builtin = @import("builtin");

level: Level,
log_queue: Io.Queue(u8),
//WARNING: Might be better to pass interface instead of having a dupliate instance of the interface, but this is negligable for now
io: std.Io,
file: ?std.Io.File,
console: ?std.Io.File,
fut: ?Io.Future(void),

pub var Instance: @This() = undefined;

const Level = enum(u8) {
    TRACE = 0,
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5,
};
const Header = struct {
    level: Level,
    payload_size: usize,
};

const Options = struct {
    level: Level = .DEBUG,
    console: bool = true,
    file: ?[]const u8 = null,
};
pub fn init(io: Io, opts: Options) !void {
    Instance = .{
        .io = io,
        .level = opts.level,
        .log_queue = undefined,
        .console = if (opts.console) Io.File.stderr() else null,
        .file = if (opts.file) |abs_path| try Io.Dir.createFileAbsolute(io, abs_path, .{}) else null,
        .fut = undefined,
    };
    Instance.fut = io.concurrent(main, .{&Instance}) catch null;
    //TODO: add synchronization flag instead of sleep loop
    try io.sleep(.fromMilliseconds(50), .awake);
}
pub fn log(self: *@This(), level: Level, desc: []const u8, args: anytype) void {
    if (@as(u8, @intFromEnum(self.level)) > @as(u8, @intFromEnum(level))) return;
    var buffer: [4096]u8 align(@alignOf(Header)) = undefined;
    const header: *Header = @ptrCast(@alignCast(buffer[0..@sizeOf(Header)]));
    var writer = Io.Writer.fixed(buffer[@sizeOf(Header)..]);
    fmtLog(level, .now(self.io, .real), &writer, desc, args) catch @panic("Log message too long");
    const written = writer.buffered();

    header.* = Header{
        .level = level,
        .payload_size = written.len,
    };
    if (self.fut) |_|
        self.log_queue.putAll(self.io, buffer[0 .. @sizeOf(Header) + written.len]) catch {}
    else
        self.writeSync(written) catch {};
}

fn main(self: *@This()) void {
    var log_queue_buff: [4096 * 3]u8 = undefined;
    self.log_queue = .init(&log_queue_buff);

    var buff: [4096]u8 align(@alignOf(Header)) = undefined;
    while (!lib.Util.ctrlC.isPressed()) {
        const h_size = self.log_queue.get(self.io, buff[0..@sizeOf(Header)], @sizeOf(Header)) catch break;
        const header: *Header = @ptrCast(@alignCast(buff[0..@sizeOf(Header)]));
        std.debug.assert(h_size == @sizeOf(Header));

        const written = self.log_queue.get(self.io, buff[@sizeOf(Header) .. @sizeOf(Header) + header.payload_size], header.payload_size) catch break;
        std.debug.assert(written == header.payload_size);

        const writable = buff[@sizeOf(Header) .. @sizeOf(Header) + written];
        self.writeSync(writable) catch {};
    }
}
pub fn deinit(self: *@This()) void {
    if (self.fut) |*fut| fut.cancel(self.io);
    if (self.console) |console| console.close(self.io);
    if (self.file) |log_file| log_file.close(self.io);
    self.log_queue.close(self.io);
}
fn writeSync(self: *@This(), buff: []const u8) !void {
    var file_buff: [4096]u8 = undefined;
    var console_buff: [4096]u8 = undefined;
    const file_writer = if (self.file) |file| file.writer(self.io, &file_buff) else null;
    const console_writer = if (self.console) |console| console.writer(self.io, &console_buff) else null;
    if (file_writer) |*w| {
        defer @constCast(w).flush() catch if (console_writer) |cw| fmtLog(.ERROR, .now(self.io, .real), @constCast(&cw.interface), @errorName(w.err.?), .{}) catch {};
        @constCast(w).interface.writeAll(buff) catch if (console_writer) |cw| fmtLog(.ERROR, .now(self.io, .real), @constCast(&cw.interface), @errorName(w.err.?), .{}) catch {};
    }
    if (console_writer) |*w| {
        defer @constCast(w).flush() catch {};
        @constCast(w).interface.writeAll(buff) catch {};
    }
}
fn fmtLog(level: Level, timestamp: Io.Timestamp, w: *Io.Writer, desc: []const u8, args: anytype) !void {
    const level_fmt = switch (level) {
        .TRACE => "\x1b[1;105m\x1b[1:37m" ++ " TRACE " ++ "\x1b[0;40m\x1b[0;37m",
        .DEBUG => "\x1b[2;106m\x1b[1:37m" ++ " DEBUG " ++ "\x1b[0;40m\x1b[0;37m",
        .INFO => "\x1b[2;102m\x1b[1:37m" ++ " INFO  " ++ "\x1b[0;40m\x1b[0;37m",
        .WARN => "\x1b[1;103m\x1b[3:30m" ++ " WARN  " ++ "\x1b[0;40m\x1b[0;37m",
        .ERROR => "\x1b[4;101m\x1b[1:37m" ++ " ERROR " ++ "\x1b[0;40m\x1b[0;37m",
        .FATAL => "\x1b[1;107m\x1b[0:30m" ++ " FATAL " ++ "\x1b[0;40m\x1b[0;37m",
    };
    try w.print("{s}({d}): \x1b[38;5;229m{s}\x1b[0;40m ", .{ level_fmt, timestamp.toMilliseconds(), desc });
    //TODO: create type and functions to make compile time logging better
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |field| {
        if (field.type == []u8 or field.type == []const u8) {
            const string = @field(args, field.name);
            const len = @min(string.len, 80);
            try w.print("{s}={s}{s}", .{
                field.name,
                string[0..len],
                if (string.len > 80) "... " else " ",
            });
            continue;
        }
        try w.print("{s}={any} ", .{ field.name, @field(args, field.name) });
    }
    try w.writeByte('\n');
}
