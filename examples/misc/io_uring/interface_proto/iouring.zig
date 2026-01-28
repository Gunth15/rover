const std = @import("std");
const IOHandle = @import("iohandle");
iouring: std.os.linux.IoUring,
event_pool: HandlePool,
fd_pool: FDPool,
pinnable: std.ArrayList(usize),

const Self = @this();
const FDPool = std.ArrayList(std.posix.fd_t);
const HandlePool = std.ArrayList(IOHandle);

//TODO: handle shrink and growth, right now, only growth is supported
pub const Options = struct {
    entries: u16 = 128,
    flags: u32,
};
pub fn init(gpa: std.mem.Allocator, opt: Options) !Self {
    const entries = opt.entries;
    const flags = opt.flags;

    var iouring: std.os.linux.IoUring = try .init(entries,flags);
    var event_pool: HandlePool = try .initCapacity(gpa, entries);
    var fd_pool: FDPool = try .initCapacity(gpa, entries);
    var pinnable: std.ArrayList(usize) = try .initCapacity(gpa, entries);

    return .{
        .iouring = iouring,
        .event_pool = event_pool,
        .fd_pool = fd_pool,
        .pinnable = pinnable,
    };
}
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.iouring.deinit();
    self.event_pool.deinit(gpa);
    self.pinnable.deinit(gpa);
}
inline fn getMemeber(self: *Self) struct{std.posix.fd_t, IOHandle} {

}
//NOTE: If no members available, allocate memory to increase pool size
inline fn setMemeber(self: *Self, gpa: std.mem.Allocator, conn: Connection) !usize {
    if (self.pinnable.pop()) |idx| return idx; 
    try self.pinnable.append(gpa,self.pinnable.len);
    const idx = self.pinnable.pop().?; 
    //new memebers should always be placed at the end of each list in a perfect world
    try self.event_pool.insert(gpa,idx handle);
    return idx
}
inline fn unpinMemeber(self: *Self) void {
    return self.pinnable.appendAssumeCapacity() 
}
pub fn submit_file(self: *Self, e: IOHandle) {

}
pub fn submit_listener(self: *Self, e: IOHandle) {
    //Do the whole tcp listener handshake
    const handle
    
    _ = try self.iouring.accept_multishot(,server.stream.handle,null,null,0);

}
pub fn submit_connection(self: *Self, e: IOHandle) {

}
