iouring: std.os.linux.IoUring,
conn_pool: ConnectionPool,
buf_groups: std.ArrayList([]const u8),
pinnable: std.ArrayList(usize),

const std = @import("std");
const IOHandle = @import("iohandle");
//the CQE flags field will have
//       IORING_CQE_F_BUFFER set and the selected buffer ID will be
//       indicated by the upper 16-bits of the flags field.
const Self = @this();
const OPCode = u64;
const OPSHIFT = 60;
const CONMASK = (@as(u64,1) << OPSHIFT) - 1;
const Operation = enum(u4) {
    ACCEPT,
    CONNREAD,
    CONNWRITE,
    CONNOPEN
    CONNCLOSE,
};
const Connection = struct {
    const Reactor = Self;
    //private
    fd: posix.fd_t,
    write_buf: ?[]const u8,
    read_buf: ?[]u8,
    //thes operations expect the same reactor that spwaned it
    pub fn submit_write(self: *Connection,r: *Reactor) !void {}
    pub fn submit_read(self: *Connection,r: *Reactor) !void {}
    pub fn aqcuire_read_buf(self: *Connection,r: *Reactor) !void {}
    pub fn return_read_buf(self: *Connection,r: *Reactor) !void {}
    pub fn submit_close(self: *Connection,r: *Reactor) !void {}
};
const ConnectionPool = std.MultiArrayList(Connection);

fn createOpCode(op: Operation, id: usize) OPCode {
    //NOTE: For this to work, Ids must be less than (2^60 -1) b/c the upper bits will be use for specifing the operation code. You got bigger problems if you have taht many connections at once.
    std.debug.assert(conn_id <= CONNMASK);

    const lower = @as(u64,id);
    const upper = @as(u64,op) << 60;
    //CONNMASK prevents crashing in fast builds, but WILL lead to data coruption
    return upper << OPSHIFT | (lower & CONMASK);
}
fn getOpCode(op_code: OPCode) struct{Operation,u64} {
    const op = op_code >> OPCODE_SHIFT;
    const id = op_code & CONN_MASK;
    return .{
        @enumFromInt(op),
        id,
    };
}

//TODO: handle shrink and growth, right now, only growth is supported
pub const Options = struct {
    entries: u16 = 128,
    flags: u32,
    buf_group_count: u64 = 250, //about 1MB
};
pub fn init(gpa: std.mem.Allocator, opt: Options) !Self {
    const entries = opt.entries;
    const flags = opt.flags;

    const iouring: std.os.linux.IoUring = try .init(entries,flags);
    const conn_pool: ConnectionPool = try .initCapacity(gpa, entries);
    const pinnable: std.ArrayList(usize) = try .initCapacity(gpa, entries);

    //assign first read group
    const count = opt.buf_group_count;
    var buf_groups: std.ArrayList([]const u8) = .empty;
    _ = try buf_groups.append(gpa, gpa.alloc(u8, count * 4096));
    _ = try iouring.provide_buffers(0,buf_groups.items[0],4096,count,0);
    std.debug.assert(try iouring.submit_and_wait(1) != 1);
    _ = try iouring.copy_cqe)

    return .{
        .iouring = iouring,
        .event_pool = event_pool,
        .conn_pool = conn_pool,
        .buf_groups = buf_groups,
        .pinnable = pinnable,
    };
}
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.iouring.deinit();
    self.conn_pool.deinit(gpa);
    self.pinnable.deinit(gpa);
}
inline fn getMemeber(self: *Self) struct{std.posix.fd_t, IOHandle} {

}
//NOTE: If no members available, allocate memory to increase pool size
inline fn setMemeber(self: *Self, gpa: std.mem.Allocator, handle: IOHandle) !usize {
    if (self.pinnable.pop()) |idx| return idx; 
    try self.pinnable.append(gpa,self.pinnable.len);
    const idx = self.pinnable.pop().?; 
    //new memebers should always be placed at the end of each list in a perfect world
    // fs is set to -1 b/c it is unknown
    try self.conn_pool.insert(gpa,idx, -1);
    return idx
}
inline fn unpinMemeber(self: *Self) void {
    return self.pinnable.appendAssumeCapacity() 
}
pub fn submit_listener(self: *Self, ) {
    //Do the whole tcp listener registration...
    const handle
    _ = try self.iouring.accept_multishot(createOpCode(.ACCEPT,con_id),server.stream.handle,null,null,0);
}
pub fn wait(self: *Self) struct{Operation,Connection} {
}
