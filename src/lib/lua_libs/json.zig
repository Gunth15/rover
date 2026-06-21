const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
const LTest = lib.LTest;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Libs = [_]Lua.LuaLib{
    .{ "decode", decode },
    .{ "encode", encode },
    .{ "to_array", array },
    .{ "to_object", object },
};
const Scanner = struct {
    cursor: usize,
    tape: []const u8,
    arena: Allocator,
    lua: *Lua,
    const TokenType = enum {
        object_begin,
        object_end,
        array_begin,
        array_end,
        comma,
        colon,
        true,
        false,
        null,
        number,
        string,
        end_of_document,
    };
    pub const Token = union(enum) {
        object_begin,
        object_end,
        array_begin,
        array_end,
        true,
        false,
        null,
        number: f64,
        string: []const u8,
        end_of_document,
    };
    const ScannerError = error{
        UnexpectedCharacter,
        UnexpectedEndOfStream,
        UnexpectedEscapeCharacter,
        ExpectedComma,
        ExpectedColon,
        ExpectedQuotation,
        UnexpectedUnicode,
    } || Allocator.Error;
    pub fn init(arena: Allocator, lua: *Lua, str: []const u8) Scanner {
        return .{
            .tape = str,
            .cursor = 0,
            .arena = arena,
            .lua = lua,
        };
    }
    pub fn parseAndPush(s: *Scanner) ScannerError!void {
        while (try s.peekNextToken() != .end_of_document) try s.pushNext();
    }
    fn pushNext(s: *Scanner) ScannerError!void {
        return switch (try s.peekNextToken()) {
            .string => s.pushString(),
            .object_begin => s.pushObject(),
            .array_begin => s.pushArray(),
            .true => s.pushTrue(),
            .false => s.pushFalse(),
            .null => s.pushNull(),
            .number => s.pushNumber(),
            .end_of_document => {},
            else => ScannerError.UnexpectedCharacter,
        };
    }
    inline fn skipWhiteSpace(s: *Scanner) void {
        while (s.cursor < s.tape.len) : (s.cursor += 1) {
            switch (s.tape[s.cursor]) {
                ' ' => {},
                '\r' => {},
                '\t' => {},
                '\n' => {},
                else => return,
            }
        }
        return;
    }
    inline fn findNextWhiteSpace(s: *Scanner) ?usize {
        var cursor: usize = s.cursor;
        while (cursor < s.tape.len) : (cursor += 1) {
            switch (s.tape[cursor]) {
                ' ', '\r', '\t', '\n' => return cursor,
                else => continue,
            }
        }
        return null;
    }
    ///WARNING: Peek does not valiate the token is correct
    inline fn peekNextToken(s: *Scanner) ScannerError!TokenType {
        s.skipWhiteSpace();
        if (s.cursor >= s.tape.len) return .end_of_document;
        return switch (s.tape[s.cursor]) {
            '\"' => .string,
            '{' => .object_begin,
            '}' => .object_end,
            '[' => .array_begin,
            ']' => .array_end,
            ',' => .comma,
            ':' => .colon,
            't' => .true,
            'f' => .false,
            'n' => .null,
            '0'...'9', '-' => .number,
            else => return ScannerError.UnexpectedCharacter,
        };
    }
    inline fn takeNextToken(s: *Scanner) ScannerError!TokenType {
        const token = try s.peekNextToken();
        s.cursor += 1;
        return token;
    }
    inline fn takeUntilNextWhiteSpace(s: *Scanner) ?usize {
        const end = s.findNextWhiteSpace() orelse return null;
        s.cursor += end;
        return end;
    }
    fn takeString(s: *Scanner) ScannerError![]const u8 {
        var allocated = false;
        var allocated_str: std.ArrayList(u8) = .empty;

        if (s.tape[s.cursor] != '\"') return ScannerError.UnexpectedCharacter;
        s.cursor += 1;

        var pin = s.cursor - 1;
        while (s.tape[s.cursor] != '\"' and s.cursor < s.tape.len) : (s.cursor += 1) {
            switch (s.tape[s.cursor]) {
                '\\' => {
                    if (!allocated) allocated = true;
                    try allocated_str.appendSlice(s.arena, s.tape[pin..s.cursor]);
                    pin = s.cursor;
                    s.cursor += 1;
                    switch (s.tape[s.cursor]) {
                        '\"' => try allocated_str.append(s.arena, '\"'),
                        '\\' => try allocated_str.append(s.arena, '\\'),
                        '/' => try allocated_str.append(s.arena, '/'),
                        'b' => try allocated_str.append(s.arena, 0x08),
                        'f' => try allocated_str.append(s.arena, 0x0C),
                        'n' => try allocated_str.append(s.arena, 0x0A),
                        'r' => try allocated_str.append(s.arena, '\r'),
                        't' => try allocated_str.append(s.arena, '\t'),
                        'u' => {
                            const hexdigit = std.fmt.parseInt(u8, s.tape[s.cursor..4], 16) catch return ScannerError.UnexpectedUnicode;
                            s.cursor += 4;
                            try allocated_str.append(s.arena, hexdigit);
                        },
                        else => return ScannerError.UnexpectedEscapeCharacter,
                    }
                },
                else => continue,
            }
        }
        if (s.cursor >= s.tape.len) return ScannerError.ExpectedQuotation;
        s.cursor += 1;
        if (allocated) {
            const str = try allocated_str.toOwnedSlice(s.arena);
            return str[1 .. str.len - 1];
        } else return s.tape[pin + 1 .. s.cursor - 1];
    }
    fn pushString(s: *Scanner) ScannerError!void {
        const str = try s.takeString();
        s.lua.push(str);
    }
    fn pushObject(s: *Scanner) ScannerError!void {
        if (try s.takeNextToken() != .object_begin) return ScannerError.UnexpectedCharacter;
        s.lua.newTable();
        while (try s.peekNextToken() != .object_end) {
            const key = try s.takeString();
            if (try s.takeNextToken() != .colon) return ScannerError.ExpectedColon;
            try s.pushNext();
            s.lua.setField(-2, key);

            if (try s.peekNextToken() == .object_end) break;
            if (try s.peekNextToken() != .comma) return ScannerError.ExpectedComma;
            _ = try s.takeNextToken();
        }
        _ = s.takeNextToken() catch unreachable;
    }
    fn pushArray(s: *Scanner) ScannerError!void {
        //TODO: encode the length of the array beacuse of how nill works
        if (try s.takeNextToken() != .array_begin) return ScannerError.UnexpectedCharacter;
        s.lua.newTable();
        var i: usize = 1;
        while (try s.peekNextToken() != .array_end) : (i += 1) {
            try s.pushNext();
            s.lua.setI(-2, @intCast(i));
            if (try s.takeNextToken() != .comma) return ScannerError.ExpectedComma;
        }
        _ = s.takeNextToken() catch unreachable;
    }
    fn pushNull(s: *Scanner) ScannerError!void {
        const end = s.takeUntilNextWhiteSpace() orelse return ScannerError.UnexpectedEndOfStream;
        if (std.mem.eql(u8, s.tape[s.cursor..end], "null")) {
            s.lua.push(null);
        } else return ScannerError.UnexpectedCharacter;
    }
    inline fn pushTrue(s: *Scanner) ScannerError!void {
        if (s.cursor + 4 >= s.tape.len) return ScannerError.UnexpectedEndOfStream;
        if (std.mem.eql(u8, s.tape[s.cursor .. s.cursor + 4], "true")) {
            s.lua.push(true);
        } else return ScannerError.UnexpectedCharacter;
    }
    inline fn pushFalse(s: *Scanner) ScannerError!void {
        if (s.cursor + 5 >= s.tape.len) return ScannerError.UnexpectedEndOfStream;
        if (std.mem.eql(u8, s.tape[s.cursor .. s.cursor + 5], "false")) {
            s.lua.push(false);
        } else return ScannerError.UnexpectedCharacter;
    }
    inline fn pushNumber(s: *Scanner) ScannerError!void {
        const start: usize = s.cursor;
        while (try s.peekNextToken() == .number) s.cursor += 1;
        const float = std.fmt.parseFloat(f64, s.tape[start..s.cursor]) catch {
            return ScannerError.UnexpectedCharacter;
        };
        s.lua.push(float);
    }
};

