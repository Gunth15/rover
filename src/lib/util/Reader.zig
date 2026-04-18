//Ring buffer for reading from
//NOTE: will crash when eventual over flow
start: usize = 0,
end: usize = 0,
buf: []u8,

const std = @import("std");
const Reader = @This();

const Slice = struct {
    first: []u8,
    second: []u8,
};

pub fn init(alloc: std.mem.Allocator, n: usize) !Reader {
    const size = try std.math.ceilPowerOfTwo(usize, n);
    return .{
        .buf = try alloc.alloc(u8, size),
    };
}
pub fn deinit(r: *Reader, alloc: std.mem.Allocator) void {
    alloc.free(r.buf);
}

//returns the amount of bytes read
pub fn peek(r: *Reader) Slice {
    const available = r.end - r.start;

    const cap = r.buf.len;
    const start = r.start & (cap - 1);

    const l1 = @min(available, cap - start);
    const l2 = available - l1;

    return Slice{
        .first = r.buf[start .. start + l1],
        .second = r.buf[0..l2],
    };
}

//returns free buffer space
pub fn free(r: *Reader) Slice {
    const cap = r.buf.len;
    const end = r.end & (cap - 1);

    //free space available capacity - used
    const free_bytes = cap - (r.end - r.start);

    const l1 = @min(free_bytes, cap - end);
    const l2 = free_bytes - l1;
    const slice = Slice{
        .first = r.buf[end .. end + l1],
        .second = r.buf[0..l2],
    };
    return slice;
}
//advance head n bytes
pub fn consume(r: *Reader) Slice {
    const slice = r.peek();
    const n = slice.first.len + slice.second.len;
    r.consumeHead(n);
    return slice;
}
pub fn consumeHead(r: *Reader, n: usize) void {
    r.start += n;
}
//extend used n bytes
pub fn advance(r: *Reader, n: usize) void {
    r.end += n;
}

pub fn reset(r: *Reader) void {
    r.start = 0;
    r.end = 0;
}

test "fresh reader is empty" {
    var r = try Reader.init(std.testing.allocator, 16);
    defer r.deinit(std.testing.allocator);

    const s = r.peek();
    try std.testing.expectEqual(@as(usize, 0), s.first.len);
    try std.testing.expectEqual(@as(usize, 0), s.second.len);
}

test "free returns full capacity on empty buffer" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    const s = r.free();
    try std.testing.expectEqual(@as(usize, 8), s.first.len + s.second.len);
}

test "write bytes via free slice then peek them back" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    const payload = "hello";
    const f = r.free();
    @memcpy(f.first[0..payload.len], payload);
    r.advance(payload.len);

    const s = r.peek();
    try std.testing.expectEqual(payload.len, s.first.len + s.second.len);
    try std.testing.expectEqualStrings(payload, s.first[0..payload.len]);
}

test "free space shrinks after advance" {
    var r = try Reader.init(std.testing.allocator, 16);
    defer r.deinit(std.testing.allocator);

    r.advance(6);
    const s = r.free();
    try std.testing.expectEqual(@as(usize, 10), s.first.len + s.second.len);
}

test "consumeHead moves start forward" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    const f = r.free();
    f.first[0] = 'A';
    f.first[1] = 'B';
    r.advance(2);

    r.consumeHead(1);
    const s = r.peek();
    try std.testing.expectEqual(@as(usize, 1), s.first.len + s.second.len);
    try std.testing.expectEqual(@as(u8, 'B'), s.first[0]);
}

test "consumeHead all bytes leaves buffer empty" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    r.advance(4);
    r.consumeHead(4);

    const s = r.peek();
    try std.testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "consume returns all bytes and empties buffer" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    const f = r.free();
    f.first[0] = 'X';
    f.first[1] = 'Y';
    r.advance(2);

    const s = r.consume();
    try std.testing.expectEqual(@as(usize, 2), s.first.len + s.second.len);

    const after = r.peek();
    try std.testing.expectEqual(@as(usize, 0), after.first.len + after.second.len);
}

test "data wraps around end of buffer correctly" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    // push end to index 6, then consume — head sits at 6
    r.advance(6);
    r.consumeHead(6);

    // write 4 bytes spanning the wrap boundary
    const f = r.free();
    f.first[0] = 'W';
    f.first[1] = 'X';
    if (f.first.len >= 4) {
        f.first[2] = 'Y';
        f.first[3] = 'Z';
    } else {
        f.second[0] = 'Y';
        f.second[1] = 'Z';
    }
    r.advance(4);

    const s = r.peek();
    var out: [4]u8 = undefined;
    @memcpy(out[0..s.first.len], s.first);
    @memcpy(out[s.first.len .. s.first.len + s.second.len], s.second);
    try std.testing.expectEqualSlices(u8, "WXYZ", &out);
}

test "free slice wraps correctly" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    // end at physical index 7, consume 5 — 1 byte before physical end, 5 after wrap
    r.advance(7);
    r.consumeHead(5);

    const f = r.free();
    try std.testing.expectEqual(@as(usize, 6), f.first.len + f.second.len);
    try std.testing.expectEqual(@as(usize, 1), f.first.len);
    try std.testing.expectEqual(@as(usize, 5), f.second.len);
}

test "reset clears start and end" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    r.advance(5);
    r.consumeHead(3);
    r.reset();

    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 0), r.end);

    const s = r.peek();
    try std.testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "reset allows full buffer reuse" {
    var r = try Reader.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    r.advance(8);
    r.reset();

    const f = r.free();
    try std.testing.expectEqual(@as(usize, 8), f.first.len + f.second.len);
}
