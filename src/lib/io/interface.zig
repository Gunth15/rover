//This file contains the public interface that a OS needs to implement to work correctly
const std = @import("std");
const buitin = @import("builtin");
const IoUring = std.os.linux.IoUring;
const Address = std.net.Address;
const posix = std.posix;

pub const Handle = switch (buitin.os.tag) {
    .linux => std.os.linux.fd_t,
    .windows => union {
        handle: std.os.windows.HANDLE,
        socket: std.os.windows.ws2_32.SOCKET,
    },
    else => @compileError("Not implemented yet"),
};

pub const Options = struct {
    //Linux only(possibly also mac)
    entries: u16 = 256,
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

///Operation to perform
pub const Vec = switch (buitin.os.tag) {
    .linux => extern struct {
        ptr: [*]const u8,
        len: usize,
        pub fn toIoVecSlice(slice: []Vec) []posix.iovec {
            comptime {
                std.debug.assert(@sizeOf(Vec) == @sizeOf(posix.iovec));
                std.debug.assert(@alignOf(Vec) == @alignOf(posix.iovec));
            }
            return @ptrCast(slice);
        }
        pub fn toConstIoVecSlice(slice: []const Vec) []const posix.iovec_const {
            comptime {
                std.debug.assert(@sizeOf(Vec) == @sizeOf(posix.iovec));
                std.debug.assert(@alignOf(Vec) == @alignOf(posix.iovec));
            }
            return @ptrCast(slice);
        }
    },
    else => @compileError("Os not supported yet"),
};
pub const Operation = union(enum) {
    accept: struct {
        handle: Handle,
        addr: *Address,
        addr_len: posix.socklen_t = @sizeOf(std.net.Address),
    },
    accept_multishot: struct {
        handle: Handle,
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
        vec: []Vec,
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
    writev: struct {
        handle: Handle,
        vec: []const Vec,
        offset: u64,
    },
};

///Return union(negligable size diffrence)
pub const CompletionReturn = union(enum) {
    accept: AcceptError!Handle,
    accept_multishot: AcceptError!Handle,
    close: void,
    openat: OpenError!Handle,
    read: ReadError!usize,
    write: WriteError!usize,
    writev: WriteError!usize,
    send: SendError!usize,
};

///Intermediate state of  a io request Submission -> IoEvent(internal) -> Completion
///the next field is use to chain events like a queue
pub const Status = union(enum) { pending: Operation, complete: CompletionReturn };
pub const Event = struct {
    context: *anyopaque,
    status: Status,
    //used for queue
    next: ?*Event = null,
    pub inline fn accept(context: *anyopaque, handle: Handle, addr: *Address) Event {
        const submission: Operation = .{
            .accept = .{
                .handle = handle,
                .addr = addr,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn accept_multishot(context: *anyopaque, handle: Handle) Event {
        const submission: Operation = .{
            .accept_multishot = .{
                .handle = handle,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn openat(context: *anyopaque, handle: Handle, path: []u8, options: OpenOptions) Event {
        const submission: Operation = .{
            .openat = .{
                .handle = handle,
                .path = path,
                .options = options,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn read(context: *anyopaque, handle: Handle, vec: []Vec, offset: u64) Event {
        const submission: Operation = .{
            .read = .{
                .vec = vec,
                .handle = handle,
                .offset = offset,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn write(context: *anyopaque, handle: Handle, buffer: []const u8, offset: u64) Event {
        const submission: Operation = .{
            .write = .{
                .handle = handle,
                .buffer = buffer,
                .offset = offset,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn writev(context: *anyopaque, handle: Handle, vec: []Vec, offset: u64) Event {
        const submission: Operation = .{
            .writev = .{
                .handle = handle,
                .vec = vec,
                .offset = offset,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn send(context: *anyopaque, handle: Handle, buffer: []const u8, options: SendOptions) Event {
        const submission: Operation = .{
            .send = .{
                .socket = handle,
                .buffer = buffer,
                .options = options,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
    pub inline fn close(context: *anyopaque, handle: Handle) Event {
        const submission: Operation = .{
            .close = .{
                .handle = handle,
            },
        };
        return .{ .context = context, .status = .{ .pending = submission } };
    }
};
