iouring: IoUring,
eventfd: linux.fd_t,

const std = @import("std");
const config = @import("config");
const linux = std.os.linux;
const IoUring = std.os.linux.IoUring;
const interface = @import("interface.zig");
const posix = std.posix;
const Queue = @import("../util/queue.zig").Queue;

const IO = @This();

//These come from the common interface defined in "interface.zig"
const OpenError = interface.OpenError;
const AcceptError = interface.AcceptError;
const ReadError = interface.ReadError;
const SendError = interface.SendError;
const WriteError = interface.WriteError;
const Operation = interface.Operation;
const Handle = interface.Handle;
const Event = interface.Event;
const Vec = interface.Vec;

pub fn init(options: interface.Options) !IO {
    const iouring = IoUring.init(options.entries, linux.IORING_SETUP_SINGLE_ISSUER) catch return error.InitializationFailed;
    var uring: IO = .{
        .iouring = iouring,
        .eventfd = @intCast(std.os.linux.eventfd(0, 0)),
    };
    try uring.iouring.register_eventfd(uring.eventfd);
    return uring;
}
pub fn deinit(self: *IO) void {
    self.iouring.deinit();
}

pub fn submit(self: *IO, event: *interface.Event) error{ IOFull, PathTooLong }!void {
    std.debug.assert(event.status == .pending);
    _ = sqe: switch (event.status.pending) {
        .accept => |a| self.iouring.accept_multishot(@intFromPtr(event), a.handle, null, null, 0),
        .openat => |o| {
            const path_z = std.posix.toPosixPath(o.path) catch return error.PathTooLong;

            const options: interface.OpenOptions = o.options;
            const flags: linux.O = .{
                .ACCMODE = switch (options.access_mode) {
                    .read => posix.ACCMODE.RDONLY,
                    .write => posix.ACCMODE.WRONLY,
                    .readwrite => posix.ACCMODE.RDWR,
                },
                .CREAT = options.create_if_not_exist,
                .TMPFILE = options.tmp_file,
                .DIRECTORY = options.is_directory,
                .PATH = options.path,
                .TRUNC = options.truncate,
            };

            //mode is always max permissions possible for given user
            break :sqe self.iouring.openat(@intFromPtr(event), o.handle, &path_z, flags, 0o0666);
        },
        .close => |c| self.iouring.close(@intFromPtr(event), c.handle),
        .read => |r| {
            const iovecs = Vec.toIoVecSlice(r.vec);
            break :sqe self.iouring.read(@intFromPtr(event), r.handle, .{ .iovecs = iovecs[0..r.vec.len] }, r.offset);
        },
        .send => |s| {
            const options: interface.SendOptions = s.options;
            var flags: u32 = 0;
            if (options.no_confirm) flags |= linux.MSG.CONFIRM;
            if (options.is_more_coming) flags |= linux.MSG.MORE;
            if (options.fastopend) flags |= linux.MSG.FASTOPEN;

            break :sqe self.iouring.send(@intFromPtr(event), s.socket, s.buffer, flags);
        },
        .writev => |w| {
            const iovecs = Vec.toConstIoVecSlice(w.vec);
            break :sqe self.iouring.writev(@intFromPtr(event), w.handle, iovecs, w.offset);
        },
        .write => |w| self.iouring.write(@intFromPtr(event), w.handle, w.buffer, w.offset),
    } catch return error.IOFull;
}
pub fn flush(self: *IO, wait_nr: u32) error{UnableToFlush}!Queue(interface.Event) {
    var cqes: [256]linux.io_uring_cqe = undefined;
    _ = self.iouring.submit() catch return error.UnableToFlush;
    const len = self.iouring.copy_cqes(&cqes, wait_nr) catch return error.UnableToFlush;
    var queue: Queue(Event) = .{};
    for (cqes[0..len]) |cqe| {
        const event: *interface.Event = fillCompletion(@ptrFromInt(cqe.user_data), cqe);
        queue.enqueue(event);
    }
    return queue;
}
pub fn wake(self: *IO) void {
    const buf: u64 = 1;
    _ = std.os.linux.write(@intCast(self.eventfd), std.mem.asBytes(&buf), 8);
}

