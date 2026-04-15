const std = @import("std");

const Writer = @This();

const Slice = struct {
    first: []u8,
    second: []u8,
};

start: usize = 0,
end: usize = 0,
buf: []u8,

pub fn init(alloc: std.mem.Allocator, n: usize) !Writer {
    std.debug.assert(std.math.isPowerOfTwo(n));
    return .{
        .buf = try alloc.alloc(u8, n),
    };
}

pub fn deinit(w: *Writer, alloc: std.mem.Allocator) void {
    alloc.free(w.buf);
}

/// pending data to send (same idea as reader.peek)
pub fn pending(w: *Writer) Slice {
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
pub fn hasPendingBytes(w: *Writer) bool {
    return (w.end - w.start) > 0;
}

/// free space to write into (like reader.free)
pub fn fill(w: *Writer, data: []const u8) usize {
    const cap = w.buf.len;
    const free_bytes = cap - (w.end - w.start);
    const n = @min(data.len, free_bytes);
    if (n == 0) return 0;
    const end = w.end & (cap - 1);
    const l1 = @min(n, cap - end);
    @memcpy(w.buf[end .. end + l1], data[0..l1]);
    const l2 = n - l1;
    if (l2 > 0) @memcpy(w.buf[0..l2], data[l1..n]);
    w.advance(n);
    return n;
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
