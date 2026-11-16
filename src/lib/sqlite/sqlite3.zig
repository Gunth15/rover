const lib = @import("../lib.zig");
const std = @import("std");
const c = @import("c");
pub const err = @import("errors.zig");

pub const Text = struct { data: []const u8 };
pub const Blob = struct { data: []const u8 };
pub const Statement = @import("Statement.zig");

//TODO:  Give user option to pass custom allocator on creation
db: ?*c.sqlite3 = null,

const Sqlite = @This();

pub fn open(filename: [:0]const u8) err.Error!Sqlite {
    var db = Sqlite{
        .db = null,
    };
    const result_code = c.sqlite3_open(filename, &db.db);

    return err.errorFromCode(result_code) orelse db;
}
pub fn prepare(db: *Sqlite, statement: []const u8) err.Error!Statement {
    var stmt: Statement = .{ .stmt = null };
    return err.errorFromCode(c.sqlite3_prepare_v2(db.db, statement.ptr, @intCast(statement.len), &stmt.stmt, null)) orelse stmt;
}
pub fn exec(db: *Sqlite, statement: []const u8) err.Error!void {
    var stmt = try db.prepare(statement);
    defer stmt.finalize();
    try stmt.exec();
}

pub fn errmsg(db: *Sqlite) [:0]const u8 {
    return c.sqlite3_errmsg(db.db);
}
pub fn close(db: *Sqlite) void {
    _ = c.sqlite3_close(db.db);
}

pub fn errstr(rc: c_int) [:0]const u8 {
    return c.sqlite3_errstr(rc);
}

test "open database and create a table" {
    var db: Sqlite = try .open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, author TEXT);");
}
test "Make a single query" {
    const Number = struct {
        int: i64,
    };
    var db: Sqlite = try .open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE number (id INTEGER PRIMARY KEY);");
    try db.exec("INSERT INTO number (id) VALUES (1);");

    var stmt = try db.prepare("SELECT id FROM number WHERE id=?");
    defer stmt.finalize();
    try stmt.bind(1, 1);

    const n = try stmt.QueryOnce(Number);
    try std.testing.expectEqual(1, n.int);
}
test "Make a query for multiple rows" {
    const Number = struct {
        int: i64,
    };
    var db: Sqlite = try .open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE number (id INTEGER PRIMARY KEY);");
    try db.exec("INSERT INTO number (id) VALUES (1);");
    try db.exec("INSERT INTO number (id) VALUES (2);");
    try db.exec("INSERT INTO number (id) VALUES (3);");
    try db.exec("INSERT INTO number (id) VALUES (4);");
    try db.exec("INSERT INTO number (id) VALUES (5);");

    var stmt = try db.prepare("SELECT id FROM number ORDER BY id ASC;");
    defer stmt.finalize();

    var it = stmt.Query(Number);
    var expected: i64 = 1;

    while (try it.next()) : (expected += 1) {
        const n = try it.row();
        try std.testing.expectEqual(expected, n.int);
    }
}
test "strings" {
    const Book = struct {
        id: i64,
        text: Text,
    };
    var db: Sqlite = try .open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE book (id INTEGER PRIMARY KEY, text TEXT);");
    try db.exec("INSERT INTO book (id, text) VALUES (1, 'hello');");

    var stmt = try db.prepare("SELECT * FROM book WHERE id = 1;");
    defer stmt.finalize();

    const book = try stmt.QueryOnce(Book);
    try std.testing.expectEqualStrings("hello", book.text.data);
}
test "blobs" {
    const Book = struct {
        id: i64,
        text: Blob,
    };
    var db: Sqlite = try .open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE book (id INTEGER PRIMARY KEY, text BLOB);");
    try db.exec("INSERT INTO book (id,text) VALUES (1, X'68656C6C6F');");

    var stmt = try db.prepare("SELECT * FROM book WHERE id = 1;");
    defer stmt.finalize();

    const book = try stmt.QueryOnce(Book);
    try std.testing.expectEqualStrings("hello", book.text.data);
}
