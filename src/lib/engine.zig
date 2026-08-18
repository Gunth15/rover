const std = @import("std");
const Io = std.Io;
//load
//rerunble pre-compilation
const State = union(enum) {
    text,
    expr,
    statement,
    begin_inline,
    end_inline,
    lua,
    string: u8,
    assign,
    string_escape: u8,
    line_comment_start,
    line_comment,
    begin_bracket: u8, //level
    end_bracket: usize, //level
    end_of_text,
};

fn peekState(state: State, r: *Io.Reader) !State {
    switch (state) {
        .text => {
            const delim = r.peek(3) catch |e| return if (e == error.EndOfStream) .end_of_text else e;
            if (std.mem.eql(u8, delim, "<% ") or std.mem.eql(u8, delim, "<%=")) return .begin_inline;
            return .text;
        },
        .begin_inline => {
            const delim = try r.peek(3);
            if (std.mem.eql(u8, delim, "<% ")) return .statement;
            if (std.mem.eql(u8, delim, "<%=")) return .expr;
            return .text;
        },
        .end_inline => return .text,
        .statement => return .lua,
        .expr => return .lua,
        .lua => {
            switch (try r.peekByte()) {
                '"' => return .{ .string = '"' },
                '\'' => return .{ .string = '\'' },
                '-' => {
                    const delim = try r.peek(2);
                    if (std.mem.eql(u8, delim, "--")) return .line_comment_start;
                    return .lua;
                },
                '[' => return .{ .begin_bracket = 0 },
                ' ' => {
                    const delim = try r.peek(3);
                    if (std.mem.eql(u8, delim, " %>")) return .end_inline;
                    return .lua;
                },
                '@' => return .assign,
                else => return .lua,
            }
        },
        .assign => return .lua,
        .string => |byte| {
            const b = try r.peekByte();
            if (b == byte) return .lua;
            if (b == '\\') return .{ .string_escape = byte };
            return .{ .string = byte };
        },
        .string_escape => |byte| return .{ .string = byte },
        .line_comment_start => return .line_comment,
        .line_comment => {
            switch (try r.peekByte()) {
                '\n' => return .lua,
                '[' => return .{ .begin_bracket = 0 },
                else => return .line_comment,
            }
        },
        .begin_bracket => |level| {
            switch (try r.peekByte()) {
                '=' => return .{ .begin_bracket = level + 1 },
                '[' => return .{ .end_bracket = level },
                else => return .lua,
            }
        },
        .end_bracket => |level| {
            const pb = try r.peekByte();
            if (pb == '=') return .{ .end_bracket = level - 1 };
            if (level == 0 and pb == ']') return .lua;
            return .{ .end_bracket = level };
        },
        .end_of_text => return .end_of_text,
    }
}

pub fn compile(r: *Io.Reader, w: *Io.Writer) !void {
    try w.print("return function (context)\n", .{});
    try w.writeAll("\tlocal list = {}\n");
    try w.writeAll("\tlist[#list+1] = [===[\n");

    var state: State = try peekState(.text, r);
    while (true) {
        switch (state) {
            .expr => {
                try w.writeAll("\tlist[#list+1] = ");
                r.toss(3);
            },
            .assign => {
                r.toss(1);
                try w.writeAll("context.");
            },
            .statement => {
                try w.writeByte('\t');
                r.toss(3);
            },
            .begin_inline => try w.writeAll("]===]\n"),
            .end_inline => {
                try w.writeByte('\n');
                try w.writeAll("\tlist[#list+1] = [===[\n");
                r.toss(3);
            },
            .line_comment_start => try r.streamExact(w, 2),
            .text, .lua, .string, .string_escape, .line_comment, .begin_bracket, .end_bracket => try r.streamExact(w, 1),
            .end_of_text => {
                _ = try r.stream(w, .limited(3));
                try w.writeAll("]===]\n");
                break;
            },
        }
        state = try peekState(state, r);
    }
    try w.writeAll("\treturn table.concat(list,\"\")\n");
    try w.writeAll("end\n");
}
