//https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/
//This is my inspiration for the redesign
const std = @import("std");
const posix = std.posix;
const IoUring = std.os.linux.IoUring;
iouring: IoUring,
completed: CompetionList
pending: CompletionList
const IO = @this();
const Operation = union(enum) {
    accept: struct {
        addr: std.net.Address,
    },
    close: struct {
        fd: posix.fd_t,
    },
    open: struct {
        path: [*:0]const u8,
        flags: u32,
        mode: os.mode_t,
    },
    read: struct {
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
    },
    send: struct {
        socket: os.socket_t,
        buffer: []const u8,
        flags: u32,
    },
    write: struct {
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    },

    pub fn slice(this: Operation) []const u8 {
        return switch (this) {
            .write => |op| op.buffer,
            .send => |op| op.buffer,
            .read => |op| op.buffer,
            else => &[_]u8{},
        };
    }
};
const Completion = {
    io: *IO,
    result: i32 = undefined,
    context: ?*anyopaque,
    operation: Operation,
    comptime cb: fn (
        context: ?*anyopaque,
        completion: *Completion,
        res: *const anyopaque,
    ) void
    fn complete() void {}
    fn prep()
};


pub fn init(gpa: std.mem.Allocator) !IO {
    const entries = opt.entries;

    const iouring: std.os.linux.IoUring = try .init(entries,0);
    return .{
        .iouring = iouring,
    };
}
pub fn deinit(self: *IO, gpa: std.mem.Allocator) void {
    self.iouring.deinit();
}

pub fn read(self: *IO, comptime Context: type, context: Context, comptime callback: fn (
        context: Context,
        completion *Completion
        res: SendError!usize
    )
) void {

};
pub fn write(self: *IO) {};
pub fn close(self: *IO) {};