const Builder = struct {
    const Error = error{
        UserDataNotSupported,
        FunctionNotSupported,
        CoroutineNotSupported,
        InvalidKeyType,
        InvalidJsonType,
        DataNotTable,
    } || Allocator.Error;
    lua: *Lua,
    buff: std.ArrayList(u8) = .empty,
    arena: Allocator,
    fn init(lua: *Lua, arena: Allocator) Builder {
        const arg = lua.getAbs(-1);
        defer lua.setTop(arg);
        return .{
            .lua = lua,
            .arena = arena,
        };
    }
    fn build(b: *Builder) Error!void {
        try b.buildLuaType();
        b.lua.push(b.buff.items);
    }
    fn buildObject(b: *Builder) Error!void {
        if (b.lua.getField(-1, "data") != .table) return Error.DataNotTable;
        try b.buff.append(b.arena, '{');

        b.lua.push(null);
        while (b.lua.Next(-2) != .nil) {
            //key copy and add it
            const key = b.lua.to(Lua.String, -2) catch return Error.InvalidKeyType;
            try b.buff.appendSlice(b.arena, key);
            try b.buff.append(b.arena, ':');
            try b.buildLuaType();
            try b.buff.append(b.arena, ',');
        }
        //Dont judge me
        b.buff.items.len -= 1;

        try b.buff.append(b.arena, '}');
    }
    fn buildArray(b: *Builder) Error!void {
        if (b.lua.getField(-1, "data") != .table) return Error.DataNotTable;
        try b.buff.append(b.arena, '[');

        b.lua.push(null);
        while (b.lua.Next(-2) != .nil) {
            try b.buildLuaType();
            try b.buff.append(b.arena, ',');
        }
        //Dont judge me
        b.buff.items.len -= 1;

        try b.buff.append(b.arena, ']');
    }
    ///Pops te value from the stack aswell as add to string builder
    fn buildLuaType(b: *Builder) Error!void {
        try switch (b.lua.Luatype(-1)) {
            .string => {
                //TODO: Handle special escaped characters
                const str = b.lua.to(Lua.String, -1) catch unreachable;
                try b.buff.append(b.arena, '"');
                try b.buff.appendSlice(b.arena, str);
                try b.buff.append(b.arena, '"');
            },
            .number => {
                const str = b.lua.to(Lua.String, -1) catch unreachable;
                try b.buff.appendSlice(b.arena, str);
            },
            .bool => {
                if (b.lua.to(Lua.Bool, -1) catch unreachable)
                    try b.buff.appendSlice(b.arena, "true")
                else
                    try b.buff.appendSlice(b.arena, "false");
            },
            .table => {
                try switch (b.jsonType() orelse return Error.InvalidJsonType) {
                    .array => b.buildArray(),
                    .object => b.buildObject(),
                };
            },
            .lightud, .ud => Error.UserDataNotSupported,
            .func => Error.FunctionNotSupported,
            .nil => try b.buff.appendSlice(b.arena, "null"),
            .nan => @panic("IDK how you got here. Good job."),
            .thread => Error.CoroutineNotSupported,
        };
        b.lua.pop(1);
    }
    fn jsonType(b: *Builder) ?enum { array, object } {
        //TODO: json.array and json.object functions needed for explicit encoding
        const table = b.lua.getAbs(-1);
        defer b.lua.setTop(table);

        if (b.lua.getField(-1, "__json_type") != .string) return null;
        const payload_type = b.lua.to(Lua.String, -1) catch unreachable;
        if (std.mem.eql(u8, "array", payload_type)) return .array;
        if (std.mem.eql(u8, "object", payload_type)) return .object;
        @panic("Invalid json type was found. Please use rover.json.array(array) or rover.json.object(object)");
    }
};

