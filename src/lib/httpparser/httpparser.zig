const std = @import("std");
const libpico = @cImport(
    @cInclude("picohttpparser.h"),
);

pub const Headers = std.StringArrayHashMapUnmanaged([]const u8);
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    minor_version: u64,
    headers: *Headers,
};

const ParseError = error{
    PartialRequest,
    ParseFailure,
    TooManyHeaders,
    Chunked,
    InvalidBodyLength,
    NoMultiLineSupport,
};
//returns request with pointers to the given buffer
pub fn parse(buffer: []const u8, headers: *Headers, previously_read: usize) ParseError!Request {
    var req: Request = undefined;
    var method: [*c]const u8 = undefined;
    var method_len: usize = 0;
    var path: [*c]const u8 = undefined;
    var path_len: usize = 0;
    var minor_version: c_int = undefined;
    var header_list: [3]libpico.phr_header = undefined;
    var header_count: usize = header_list.len;

    const header_bytes = libpico.phr_parse_request(buffer.ptr, buffer.len, &method, &method_len, &path, &path_len, &minor_version, &header_list, &header_count, previously_read);
    if (header_bytes == -2) return error.PartialRequest;
    if (header_bytes == -1) return error.ParseFailure;

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

    const length = req.headers.get("Content-Length") orelse {
        req.body = null;
        return req;
    };
    const len = std.fmt.parseInt(usize, length, 10) catch return error.InvalidBodyLength;
    const header_len: usize = @intCast(header_bytes);
    req.body = buffer[header_len .. header_len + len];

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

    var headers = Headers.empty;
    defer headers.deinit(std.testing.allocator);

    try headers.ensureTotalCapacity(std.testing.allocator, 8);

    const req = try parse(request, &headers, 0);

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqual(@as(u64, 1), req.minor_version);

    const host = req.headers.get("Host").?;
    try std.testing.expectEqualStrings("example.com", host);

    const body = req.body.?;
    try std.testing.expectEqualStrings("hello", body);
}
