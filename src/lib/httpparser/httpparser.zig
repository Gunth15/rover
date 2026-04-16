const std = @import("std");
const libpico = @cImport(
    @cInclude("picohttpparser.h"),
);

pub const Headers = std.StringArrayHashMapUnmanaged([]const u8);
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    minor_version: u64,
    headers: Headers,
    //size of request in bytes
    //TODO: make this optional to handle chunck encoding
    size: usize,
};

const ParseError = error{
    PartialRequest,
    ParseFailure,
    TooManyHeaders,
    Chunked,
    InvalidBodyLength,
    NoMultiLineSupport,
    OutOfMemory,
};
//returns request with pointers to the given buffer
//headers are allocated with the capacity of max_headers
pub fn parse(buffer: []const u8, alloc: std.mem.Allocator, max_headers: usize, previously_read: usize) ParseError!Request {
    var req: Request = undefined;
    var method: [*c]const u8 = undefined;
    var method_len: usize = 0;
    var path: [*c]const u8 = undefined;
    var path_len: usize = 0;
    var minor_version: c_int = undefined;
    var headers = Headers.empty;
    var header_list: []libpico.phr_header = try alloc.alloc(libpico.phr_header, max_headers);
    defer alloc.free(header_list);

    var header_count: usize = header_list.len;

    const header_bytes = libpico.phr_parse_request(buffer.ptr, buffer.len, &method, &method_len, &path, &path_len, &minor_version, header_list.ptr, &header_count, previously_read);
    if (header_bytes == -2) return error.PartialRequest;
    if (header_bytes == -1) return error.ParseFailure;
    try headers.ensureUnusedCapacity(alloc, header_count);

    req.method = method[0..method_len];
    req.path = path[0..path_len];
    req.minor_version = @intCast(minor_version);
    req.headers = headers;

    for (header_list[0..header_count]) |header| {
        //TODO: handle multiline headers
        const name = if (header.name != null) header.name[0..header.name_len] else return error.NoMultiLineSupport;
        const value = if (header.value != null) header.value[0..header.value_len] else unreachable;

        req.headers.putAssumeCapacity(name, value);
    }

    const header_len: usize = @intCast(header_bytes);
    req.size = header_len;

    const encoding = req.headers.get("Transfer-Encoding") orelse return req;
    if (std.ascii.eqlIgnoreCase("chunked", encoding)) return error.Chunked;
    return req;
}
test "parse basic HTTP request with body" {
    const request =
        "POST /hello HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    var req = try parse(request, std.testing.allocator, 10, 0);
    defer req.headers.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqual(@as(u64, 1), req.minor_version);

    const host = req.headers.get("Host").?;
    try std.testing.expectEqualStrings("example.com", host);

    const req_size = req.size;
    try std.testing.expect(request.len - 5 == req_size);
}
