iouring: IoUring,

const std = @import("std");
const config = @import("config");
const linux = std.os.linux;
const IoUring = std.os.linux.IoUring;
const posix = std.posix;
const IO = @This();

pub const Options = struct {
    entries: u16 = config.io_ring_size * 4,
    flags: u32 = 0,
};

const OpenError = error{
    AccessDenied, // EACCES
    PermissionDenied, // EPERM
    AlreadyExists, // EEXIST
    FileNotFound, // ENOENT
    NotDirectory, // ENOTDIR
    IsDirectory, // EISDIR
    TooManySymlinks, // ELOOP
    NameTooLong, // ENAMETOOLONG
    FileTooLarge, // EFBIG
    NoSpaceLeft, // ENOSPC
    ReadOnlyFileSystem, // EROFS
    TooManyOpenFiles, // EMFILE (process limit)
    SystemFileLimit, // ENFILE (system-wide limit)
    InvalidFileDescriptor, // EBADF
    InvalidArgument, // EINVAL
    IoError, // EIO
    MemoryFault, // EFAULT
    QuotaExceeded, // EDQUOT
    Busy, // EBUSY
    TextFileBusy, // ETXTBSY
} || posix.UnexpectedError;
//ran per connection(this is a multishot)
const AcceptError = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK
    ConnectionAborted, // ECONNABORTED
    Interrupted, // EINTR
    InvalidArgument, // EINVAL
    TooManyOpenFiles, // EMFILE
    SystemFileLimit, // ENFILE
    NoBufferSpace, // ENOBUFS
    OutOfMemory, // ENOMEM
    NotSocket, // ENOTSOCK
    OperationNotSupported, // EOPNOTSUPP
    InvalidFileDescriptor, // EBADF
    ProtocolError, // EPROTO (rare)
} || posix.UnexpectedError;
const ReadError = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    MemoryFault, // EFAULT
    Interrupted, // EINTR
    InvalidArgument, // EINVAL
    IoError, // EIO
    IsDirectory, // EISDIR
    OutOfMemory, // ENOMEM
    NoBufferSpace, // ENOBUFS
} || posix.UnexpectedError;
const SendError = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    ConnectionReset, // ECONNRESET
    DestinationRequired, // EDESTADDRREQ
    MemoryFault, // EFAULT
    Interrupted, // EINTR
    InvalidArgument, // EINVAL
    IoError, // EIO
    NoBufferSpace, // ENOBUFS
    OutOfMemory, // ENOMEM
    NotConnected, // ENOTCONN
    NotSocket, // ENOTSOCK
    OperationNotSupported, // EOPNOTSUPP
    BrokenPipe, // EPIPE
    MessageTooLarge, // EMSGSIZE
} || posix.UnexpectedError;
const WriteError = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    MemoryFault, // EFAULT
    Interrupted, // EINTR
    InvalidArgument, // EINVAL
    IoError, // EIO
    NoSpaceLeft, // ENOSPC
    BrokenPipe, // EPIPE
    QuotaExceeded, // EDQUOT
    FileTooLarge, // EFBIG
    OutOfMemory, // ENOMEM
    NoBufferSpace, // ENOBUFS
} || posix.UnexpectedError;

