const lib = @import("../lib.zig");
const std = @import("std");
const c = @import("c");
pub const err = @import("errors.zig");

pub const Text = struct { data: []const u8 };
pub const Blob = struct { data: []const u8 };
pub const Statement = @import("Statement.zig");

db: *c.sqlite3,

const Sqlite = @This();
pub fn open(filename: []const u8) error{SQLiteError}!Sqlite {
    var db = Sqlite{
        .db = undefined,
    };
    const result_code = c.sqlite3_open(filename, &db.db);

    if (result_code != c.SQLITE_OK) return error.SQLiteError;

    return db;
}
pub fn prepare(db: *Sqlite, statement: []const u8) !Statement {
    var stmt: Statement = .{ .stmt = undefined };
    c.sqlite3_prepare_v2(db.db, statement, @intCast(statement.len), &stmt.stmt, null);
}

pub fn errmsg(db: *Sqlite) [:0]const u8 {
    return c.sqlite3_errmsg(db.db);
}
pub fn close(db: *Sqlite) void {
    c.sqlite3_close(&db.db);
}

pub fn errstr(rc: c_int) [:0]const u8 {
    return c.sqlite3_errstr(rc);
}
