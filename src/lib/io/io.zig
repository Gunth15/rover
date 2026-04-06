impl: Impl,
queued: Queue(Event),

const Queue = @import("../util/queue.zig").Queue;
const builtin = @import("builtin");
const interface = @import("interface.zig");

const Io = @This();

pub const Handle = interface.Handle;
pub const Event = interface.Event;
pub const Status = interface.Status;
pub const Operation = interface.Operation;
pub const CompletionReturn = interface.CompletionReturn;
pub const OpenOptions = interface.OpenOptions;
pub const SendOptions = interface.SendOptions;
pub const AcceptError = interface.AcceptError;
pub const SendError = interface.SendError;
pub const ReadError = interface.ReadError;
pub const WriteError = interface.WriteError;

//Implementation must define 4 functions
// 1. init: how to initialize async io
// 2. deinit: how to deinitialize async io
// 3. submit: how to submit task to io
// 4. flush: how to drain io and wait if needed
// 5. wake: notifies IO to exit blocking state
// Sadly specific IO errors are not part of the interface, so must be debugged in the implementation
const Impl = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported operating system"),
};
pub inline fn init(options: interface.Options) !Io {
    return .{
        .impl = try Impl.init(options),
        .queued = .{},
    };
}
pub inline fn deinit(self: *Io) void {
    return self.impl.deinit();
}
pub inline fn submit(self: *Io, sub: *Event) error{PathTooLong}!void {
    return self.impl.submit(sub) catch |e| {
        switch (e) {
            error.PathTooLong => |p| return p,
            error.IOFull => self.queued.enqueue(sub),
        }
    };
}
pub inline fn flush(self: *Io, wait_nr: u32) error{UnableToFlush}!Queue(Event) {
    const completions = self.impl.flush(wait_nr);
    while (self.queued.dequeue()) |ev| {
        self.submit(ev) catch unreachable;
    }
    return completions;
}

pub inline fn wake(self: *Io) void {
    return self.impl.wake();
}

test "simple connection test" {
    const std = @import("std");
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8083);
    const clientcb = struct {
        fn createconnection(addr: std.net.Address) !void {
            var buf: [5]u8 = undefined;
            const client = try std.net.tcpConnectToAddress(addr);
            defer client.close();

            _ = try client.write("Hello");
            const n = try client.read(&buf);
            try std.testing.expectEqual(5, n);
            try std.testing.expectEqualStrings("Hello", &buf);
        }
    };

    var buf: [10]u8 = undefined;
    var server = try address.listen(.{});
    defer server.deinit();

    var io: Io = try .init(.{ .entries = 1 });
    defer io.deinit();

    const client_thread = try std.Thread.spawn(.{}, clientcb.createconnection, .{server.listen_address});
    defer client_thread.join();

    var accept_ev = Event.accept(&.{}, server.stream.handle);
    try io.submit(&accept_ev);

    var q = try io.flush(1);
    var event = q.dequeue().?;

    try std.testing.expect(event.status == .complete);
    const handle = event.status.complete.accept catch |e| {
        std.debug.print("ACCEPT ERROR: {any}\n", .{e});
        return e;
    };

    const ctx = struct {
        buf: []u8,
    };

    var c = ctx{ .buf = &buf };
    var read_ev = Event.read(&c, handle, &buf, 0);
    try io.submit(&read_ev);

    q = try io.flush(1);
    event = q.dequeue().?;
    try std.testing.expect(event.status == .complete);

    const context: *ctx = @ptrCast(@alignCast(event.context));
    const read = try event.status.complete.read;
    try std.testing.expectEqualStrings("Hello", context.buf[0..read]);

    var write_ev = Event.send(&c, handle, context.buf[0..read], .{});
    try io.submit(&write_ev);
    q = try io.flush(1);
    event = q.dequeue().?;

    try std.testing.expect(event.status == .complete);

    const five = try event.status.complete.send;
    try std.testing.expect(five == 5);
}
