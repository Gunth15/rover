const std = @import("std");
const Io = std.Io;
const Lua = @import("../lua/Lua.zig");
const Reader = @import("../util/Reader.zig");
const Writer = @import("../util/Writer.zig");
const assert = std.debug.assert;

const STDERR: Io.File = .stderr();
const STDOUT: Io.File = .stdout();
const STDIN: Io.File = .stdin();

const Operation = union(enum) {
    CLOSE: Io.File,
    CLOCK: Io.Clock,
    RENAME: struct { oldname: []const u8, newname: []const u8 },
    EXIT: u8,
};

const FileWrapper = struct {
    file: std.Io.File,
    writer: ?std.Io.Writer = null,
    reader: ?std.Io.Reader = null,
};

//NOTE: does not implement io.tmpfile, io.input,io.output,io.popen,file:setvbuf
//
fn open(lua: *Lua) c_int {
    const Options = std.Io.Dir.OpenFileOptions;
    const args = lua.getTop();
    if (args > 2) lua.fmtError("Expected at most 2 arguments", .{});

    lua.check(1, .string);
    const filename = lua.to(Lua.String, 1) catch unreachable;

    var r_size: usize = 4096;
    var w_size: usize = 4096;
    var opts: Options = .{};
    if (args == 2) {
        lua.check(2, .string);
        if (lua.getField(2, "mode") == .string) {
            const mode = lua.to(Lua.String, -1) catch unreachable;
            opts.mode = std.meta.stringToEnum(Options.Mode, mode) orelse lua.argError(2,
                \\Invalid mode. Supported modes are "read_only", "write_only", and "read_write"
            );
        }
        if (lua.getField(2, "write_buffer_size") == .number) {
            w_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
            if (w_size < 0) lua.argError(2, "write_buffer_size must be a positive integer");
        }
        if (lua.getField(2, "read_buffer_size") == .number) {
            r_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
            if (r_size < 0) lua.argError(2, "read_buffer_size must be a positive integer");
        }
    }

    assert(lua.getField(Lua.RegistryIndex, "rover_io") == .lightud);
    const io = lua.toUserData(std.Io, -1);

    const file = std.Io.Dir.openFileAbsolute(io, filename, opts) catch |e| lua.fmtError("%s", .{@errorName(e)});
    const buff = lua.newUserDataRaw(@sizeOf(FileWrapper) + w_size + r_size) catch |e| lua.fmtError("%s", .{@errorName(e)});

    const wrapper: *FileWrapper = @ptrCast(@alignCast(buff[0..@sizeOf(FileWrapper)]));
    wrapper.file = file;
    wrapper.writer = file.writer(io, buff[@sizeOf(FileWrapper)..w_size]);
    wrapper.reader = file.reader(io, buff[(@sizeOf(FileWrapper) + w_size)..r_size]);

    return 1;
}
fn create(lua: *Lua) c_int {
    const Options = std.Io.Dir.CreateFileOptions;
    const args = lua.getTop();
    if (args > 2) lua.fmtError("Expected at most 2 arguments", .{});

    lua.check(1, .string);
    const filename = lua.to(Lua.String, 1) catch unreachable;

    var r_size: usize = 4096;
    var w_size: usize = 4096;
    if (args == 2) {
        lua.check(2, .table);

        var opts: Options = .{};
        if (lua.getField(2, "read") == .bool) opts.read = lua.to(Lua.Bool, -1) catch unreachable;
        if (lua.getField(2, "write_buffer_size") == .number) {
            w_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
            if (w_size < 0) lua.argError(2, "write_buffer_size must be a positive integer");
        }
        if (lua.getField(2, "read_buffer_size") == .number) {
            r_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
            if (r_size < 0) lua.argError(2, "read_buffer_size must be a positive integer");
        }
    }

    assert(lua.getField(Lua.RegistryIndex, "rover_io") == .lightud);
    const io = lua.toUserData(std.Io, -1);

    const file = std.Io.Dir.createFileAbsolute(io, filename, opts) catch |e| lua.fmtError("%s", .{@errorName(e)});
    const buff = lua.newUserDataRaw(@sizeOf(FileWrapper) + w_size + r_size) catch |e| lua.fmtError("%s", .{@errorName(e)});

    const wrapper: *FileWrapper = @ptrCast(@alignCast(buff[0..@sizeOf(FileWrapper)]));
    wrapper.file = file;
    wrapper.writer = file.writer(io, buff[@sizeOf(FileWrapper)..w_size]);
    wrapper.reader = file.reader(io, buff[(@sizeOf(FileWrapper) + w_size)..r_size]);

    return 1;
}
fn close(lua: *Lua) c_int {
    const args = lua.getTop();
    if (args != 1) lua.fmtError("Expected 1 argument", .{});
    lua.check(1, .ud);

    const file = lua.toUserData(FileWrapper, 1);
    const io = lua.toUserData(std.Io, -1);
    file.file.close(io);

    return 0;
}
fn read(lua: *Lua) c_int {
    const args = lua.getTop();
    if (args == 2) lua.fmtError("Expected 2 arguments", .{});
    lua.check(1, .ud);
    lua.check(2, .string);

    const file = lua.toUserData(FileWrapper, 1);
    const op = lua.toUserData(Lua.String, 2);
    if (file.reader) |r| {
        if (std.mem.eql(u8, "*n", op)) {}
        if (std.mem.eql(u8, "*l", op)) {}
        if (std.mem.eql(u8, "*a", op)) {} else {
            const n = std.fmt.parseInt(usize, op, 10) catch |e| lua.fmtError("%s", .{@errorName(e)});
            const readable = r.take(n) catch |e| lua.fmtError("%s", .{@errorName(e)});
            lua.push(readable);
        }
    } else lua.fmtError("File not initialized with read buffer", .{});
    return 1;
}
fn write(lua: *Lua) c_int {}
fn flush(lua: *Lua) c_int {
    const args = lua.getTop();
    if (args != 1) lua.fmtError("Expected 1 argument", .{});
    lua.check(1, .ud);

    const file = lua.toUserData(FileWrapper, 1);
    if (file.writer) |writer| writer.flush() catch lua.fmtError("%s", .{@errorName(e)})
        //
    else lua.fmtError("File not initialized with write buffer", .{});

    return 0;
}
fn input(lua: *Lua) c_int {}
fn file_seek(lua: *Lua) c_int {}
fn lines(lua: *Lua) c_int {}

//NOTE: doe snot implement os.getenv and os.tmpname
//os functions
fn clock(lua: *Lua) c_int {}
fn date(lua: *Lua) c_int {}
fn difftime(lua: *Lua) c_int {}
fn exit(lua: *Lua) c_int {}
fn rename(lua: *Lua) c_int {}
