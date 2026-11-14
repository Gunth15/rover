const std = @import("std");
const lib = @import("../lib.zig");
const sqlite = @import("sqlite3.zig");
const err = sqlite.err;
const Blob = sqlite.Blob;
const Text = sqlite.Text;
const c = @import("c");

stmt: *c.sqlite3_stmt,

const Statement = @This();

fn Iterator(T: type) type {
    return struct {
        const Self = @This();
        stmt: Statement,
        pub fn next(self: *Self) err.Error!bool {
            const ret = c.sqlite3_step(self.stmt.stmt);

            if (ret == c.SQLITE_ROW) return true else if (ret == c.SQLITE_DONE) {
                self.stmt.reset();
                return false;
            }

            return err.translate(ret) orelse return false;
        }
        pub fn row(self: *Self) err.Error!T {
            return try self.stmt.row(T);
        }
        pub fn column(self: *Self, i: usize) err.Error!T {
            try self.stmt.column(T, i);
        }
    };
}
pub inline fn deinit(stmt: *Statement) err.Error!void {
    return err.translate(c.sqlite3_finalize(stmt.stmt)) orelse {};
}
inline fn reset(stmt: *Statement) !void {
    return err.translate(c.sqlite3_reset(stmt.stmt));
}
const TypeError = error{
    UnexpectedType,
    NotNullable,
    ExpectedBlob,
    ExpectedText,
    ExpectedFloat,
    ExpectedInt64,
};

//NOTE: blobs and strings are borrowed
pub inline fn row(stmt: *Statement, T: type) TypeError!T {
    const info = @typeInfo(T);
    comptime if (info != .@"struct") @compileError("Sqlite can rows must be mapped to a struct");

    const ret: T = .{};

    inline for (0.., info.@"struct".fields) |i, field| {
        @field(ret, field.name) = stmt.column(field.type, i);
    }
    return ret;
}

//NOTE: blobs and strings are borrowed
pub inline fn column(stmt: *Statement, T: type, i: usize) TypeError!T {
    const info = @typeInfo(T);

    switch (c.sqlite3_column_type(stmt.stmt, i)) {
        c.SQLITE_INTEGER => {
            if (info != .number) return TypeError.ExpectedInt64;
            const int: i64 = c.sqlite3_column_int64(stmt.stmt, i);
            return @intCast(int);
        },
        c.SQLITE_FLOAT => {
            if (info != .float) return TypeError.ExpectedFloat;
            const float: f64 = c.sqlite3_column_double(stmt.stmt, i);
            return float;
        },
        c.SQLITE_TEXT => {
            if (T != sqlite.Text) return TypeError.ExpectedText;
            const blob: *const anyopaque = c.sqlite3_column_text(stmt.stmt, i);
            return sqlite.Text{ .data = @ptrCast(@alignCast(blob)) };
        },
        c.SQLITE_BLOB => {
            if (T != sqlite.Blob) return TypeError.ExpectedBlob;
            const blob: *const anyopaque = c.sqlite3_column_blob(stmt.stmt, i);
            return sqlite.Blob{ .data = @ptrCast(@alignCast(blob)) };
        },
        c.SQLITE_NULL => {
            if (info != .optional) return TypeError.NotNullable;
            return null;
        },
    }
}

pub inline fn exec(stmnt: *Statement) err.Error!void {
    defer stmnt.reset();
    return err.translate(c.sqlite3_step(stmnt.stmt)) orelse {};
}
//NOTE: blobs and strings are borrowed
pub inline fn Query(stmnt: *Statement, T: type) Iterator(T) {
    return Iterator(T){
        .stmt = stmnt,
    };
}
//NOTE: blobs and strings are borrowed
pub inline fn QueryOnce(stmnt: *Statement, T: type) err.Error!T {
    return err.translate(c.sqlite3_step(stmnt.stmt)) orelse {
        defer stmnt.reset();
        return try stmnt.row(T);
    };
}

//copies buffers for simplicity
pub inline fn binds(stmnt: *Statement, values: anytype) err.Error!void {
    const info = @typeInfo(@TypeOf(values));
    comptime if (info != .@"struct") @compileError("Sqlite can only multi-bind with a struct");
    const fields: []const std.meta.Type.StructField = info.@"struct".fields;

    for (fields, 0..) |field, i| {
        const value = @field(values, field.n);
        try stmnt.bind(i, value);
    }
}
pub inline fn bind(stmnt: *Statement, idx: usize, value: anytype) err.Error!void {
    return switch (@typeInfo(value)) {
        .int => stmnt.bindInt(idx, value),
        .float => stmnt.bindDouble(idx, value),
        .null => stmnt.bindNull(idx),
        .optional => if (value) |v| stmnt.bind(v) else stmnt.bindNull(idx),
        .@"struct" => if (@TypeOf(value) == Blob) stmnt.bindBlob(idx, value.data) else if (@TypeOf(value) == Text) stmnt.bindBlob(idx, value.data) else @compileError("Unsupported type"),
        else => @compileError("Unsupported type"),
    };
}
pub inline fn bindText(stmnt: *Statement, idx: usize, value: []const u8) err.Error!void {
    return err.translate(
        c.sqlite3_bind_text64(
            stmnt.stmt,
            idx,
            value,
            value.len,
            c.SQLITE_TRANSIENT,
        ),
    );
}
pub inline fn bindBlob(stmnt: *Statement, idx: usize, value: []const u8) err.Error!void {
    return err.translate(
        c.sqlite3_bind_blob64(
            stmnt.stmt,
            idx,
            value,
            value.len,
            c.SQLITE_TRANSIENT,
        ),
    );
}
pub inline fn bindInt(stmnt: *Statement, idx: usize, int: isize) err.Error!void {
    return err.translate(
        c.sqlite3_bind_int64(
            stmnt.stmt,
            idx,
            @as(c_int, @intCast(int)),
        ),
    );
}
pub inline fn bindDouble(stmnt: *Statement, idx: usize, double: f64) err.Error!void {
    return err.translate(
        c.sqlite3_bind_double(
            stmnt.stmt,
            idx,
            double,
        ),
    );
}
pub inline fn bindNull(stmnt: *Statement, idx: usize) err.Error!void {
    return err.translate(
        c.sqlite3_bind_null(
            stmnt.stmt,
            idx,
        ),
    );
}