fn fillCompletion(event: *interface.Event, cqe: linux.io_uring_cqe) *Event {
    std.debug.assert(event.status == .pending);
    switch (event.status.pending) {
        .accept => {
            event.status = .{
                .complete = .{
                    .accept = switch (cqe.err()) {
                        .SUCCESS => cqe.res,
                        .AGAIN => AcceptError.WouldBlock,
                        //.WOULDBLOCK => AcceptError.WouldBlock,
                        .CONNABORTED => AcceptError.ConnectionAborted,
                        .INTR => AcceptError.Interrupted,
                        .INVAL => AcceptError.InvalidArgument,
                        .MFILE => AcceptError.TooManyOpenFiles,
                        .NFILE => AcceptError.SystemFileLimit,
                        .NOBUFS => AcceptError.NoBufferSpace,
                        .NOMEM => AcceptError.OutOfMemory,
                        .NOTSOCK => AcceptError.NotSocket,
                        .OPNOTSUPP => AcceptError.OperationNotSupported,
                        .BADF => AcceptError.InvalidFileDescriptor,
                        .PROTO => AcceptError.ProtocolError,
                        else => AcceptError.Unexpected,
                    },
                },
            };
        },
        .openat => {
            event.status = .{ .complete = .{
                .openat = switch (cqe.err()) {
                    .SUCCESS => cqe.res,
                    .ACCES => OpenError.AccessDenied,
                    .PERM => OpenError.PermissionDenied,
                    .EXIST => OpenError.AlreadyExists,
                    .NOENT => OpenError.FileNotFound,
                    .NOTDIR => OpenError.NotDirectory,
                    .ISDIR => OpenError.IsDirectory,
                    .LOOP => OpenError.TooManySymlinks,
                    .NAMETOOLONG => OpenError.NameTooLong,
                    .FBIG => OpenError.FileTooLarge,
                    .NOSPC => OpenError.NoSpaceLeft,
                    .ROFS => OpenError.ReadOnlyFileSystem,
                    .MFILE => OpenError.TooManyOpenFiles,
                    .NFILE => OpenError.SystemFileLimit,
                    .BADF => OpenError.InvalidFileDescriptor,
                    .INVAL => OpenError.InvalidArgument,
                    .IO => OpenError.IoError,
                    .FAULT => OpenError.MemoryFault,
                    .DQUOT => OpenError.QuotaExceeded,
                    .BUSY => OpenError.Busy,
                    .TXTBSY => OpenError.TextFileBusy,
                    else => AcceptError.Unexpected,
                },
            } };
        },
        .read => {
            event.status = .{
                .complete = .{
                    .read = switch (cqe.err()) {
                        .SUCCESS => @as(usize, @intCast(cqe.res)),
                        .AGAIN => ReadError.WouldBlock,
                        //.WOULDBLOCK => ReadError.WouldBlock,
                        .BADF => ReadError.InvalidFileDescriptor,
                        .FAULT => ReadError.MemoryFault,
                        .INTR => ReadError.Interrupted,
                        .INVAL => ReadError.InvalidArgument,
                        .IO => ReadError.IoError,
                        .ISDIR => ReadError.IsDirectory,
                        .NOMEM => ReadError.OutOfMemory,
                        .NOBUFS => ReadError.NoBufferSpace,
                        else => AcceptError.Unexpected,
                    },
                },
            };
        },
        .send => {
            event.status = .{
                .complete = .{
                    .send = switch (cqe.err()) {
                        .SUCCESS => @as(usize, @intCast(cqe.res)),
                        .AGAIN => SendError.WouldBlock,
                        //.WOULDBLOCK => SendError.WouldBlock,
                        .BADF => SendError.InvalidFileDescriptor,
                        .CONNRESET => SendError.ConnectionReset,
                        .DESTADDRREQ => SendError.DestinationRequired,
                        .FAULT => SendError.MemoryFault,
                        .INTR => SendError.Interrupted,
                        .INVAL => SendError.InvalidArgument,
                        .IO => SendError.IoError,
                        .NOBUFS => SendError.NoBufferSpace,
                        .NOMEM => SendError.OutOfMemory,
                        .NOTCONN => SendError.NotConnected,
                        .NOTSOCK => SendError.NotSocket,
                        .OPNOTSUPP => SendError.OperationNotSupported,
                        .PIPE => SendError.BrokenPipe,
                        .MSGSIZE => SendError.MessageTooLarge,
                        else => AcceptError.Unexpected,
                    },
                },
            };
        },
        .write => {
            event.status = .{
                .complete = .{
                    .write = switch (cqe.err()) {
                        .SUCCESS => @as(usize, @intCast(cqe.res)),
                        .AGAIN => WriteError.WouldBlock,
                        //.WOULDBLOCK => WriteError.WouldBlock,
                        .BADF => WriteError.InvalidFileDescriptor,
                        .FAULT => WriteError.MemoryFault,
                        .INTR => WriteError.Interrupted,
                        .INVAL => WriteError.InvalidArgument,
                        .IO => WriteError.IoError,
                        .NOSPC => WriteError.NoSpaceLeft,
                        .PIPE => WriteError.BrokenPipe,
                        .DQUOT => WriteError.QuotaExceeded,
                        .FBIG => WriteError.FileTooLarge,
                        .NOMEM => WriteError.OutOfMemory,
                        .NOBUFS => WriteError.NoBufferSpace,
                        else => AcceptError.Unexpected,
                    },
                },
            };
        },
        .writev => {
            event.status = .{
                .complete = .{
                    .writev = switch (cqe.err()) {
                        .SUCCESS => @as(usize, @intCast(cqe.res)),
                        .AGAIN => WriteError.WouldBlock,
                        //.WOULDBLOCK => WriteError.WouldBlock,
                        .BADF => WriteError.InvalidFileDescriptor,
                        .FAULT => WriteError.MemoryFault,
                        .INTR => WriteError.Interrupted,
                        .INVAL => WriteError.InvalidArgument,
                        .IO => WriteError.IoError,
                        .NOSPC => WriteError.NoSpaceLeft,
                        .PIPE => WriteError.BrokenPipe,
                        .DQUOT => WriteError.QuotaExceeded,
                        .FBIG => WriteError.FileTooLarge,
                        .NOMEM => WriteError.OutOfMemory,
                        .NOBUFS => WriteError.NoBufferSpace,
                        else => AcceptError.Unexpected,
                    },
                },
            };
        },
        .close => event.status = .{ .complete = .{ .close = {} } },
    }
    return event;
}