fn array(lua: *Lua) c_int {
    lua.check(1, .table);

    lua.newTable();

    lua.insert(1);
    lua.setField(-2, "data");

    lua.push("array");
    lua.setField(-2, "__json_type");
    return 1;
}
fn object(lua: *Lua) c_int {
    lua.check(1, .table);

    lua.newTable();

    lua.insert(1);
    lua.setField(-2, "data");

    lua.push("object");
    lua.setField(-2, "__json_type");
    return 1;
}
///Uses c allocator if no allocatr is given
fn decode(lua: *Lua) c_int {
    if (lua.getTop() != 1) lua.fmtError("Expected 1 argument", .{});
    lua.check(1, .string);
    const str = lua.to(Lua.String, -1) catch unreachable;

    var arena = alloc: {
        const alloc = lua.getAlloc() orelse std.heap.c_allocator;
        break :alloc std.heap.ArenaAllocator.init(alloc);
    };
    defer arena.deinit();

    const alloc = arena.allocator();
    var scanner = Scanner.init(alloc, lua, str);
    scanner.parseAndPush() catch |e| switch (e) {
        Scanner.ScannerError.UnexpectedCharacter => lua.fmtError("Unexpected character at byte %d", .{scanner.cursor}),
        Scanner.ScannerError.UnexpectedEndOfStream => lua.fmtError("Unexpected end of stream", .{}),
        Scanner.ScannerError.UnexpectedEscapeCharacter => lua.fmtError("Unexpected escape charcter at byte %d", .{scanner.cursor}),
        Scanner.ScannerError.ExpectedComma => lua.fmtError("Expected comma at byte %d", .{scanner.cursor}),
        Scanner.ScannerError.ExpectedColon => lua.fmtError("Expected colon colon at byte %d", .{scanner.cursor}),
        Scanner.ScannerError.ExpectedQuotation => lua.fmtError("Expected colon at byte %d", .{scanner.cursor}),
        Scanner.ScannerError.UnexpectedUnicode => lua.fmtError("Unexpected unicode around byte %d", .{scanner.cursor}),
        Scanner.ScannerError.OutOfMemory => lua.fmtError("System out of memory, unable to finish encoding", .{}),
    };
    return 1;
}
fn encode(lua: *Lua) c_int {
    const BuilderError = Builder.Error;
    if (lua.getTop() != 1) lua.fmtError("Expected 1 argument", .{});

    var arena = alloc: {
        const alloc = lua.getAlloc() orelse std.heap.c_allocator;
        break :alloc std.heap.ArenaAllocator.init(alloc);
    };
    defer arena.deinit();
    var builder = Builder.init(lua, arena.allocator());
    builder.build() catch |e| switch (e) {
        //TODO: InvalidJsonType not used
        BuilderError.InvalidJsonType => lua.fmtError("Invalid json type", .{}),
        BuilderError.FunctionNotSupported => lua.fmtError("Functions can not be serialized", .{}),
        BuilderError.InvalidKeyType => lua.fmtError("All table object keys must be convertable to a string", .{}),
        BuilderError.UserDataNotSupported => lua.fmtError("Userdata cannot be serialized", .{}),
        BuilderError.CoroutineNotSupported => lua.fmtError("Coroutines cannot be serialized", .{}),
        BuilderError.DataNotTable => lua.fmtError("Data field should be a table", .{}),
        Allocator.Error.OutOfMemory => lua.fmtError("OUT OF MEMORY", .{}),
    };
    return 1;
}

//TODO: do some fuzzing
//FUZZING DOES NOT WORK WITH C CODE YET
test "fuzz decode" {
    if (true) return;
    const decode_fuzz = struct {
        fn fuzz(_: void, smith: *std.testing.Smith) anyerror!void {
            var test_env = try LTest.init();
            defer test_env.deinit();

            var buf: [4096]u8 = undefined;
            smith.bytes(&buf);
            std.debug.print("BYTES: {s}", .{buf});
            try test_env.testFunc("decode", decode, .{&buf});
        }
    };
    try std.testing.fuzz({}, decode_fuzz.fuzz, .{});
}
