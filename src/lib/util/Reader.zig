//Ring buffer for reading from
//NOTE: will crash when eventual over flow
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
pub fn deinit(r: *Reader, alloc: std.mem.Allocator) void {
    alloc.free(r.buf);
}

//returns the amount of bytes read
pub fn peek(r: *Reader, buf: []u8) usize {
    const available = r.end - r.start;
    const to_copy = @min(available, buf.len);

    const cap = r.buf.len;
    const start = r.start & (cap - 1);

    const l1 = @min(to_copy, cap - start);
    @memcpy(buf[0..l1], r.buf[start .. start + l1]);

    const l2 = to_copy - l1;
    if (l2 > 0) @memcpy(buf[l1 .. l1 + l2], r.buf[0..l2]);

    return to_copy;
}

//fille the buffer with the given data, return how many bytes written
pub fn fill(r: *Reader, buf: []const u8) usize {
    const cap = r.buf.len;
    const end = r.end & (cap - 1);

    //free space available capacity - used
    const free = cap - r.end - r.start;

    const to_add = @min(buf.len, free);

    const l1 = @min(to_add, cap - end);
    @memcpy(r.buf[end .. end + l1], buf[0..l1]);

    const l2 = to_add - l1;
    if (l2) @memcpy(r.buf[0..l2], buf[l1 .. l1 + l2]);

    r.advanceTail(to_add);
    return to_add;
}
//advance head n bytes
pub fn advanceHead(r: *Reader, n: usize) void {
    r.start += n;
}
//extend used n bytes
pub fn advanceTail(r: *Reader, n: usize) void {
    r.end += n;
}

test "basic fill and peek" {
    const testing = std.testing;
    var alloc = testing.allocator;
    var r = Reader.init(alloc, 8);
    defer alloc.free(r.buf);

    const data = "abcd";
    _ = r.fill(data);

    var out: [4]u8 = undefined;
    const n = r.peek(&out);

    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("abcd", &out);
}

test "peek partial buffer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var r = Reader.init(alloc, 8);
    defer r.deinit(alloc);

    _ = r.fill("abcdef");

    var out: [3]u8 = undefined;
    const n = r.peek(&out);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("abc", &out);
}

test "advanceHead works" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var r = Reader.init(alloc, 8);
    defer r.deinit(alloc);

    _ = r.fill("abcdef");

    r.advanceHead(3);

    var out: [3]u8 = undefined;
    const n = r.peek(&out);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("def", &out);
}

test "wrap around fill + peek" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var r = Reader.init(alloc, 8);
    defer r.deinit(alloc);

    _ = r.fill("abcdef");
    r.advanceHead(6); // consume everything

    // now force wrap
    _ = r.fill("wxyz");

    var out: [4]u8 = undefined;
    const n = r.peek(&out);

    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("wxyz", &out);
}

test "wrap around read across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var r = Reader.init(alloc, 8);
    defer r.deinit(alloc);

    _ = r.fill("abcdef");
    r.advanceHead(4); // remaining: "ef"

    _ = r.fill("wxyz"); // causes wrap

    var out: [6]u8 = undefined;
    const n = r.peek(&out);

    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("efwxyz", &out);
}