pub const Operation = union(enum) {
    accept: struct {
        fd: linux.fd_t,
        addr: std.net.Address,
        flags: u32,
    },
    close: struct {
        fd: linux.fd_t,
    },
    openat: struct {
        fd: linux.fd_t,
        path: []const u8,
        flags: u32,
        mode: linux.mode_t,
    },
    read: struct {
        fd: linux.fd_t,
        buffer: []u8,
        offset: u64,
    },
    send: struct {
        socket: linux.socket_t,
        buffer: []const u8,
        flags: u32,
    },
    write: struct {
        fd: linux.fd_t,
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

pub const Completion = union(enum) {
    accept: AcceptError!std.net.Stream.Handle,
    close: void,
    openat: OpenError!std.fs.File.Handle,
    read: ReadError![]u8,
    write: WriteError![]const u8,
    send: SendError![]const u8,

    fn from_operation(op: Operation, cqe: linux.io_uring_cqe) Completion {
        return switch (op) {
            .accept => {
                Completion{ .accept = switch (cqe.err()) {
                    .SUCCESS => @as(std.net.Stream.Handle, cqe.res),
                    .AGAIN => AcceptError.WouldBlock,
                    .WOULDBLOCK => AcceptError.WouldBlock,
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
                    else => |e| posix.unexpectedErrno(e),
                } };
            },
            .openat => {
                Completion{ .openat = switch (cqe.err()) {
                    .SUCCESS => @as(std.fs.File.Handle, cqe.res),
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
                    else => |e| posix.unexpectedErrno(e),
                } };
            },
            .read => |o| {
                Completion{ .read = switch (cqe.err()) {
                    .SUCCESS => {
                        const read = @as(usize, @intCast(cqe.res));
                        o.buffer[0..read];
                    },
                    .AGAIN => ReadError.WouldBlock,
                    .WOULDBLOCK => ReadError.WouldBlock,
                    .BADF => ReadError.InvalidFileDescriptor,
                    .FAULT => ReadError.MemoryFault,
                    .INTR => ReadError.Interrupted,
                    .INVAL => ReadError.InvalidArgument,
                    .IO => ReadError.IoError,
                    .ISDIR => ReadError.IsDirectory,
                    .NOMEM => ReadError.OutOfMemory,
                    .NOBUFS => ReadError.NoBufferSpace,
                    else => |e| posix.unexpectedErrno(e),
                } };
            },
            .send => |o| {
                Completion{ .send = switch (cqe.err()) {
                    .SUCCESS => {
                        const sent = @as(usize, @intCast(cqe.res));
                        o.buffer[sent..];
                    },
                    .AGAIN => SendError.WouldBlock,
                    .WOULDBLOCK => SendError.WouldBlock,
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
                    else => |e| posix.unexpectedErrno(e),
                } };
            },
            .write => |o| {
                Completion{ .write = switch (cqe.err()) {
                    .SUCCESS => {
                        const wrote = @as(usize, @intCast(cqe.res));
                        o.buffer[wrote..];
                    },
                    .AGAIN => WriteError.WouldBlock,
                    .WOULDBLOCK => WriteError.WouldBlock,
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
                    else => |e| posix.unexpectedErrno(e),
                } };
            },
        };
    }
};

pub const Transaction = union(enum) {
    pending: Operation,
    completion: Completion,
};

pub fn init(options: Options) !IO {
    const iouring: IoUring = init(options.entries, options.flags) catch return error.InitializationFailed;
    return .{
        .iouring = iouring,
    };
}
pub fn deinit(self: *IO) void {
    self.iouring.deinit();
}

pub fn submit(
    self: *IO,
    transction: *Transaction,
) error{IOFull}!void {
    std.debug.assert(transction == .pending);
    _ = switch (transction.pending) {
        .accept => |a| self.iouring.accept_multishot(@intFromPtr(transction), a.fd, a.addr.any, a.addr.getOsSockLen(), a.flags),
        .openat => |o| self.iouring.openat(@intFromPtr(transction), o.fd, o.path, o.flags, o.mode),
        .close => |c| self.iouring.close(@intFromPtr(transction), c.fd),
        .read => |r| self.iouring.read(@intFromPtr(transction), r.fd, r.buffer, r.offset),
        .send => |s| self.iouring.send(@intFromPtr(transction), s.fs, s.buffer, s.flags),
        .write => |w| self.iouring.write(@intFromPtr(transction), w.fd, w.buffer, w.offset),
    } catch return error.IOFull;
}
pub fn flush(self: *IO, transactions: []*Transaction) ![]*Transaction {
    const cqes: [config.io_ring_size * 4]linux.io_uring_cqe = undefined;
    _ = try self.iouring.submit();
    const len = try self.iouring.copy_cqes(&cqes, 0);
    for (cqes[0..len], 0..) |cqe, i| {
        var transaction = @as(*Transaction, cqe.user_data);
        transaction.completion = Completion.from_operation(transaction.pending, cqe);
        transactions[i] = transaction;
    }
    return transactions[0..len];
}
