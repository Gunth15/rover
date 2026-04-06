//Ring buffer for reading from
start: usize = 0,
end: usize = 0,
buf: []u8,

const std = @import("std");
const Reader = @This();

pub fn init(alloc: std.mem.Allocator, n: usize) Reader {
    std.debug.assert(std.math.isPowerOfTwo(n));
    return .{
        .buf = alloc.alloc(u8, n),
    };
}

pub fn peek(r: *Reader) void {
    const start = @min(r.start & (r.buf - 1), r.end & (r.buf - 1));
    const end = @max(r.start & (r.buf - 1), r.end & (r.buf - 1));
    return r.buf[start..end];
}

///returns free memory in buffer
pub fn free(r: *Reader) []u8 {
    const start = @max(r.start & (r.buf - 1), r.end & (r.buf - 1));
    return r.buf[start..];
}
//advance head n bytes
pub fn advanceHead(r: *Reader, n: usize) void {
    r.start += n;
}
//extend used n bytes
pub fn advanceTail(r: *Reader, n: usize) void {
    r.end += n;
}
