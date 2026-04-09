const std = @import("std");

const Writer = @This();

const Slice = struct {
    first: []u8,
    second: []u8,
};

start: usize = 0,
end: usize = 0,
buf: []u8,

pub fn init(alloc: std.mem.Allocator, n: usize) Writer {
    std.debug.assert(std.math.isPowerOfTwo(n));
    return .{
        .buf = alloc.alloc(u8, n),
    };
}

pub fn deinit(w: *Writer, alloc: std.mem.Allocator) void {
    alloc.free(w.buf);
}

/// pending data to send (same idea as reader.peek)
pub fn peek(w: *Writer) Slice {
    const available = w.end - w.start;

    const cap = w.buf.len;
    const start = w.start & (cap - 1);

    const l1 = @min(available, cap - start);
    const l2 = available - l1;

    return Slice{
        .first = w.buf[start .. start + l1],
        .second = w.buf[0..l2],
    };
}

/// free space to write into (like reader.free)
pub fn pending(w: *Writer) ?Slice {
    const available = w.end - w.start;
    if (available == 0) return null;

    const cap = w.buf.len;
    const start = w.start & (cap - 1);

    const l1 = @min(available, cap - start);
    const l2 = available - l1;

    return Slice{
        .first = w.buf[start .. start + l1],
        .second = w.buf[0..l2],
    };
}

pub fn advance(w: *Writer, n: usize) void {
    w.end += n;
}

/// consume n bytes after send completes
pub fn consume(w: *Writer, n: usize) void {
    w.start += n;
}

pub fn reset(w: *Writer) void {
    w.start = 0;
    w.end = 0;
}
