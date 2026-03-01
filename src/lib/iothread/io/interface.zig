//This file contains the public interface that a OS needs to implement to work correctly
const std = @import("std");
const config = @import("config");
const buitin = @import("builtin");
const IoUring = std.os.linux.IoUring;
const Address = std.net.Address;
const posix = std.posix;

pub const Handle = switch (buitin.os.tag) {
    .linux => std.os.linux.fd_t,
    .windows => union { handle: std.os.windows.HANDLE, socket: std.os.windows.ws2_32.SOCKET },
    else => @compileError("Not implemented yet"),
};

pub const Options = struct {
    //Linux only(possibly also mac)
    entries: u16 = config.io_ring_size * 4,
};

pub const OpenError = error{
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
    Unexpected,
};
pub const AcceptError = error{
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
    Unexpected,
};
pub const ReadError = error{
    WouldBlock, // EAGAIN / EWOULDBLOCK
    InvalidFileDescriptor, // EBADF
    MemoryFault, // EFAULT
    Interrupted, // EINTR
    InvalidArgument, // EINVAL
    IoError, // EIO
    IsDirectory, // EISDIR
    OutOfMemory, // ENOMEM
    NoBufferSpace, // ENOBUFS
    Unexpected,
};
pub const SendError = error{
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
    Unexpected,
};
pub const WriteError = error{
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
    Unexpected,
};

pub const OpenOptions = struct {
    access_mode: enum { read, write, readwrite } = .readwrite,
    create_if_not_exist: bool = false,
    tmp_file: bool = false,
    is_directory: bool = false,
    //path only, does not open file/directory
    path: bool = false,
    truncate: bool = false,
};
pub const SendOptions = struct {
    //Tells link layer that, you do not need to
    //check if the neoghbor  is still alive
    no_confirm: bool = false,
    //Use when you have more data to send
    is_more_coming: bool = false,
    fastopend: bool = false,
};

//Operation to perform
pub const Operation = union(enum) {
    accept: struct {
        handle: Handle,
        addr: Address,
    },
    close: struct {
        handle: Handle,
    },
    openat: struct {
        handle: Handle,
        path: []const u8,
        options: OpenOptions,
    },
    read: struct {
        handle: Handle,
        buffer: []u8,
        offset: u64,
    },
    send: struct {
        socket: Handle,
        buffer: []const u8,
        options: SendOptions,
    },
    write: struct {
        handle: Handle,
        buffer: []const u8,
        offset: u64,
    },
};

//Return union(negligable size diffrence)
pub const CompletionReturn = union(enum) {
    accept: AcceptError!Handle,
    close: void,
    openat: OpenError!Handle,
    read: ReadError!usize,
    write: WriteError!usize,
    send: SendError!usize,
};

//submitted to IO
pub const Submission = struct {
    context: *anyopaque,
    op: Operation,
};
//returned from IO
pub const Completion = struct {
    context: *anyopaque,
    ret: CompletionReturn,
    pub fn formContext(c: *const Completion, T: type) *T {
        return @ptrCast(@alignCast(c.context));
    }
};
//Intermediate state of  a io request Submission -> IoEvent(internal) -> Completion
pub const Status = union(enum) { pending: Submission, complete: Completion };
pub const Event = struct {
    queue_id: usize,
    status: Status,
    next: ?*Event = null,
    pub inline fn fromSubmission(sub: *const Submission, queue_id: usize) Event {
        return .{
            .queue_id = queue_id,
            .status = .{ .pending = sub },
        };
    }
    pub inline fn toCompletion(event: *const Event) Completion {
        std.debug.assert(event.status == .complete);
        return event.status.complete;
    }
};
