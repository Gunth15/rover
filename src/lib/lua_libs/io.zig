const std = @import("std");
const Io = std.Io;
const Lua = @import("../lua/Lua.zig");
const Reader = @import("../util/Reader.zig");
const Writer = @import("../util/Writer.zig");

const STDERR: Io.File = .stderr();
const STDOUT: Io.File = .stdout();
const STDIN: Io.File = .stdin();

const Operation = union(enum) {
    READ: *Io.File.Reader,
    WRITE: *Io.File.Writer,
    CLOSE: Io.File,
    CLOCK: Io.Clock,
    RENAME: struct { oldname: []const u8, newname: []const u8 },
    EXIT: u8,
};

//NOTE: does not implement io.input,io.output,io.popen,file:setvbuf
//
fn open(lua: *Lua) c_int {}
fn close(lua: *Lua) c_int {}
fn read(lua: *Lua) c_int {}
fn write(lua: *Lua) c_int {}
fn tmpfile(lua: *Lua) c_int {}
fn type(lua: *Lua) c_int {}
fn flush(lua: *Lua) c_int {}
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
