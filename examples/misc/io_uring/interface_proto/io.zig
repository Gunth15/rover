//https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/
//This is my inspiration for the redesign
const std = @import("std");
const os = std.os;
const FIFO = @import("./fifo.zig");
const posix = std.posix;
const IoUring = std.os.linux.IoUring;
iouring: IoUring,
completed: FIFO(Completion),
pending: FIFO(Completion),
const IO = @this();
const Operation = union(enum) {
    accept: struct {
        fd: posix.fd_t,
        addr: std.net.Address,
        flags: u32,
    },
    close: struct {
        fd: posix.fd_t,
    },
    open: struct {
        path: []const u8,
        flags: u32,
        mode: posix.mode_t,
    },
    read: struct {
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
    },
    send: struct {
        socket: posix.socket_t,
        buffer: []const u8,
        flags: u32,
    },
    write: struct {
        fd: posix.fd_t,
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
//TODO: Adjust api for mutlithreadded environment
//Instead of callbacks, can us Channel(Sender,Reciever)
//Instead linked list, can use dequeue c/c Completions will never leave OS thread
const Completion = struct {
    io: *IO,
    result: i32 = undefined,
    context: ?*anyopaque,
    operation: Operation,
    //Allows for linking
    next: ?Completion,
    comptime cb: fn (
        context: ?*anyopaque,
        completion: *Completion,
        res: *const anyopaque,
    ) void,
    fn complete(self: *Completion) void {
        switch (self.operation) {
            .accept => {
                const result = brk: {
                    if (self.result >= 0) break :brk @as(posix.fd_t, self.result);

                    const err = switch (@intToEnum(std.os.E, -self.result)) {
                        .AGAIN => error.WouldBlock,
                        .WOULDBLOCK => error.WouldBlock,
                        .CONNABORTED => error.ConnectionAborted,
                        .INTR => error.Interrupted,
                        .INVAL => error.InvalidArgument,
                        .MFILE => error.TooManyOpenFiles,
                        .NFILE => error.SystemFileLimit,
                        .NOBUFS => error.NoBufferSpace,
                        .NOMEM => error.OutOfMemory,
                        .NOTSOCK => error.NotSocket,
                        .OPNOTSUPP => error.OperationNotSupported,
                        .BADF => error.InvalidFileDescriptor,
                        .PROTO => error.ProtocolError,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };

                    break :brk err;
                };
                self.cb(self.context,self, &result);
            },
            .close => {
                const result = brk: {
                    if (self.result >= 0) break :brk;

                    const err = switch (@intToEnum(std.os.E, -self.result)) {
                        .BADF => error.InvalidFileDescriptor,
                        .INTR => error.Interrupted,
                        .IO => error.IoError,
                        .NOSPC => error.NoSpaceLeft,
                        .DQUOT => error.QuotaExceeded,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };

                    break :brk err;
                };
                self.cb(self.context,self, &result);
           },
            .open => {
                const result = brk: {
                    if (self.result > 0) break :brk @as(posix.fd_t,self.result);
                    const err  = switch (@intToEnum(std.os.E,-self.result)) {
                        .ACCES => error.AccessDenied,
                        .PERM => error.PermissionDenied,
                        .EXIST => error.AlreadyExists,
                        .NOENT => error.FileNotFound,
                        .NOTDIR => error.NotDirectory,
                        .ISDIR => error.IsDirectory,
                        .LOOP => error.TooManySymlinks,
                        .NAMETOOLONG => error.NameTooLong,
                        .FBIG => error.FileTooLarge,
                        .NOSPC => error.NoSpaceLeft,
                        .ROFS => error.ReadOnlyFileSystem,
                        .MFILE => error.TooManyOpenFiles,
                        .NFILE => error.SystemFileLimit,
                        .BADF => error.InvalidFileDescriptor,
                        .INVAL => error.InvalidArgument,
                        .IO => error.IoError,
                        .FAULT => error.MemoryFault,
                        .DQUOT => error.QuotaExceeded,
                        .BUSY => error.Busy,
                        .TXTBSY => error.TextFileBusy,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };
                    break :brk err;
                };
                self.cb(self.context,self, &result);
            },
            .read => {
                const result = brk: {
                    if (self.result >= 0) break :brk @as(usize, self.result);

                    const err = switch (@intToEnum(std.os.E, -self.result)) {
                        .AGAIN => error.WouldBlock,
                        .WOULDBLOCK => error.WouldBlock,
                        .BADF => error.InvalidFileDescriptor,
                        .FAULT => error.MemoryFault,
                        .INTR => error.Interrupted,
                        .INVAL => error.InvalidArgument,
                        .IO => error.IoError,
                        .ISDIR => error.IsDirectory,
                        .NOMEM => error.OutOfMemory,
                        .NOBUFS => error.NoBufferSpace,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };

                    break :brk err;
                };
                self.cb(self.context,self, &result);
            },
            .send => {
                const result = brk: {
                    if (self.result >= 0) break :brk @as(usize, self.result);

                    const err = switch (@intToEnum(std.os.E, -self.result)) {
                        .AGAIN => error.WouldBlock,
                        .WOULDBLOCK => error.WouldBlock,
                        .BADF => error.InvalidFileDescriptor,
                        .CONNRESET => error.ConnectionReset,
                        .DESTADDRREQ => error.DestinationRequired,
                        .FAULT => error.MemoryFault,
                        .INTR => error.Interrupted,
                        .INVAL => error.InvalidArgument,
                        .IO => error.IoError,
                        .NOBUFS => error.NoBufferSpace,
                        .NOMEM => error.OutOfMemory,
                        .NOTCONN => error.NotConnected,
                        .NOTSOCK => error.NotSocket,
                        .OPNOTSUPP => error.OperationNotSupported,
                        .PIPE => error.BrokenPipe,
                        .MSGSIZE => error.MessageTooLarge,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };

                    break :brk err;
                };
                self.cb(self.context,self, &result);
            },
            .write => {
                const result = brk: {
                    if (self.result >= 0) break :brk @as(usize, self.result);

                    const err = switch (@intToEnum(std.os.E, -self.result)) {
                        .AGAIN => error.WouldBlock,
                        .WOULDBLOCK => error.WouldBlock,
                        .BADF => error.InvalidFileDescriptor,
                        .FAULT => error.MemoryFault,
                        .INTR => error.Interrupted,
                        .INVAL => error.InvalidArgument,
                        .IO => error.IoError,
                        .NOSPC => error.NoSpaceLeft,
                        .PIPE => error.BrokenPipe,
                        .DQUOT => error.QuotaExceeded,
                        .FBIG => error.FileTooLarge,
                        .NOMEM => error.OutOfMemory,
                        .NOBUFS => error.NoBufferSpace,
                        else => |errno| std.os.unexpectedErrno(errno),
                    };

                    break :brk err;
                };
                self.cb(self.context,self, &result);
            },
        }
    }
    fn submit(self: *Completion) !std.linux.io_uring_sqe {
       switch (self.operation) {
            .listen => |op| return self.io.iouring.listen(@intFromPtr(self),op.fd,op.backlog,op.flags),
            .close => |op| return self.io.iouring.close(op.fd),
            .open => |op| return self.io.iouring.open(@intFromPtr(self), op.fd, op.path, op.flags, op.mode),
            .read => |op| return self.io.iouring.read(@intfromptr(self), op.fd, op.buffer, op.offset),
            .send => |op| return self.io.iouring.send(@intFromPtr(self),op.fd, op.buffer,op.flags),
            .write => |op| return self.io.iouring.write(@intfromptr(self), op.fd, op.buffer, op.offset),
            .bind => |op| return self.io.iouring.bind(@intfromptr(self),op.fd, op.address.any, op.address.getOsSockLen(), op.flags),
        }
    }
};

pub fn init(entries: u16, flags: u32) !IO {
    const iouring: IoUring = try .init(entries, flags);
    return .{
        .iouring = iouring,
    };
}
pub fn deinit(self: *IO) void {
    self.iouring.deinit();
}

pub fn wait(self: *IO) void {
    //256
    self.iouring.copy_cqes(//blah);
    for (cqes) {
        //...
        self.completed.enqueue()
    }
}

fn enqueue(self: *IO) void {
    //if io_uring full, enqeuee to pending
    //else submit

}
fn flush(self: *IO) void {
    //flush sq
    //flush cq
    //copy and empty pending and enqueue
    //copy and empty completion queue and complete
}
fn flush_completions(self: *IO) void {
    //flush completion
}
fn flush_pending(self: *IO) void {
    //flush pending
}

const OpenError = error{
    AccessDenied,            // EACCES
    PermissionDenied,        // EPERM
    AlreadyExists,           // EEXIST
    FileNotFound,            // ENOENT
    NotDirectory,            // ENOTDIR
    IsDirectory,             // EISDIR
    TooManySymlinks,         // ELOOP
    NameTooLong,             // ENAMETOOLONG
    FileTooLarge,            // EFBIG
    NoSpaceLeft,             // ENOSPC
    ReadOnlyFileSystem,      // EROFS
    TooManyOpenFiles,        // EMFILE (process limit)
    SystemFileLimit,         // ENFILE (system-wide limit)
    InvalidFileDescriptor,   // EBADF
    InvalidArgument,         // EINVAL
    IoError,                 // EIO
    MemoryFault,             // EFAULT
    QuotaExceeded,           // EDQUOT
    Busy,                    // EBUSY
    TextFileBusy,            // ETXTBSY
} || os.UnexpectedError;
pub fn open(self: *IO, comptime Context: type, context: Context, 
    fd: posix.fd_t,
    path: [*:0]const u8,
    flags: std.linux.O,
    mode: posix.mode_t,
    comptime callback: fn (
    context: Context,
    completion: *Completion,
    res: OpenError!posix.fd_t,
) void) void {

}
//ran per connection(this is a multishot)
const AcceptError = error{
    WouldBlock,              // EAGAIN / EWOULDBLOCK
    ConnectionAborted,       // ECONNABORTED
    Interrupted,             // EINTR
    InvalidArgument,         // EINVAL
    TooManyOpenFiles,        // EMFILE
    SystemFileLimit,         // ENFILE
    NoBufferSpace,           // ENOBUFS
    OutOfMemory,             // ENOMEM
    NotSocket,               // ENOTSOCK
    OperationNotSupported,   // EOPNOTSUPP
    InvalidFileDescriptor,   // EBADF
    ProtocolError,           // EPROTO (rare)
} || os.UnexpectedError;
pub fn accept(self: *IO, comptime Context: type, context: Context, 
    fd: posix.fd_t,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
    flags: u32,
    comptime callback: fn (
    context: Context,
    completion: *Completion,
    res: AcceptError!posix.fd_t,
) void) void {

}

const ReadError = error{
    WouldBlock,            // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    MemoryFault,           // EFAULT
    Interrupted,           // EINTR
    InvalidArgument,       // EINVAL
    IoError,               // EIO
    IsDirectory,           // EISDIR
    OutOfMemory,           // ENOMEM
    NoBufferSpace,         // ENOBUFS
} || os.UnexpectedError;
pub fn read(self: *IO, comptime Context: type, context: Context, fd: posix.fd_t, buffer: []u8, offset: u64, comptime callback: fn (
    context: Context,
    completion: *Completion,
    res: ReadError!usize,
) void) void {
    completion.* = .{ .io = self, .context = context, .operation = .{ .read = .{
        .fd = fd,
        .buffer = buffer,
        .offset = offset,
    } }, .cb = struct {
        fn wrapper(context: ?*anyopaque, completion: *Completion, res: *const anyopaque) void {
            callback(@ptrCast(completion.context), @ptrCast(completion.result));
        }
    }.wrapper };
}

const SendError = error{
    WouldBlock,            // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    ConnectionReset,       // ECONNRESET
    DestinationRequired,   // EDESTADDRREQ
    MemoryFault,           // EFAULT
    Interrupted,           // EINTR
    InvalidArgument,       // EINVAL
    IoError,               // EIO
    NoBufferSpace,         // ENOBUFS
    OutOfMemory,           // ENOMEM
    NotConnected,          // ENOTCONN
    NotSocket,             // ENOTSOCK
    OperationNotSupported, // EOPNOTSUPP
    BrokenPipe,            // EPIPE
    MessageTooLarge,       // EMSGSIZE
} || os.UnexpectedError;
pub fn send(self: *IO, comptime Context: type, context: Context, socket: posix.socket_t, buffer: []const u8, flags: u32, comptime callback: fn (
    context: Context,
    completion: *Completion,
    res: SendError!usize,
) void) void {
    completion.* = .{ .io = self, .context = context, .operation = .{ .send = .{
        .socket = socket,
        .buffer = buffer,
        .flags = u32,
    } }, .cb = struct {
        fn wrapper(context: ?*anyopaque, completion: *Completion, res: *const anyopaque) void {
            callback(@ptrCast(completion.context), @ptrCast(completion.result));
        }
    }.wrapper };
}

const WriteError = error{
    WouldBlock,            // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    MemoryFault,           // EFAULT
    Interrupted,           // EINTR
    InvalidArgument,       // EINVAL
    IoError,               // EIO
    NoSpaceLeft,           // ENOSPC
    BrokenPipe,            // EPIPE
    QuotaExceeded,         // EDQUOT
    FileTooLarge,          // EFBIG
    OutOfMemory,           // ENOMEM
    NoBufferSpace,         // ENOBUFS
} || os.UnexpectedError;
pub fn write(self: *IO, comptime Context: type, context: Context, fd: posix.fd_t, buffer: []const u8, offset: u64, comptime callback: fn (
    context: Context,
    completion: *Completion,
    res: WriteError!usize,
) void) void {
    completion.* = .{ .io = self, .context = context, .operation = .{ .write = .{
        .fd = fd,
        .buffer = buffer,
        .offset = u64,
    } }, .cb = struct {
        fn wrapper(context: ?*anyopaque, completion: *Completion, res: *const anyopaque) void {
            callback(@ptrCast(completion.context), @ptrCast(completion.result));
        }
    }.wrapper };
}

const CloseError = error{
    InvalidFileDescriptor, // EBADF
    Interrupted,           // EINTR
    IoError,               // EIO
    NoSpaceLeft,           // ENOSPC
    QuotaExceeded,         // EDQUOT
} || os.UnexpectedError;
pub fn close(self: *IO, comptime Context: type, context: Context, fd: posix.fd_t, 
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,) 
void {
    completion.* = .{ .io = self, .context = context, .operation = .{ .close = .{
        .fd = fd,
    } }, .cb = struct {
        fn wrapper(context: ?*anyopaque, completion: *Completion, res: *const anyopaque) void {
            callback(@ptrCast(completion.context), @ptrCast(completion.result));
        }
    }.wrapper };
}
