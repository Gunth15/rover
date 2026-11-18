const std = @import("std");
const lib = @import("../lib.zig");
const Sql = lib.Sqlite;
const MIGRATION_TEMPLATE =
    \\-- RoverUp
    \\
    \\
    \\
    \\
    \\-- RoverDown
    \\
    \\
    \\
    \\
;
const CREATE_MIGRATION_TABLE_STATEMENT =
    \\CREATE TABLE IF NOT EXISTS rover_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  applied_at DATETIME,
    \\  name TEXT NOT NULL UNIQUE
    \\);
;

const ADD_MIGRATION =
    \\INSERT INTO rover_migrations (name, applied_at) 
    \\VALUES (?,NULL)
    \\ON CONFLICT(name) DO NOTHING;
    \\; 
;
const GET_CURRENT_VERSION =
    \\SELECT COALESCE(MAX(version),0)
    \\FROM rover_migrations
    \\WHERE applied_at IS NOT NULL
    \\;
;

const UPDATE_APPLIED_AT =
    \\UPDATE rover_migrations
    \\SET applied_at = CURRENT_TIMESTAMP
    \\WHERE version = ?;
;
const GET_MIGRATIONS_UP_TO_N =
    \\SELECT version, name, applied_at
    \\FROM rover_migrations 
    \\WHERE version <= ? AND version > (
    \\  SELECT COALESCE(MAX(version),0)
    \\  FROM rover_migrations
    \\  WHERE applied_at IS NOT NULL
    \\)
    \\ORDER BY version ASC; 
;
const GET_MIGRATIONS_DOWN_TO_N =
    \\SELECT version, name, applied_at
    \\FROM rover_migrations 
    \\WHERE version >= ? AND version < (
    \\  SELECT COALESCE(MAX(version),0)
    \\  FROM rover_migrations
    \\  WHERE applied_at IS NOT NULL
    \\)
    \\ORDER BY version DESC; 
;
const DELETE_MIGRATION =
    \\DELETE FROM rover_migrations
    \\WHERE version = ?;
;
const GET_ALL_MIGRATIONS =
    \\SELECT version, name, COALESCE(applied_at,"Pending")
    \\FROM rover_migrations 
    \\ORDER BY version ASC; 
;

const MigrationRow = struct {
    version: u64,
    name: Sql.Text,
    applied_at: ?Sql.Text,
};
const MigrationFile = struct {
    const Token = enum {
        begin,
        rover_up,
        rover_down,
        eof,
    };
    up: []const u8,
    down: []const u8,
    fn parse(r: *std.Io.Reader, allocator: std.mem.Allocator) !MigrationFile {
        var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
        defer alloc_writer.deinit();

        const RoverUp = "-- RoverUp\n";
        const RoverDown = "-- RoverDown\n";

        var mfile: MigrationFile = undefined;
        token: switch (Token.begin) {
            .begin => {
                if (std.mem.eql(u8, RoverUp, try r.peek(RoverUp.len))) {
                    r.toss(RoverUp.len);
                    continue :token .rover_up;
                }
                _ = try r.streamDelimiter(&alloc_writer.writer, '\n');
                _ = try r.streamExact(&alloc_writer.writer, 1);
                continue :token .begin;
            },
            .rover_up => {
                if (std.mem.eql(u8, RoverDown, try r.peek(RoverDown.len))) {
                    r.toss(RoverDown.len);
                    mfile.up = try alloc_writer.toOwnedSlice();
                    alloc_writer.clearRetainingCapacity();
                    continue :token .rover_down;
                }
                _ = try r.streamDelimiter(&alloc_writer.writer, '\n');
                _ = try r.streamExact(&alloc_writer.writer, 1);
                continue :token .rover_up;
            },
            .rover_down => {
                _ = try r.streamRemaining(&alloc_writer.writer);
                mfile.down = try alloc_writer.toOwnedSlice();
                continue :token .eof;
            },
            .eof => return mfile,
        }
        unreachable;
    }
    fn deinit(self: *MigrationFile, allocator: std.mem.Allocator) void {
        allocator.free(self.up);
        allocator.free(self.down);
        self.* = undefined;
    }
};

inline fn migrationFailure(w: *std.Io.Writer, e: anyerror) void {
    w.writeAll("Migration command Failed: ") catch {};
    w.print("{s}", .{@errorName(e)}) catch {};
    if (Sql.err.messageFromError(e)) |message| {
        w.print(" (Sqlite code {d}: {s})", .{ Sql.err.codeFromError(e).?, message }) catch {};
    }
    w.writeAll("\n") catch {};
}

pub fn create(
    io: std.Io,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    filename: []const u8,
) !void {
    //TODO: remove allocator requirment since filames can only be 256 characters realistically
    var db = try initDb(io, migration_dir, database_file);
    defer db.close();

    var name_buff: [256]u8 = undefined;
    var fname: std.ArrayList(u8) = .initBuffer(&name_buff);

    var v_stmt = try db.prepare(GET_CURRENT_VERSION);
    defer v_stmt.finalize();

    const version = (try v_stmt.QueryOnce(struct { u64 })).@"0";

    try fname.printBounded("{d:0>4}_{s}.sql", .{ version, filename });

    const new_migration = try migration_dir.createFile(io, fname.items, .{});
    defer new_migration.close(io);
    try new_migration.writeStreamingAll(io, MIGRATION_TEMPLATE);

    var add_stmt = try db.prepare(ADD_MIGRATION);
    defer add_stmt.finalize();

    try add_stmt.bind(1, Sql.Text{ .data = fname.items });
    try add_stmt.exec();
}
pub fn upTo(
    io: std.Io,
    alllocator: std.mem.Allocator,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    version: u64,
) !void {
    var rbuff: [4096]u8 = undefined;
    var db = try initDb(io, migration_dir, database_file);
    defer db.close();

    var get_smt = try db.prepare(GET_MIGRATIONS_UP_TO_N);
    defer get_smt.finalize();

    try get_smt.bind(1, version);

    var iter = get_smt.Query(MigrationRow);

    var update_smt = try db.prepare(UPDATE_APPLIED_AT);
    defer update_smt.finalize();

    while (try iter.next()) {
        const row: MigrationRow = try iter.row();

        //if not applied, apply it
        if (row.applied_at != null) continue;

        //Parse Migration file
        const fname = row.name;

        // Run necesarry migration
        const file = try migration_dir.openFile(io, fname.data, .{});
        defer file.close(io);

        var reader = file.reader(io, &rbuff);

        var migration = try MigrationFile.parse(&reader.interface, alllocator);
        defer migration.deinit(alllocator);

        try db.exec(migration.up);

        //Update migration table
        try update_smt.bind(1, row.version);
        try update_smt.exec();
        try update_smt.reset();
    }
}

pub fn downTo(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    version: u64,
) !void {
    var rbuff: [4096]u8 = undefined;
    var db = try initDb(io, migration_dir, database_file);
    defer db.close();

    var get_smt = try db.prepare(GET_MIGRATIONS_DOWN_TO_N);
    defer get_smt.finalize();

    try get_smt.bind(1, version);

    var iter = get_smt.Query(MigrationRow);

    var del_smt = try db.prepare(DELETE_MIGRATION);
    defer del_smt.finalize();

    while (try iter.next()) {
        const row: MigrationRow = try iter.row();

        //if not applied, apply it
        if (row.applied_at != null) continue;

        //Parse Migration file
        const fname = row.name;

        // Run necesarry migration
        const file = try migration_dir.openFile(io, fname.data, .{});
        defer file.close(io);

        var reader = file.reader(io, &rbuff);

        var migration = try MigrationFile.parse(&reader.interface, allocator);
        defer migration.deinit(allocator);

        try db.exec(migration.down);

        //Update migration table
        try del_smt.bind(1, row.version);
        try del_smt.exec();
        try del_smt.reset();
    }
}
pub fn getVersion(
    io: std.Io,
    writer: *std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
) !void {
    var db = try initDb(io, migration_dir, database_file);

    var stmt = try db.prepare(GET_CURRENT_VERSION);
    defer stmt.finalize();

    const version, _ = try stmt.QueryOnce(struct { u64 });
    writer.print("Database version: {d:0>4}\n", .{version});
}
pub fn status(
    io: std.Io,
    writer: std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
) !void {
    var db = try initDb(io, migration_dir, database_file);

    var stmt = try db.prepare(GET_ALL_MIGRATIONS);
    defer stmt.finalize();

    writer.writeAll("Applied At                  Migration  \n") catch {};
    writer.writeAll("=======================================\n") catch {};
    const iter = stmt.Query(MigrationRow);
    while (try iter.next()) {
        const mig = try iter.row();
        writer.print("{s} -- {s}\n", .{
            mig.applied_at.?,
            mig.name,
        }) catch {};
    }
}

inline fn initDb(io: std.Io, migration_dir: std.Io.Dir, database_file: [:0]const u8) !Sql {
    var db = try Sql.open(database_file);
    errdefer db.close();

    try db.exec(CREATE_MIGRATION_TABLE_STATEMENT);

    var iter = migration_dir.iterate();
    while (try iter.next(io)) |entry| {
        const filename = entry.name;

        //INSERT INTO DATABSE IF NOT EXIST
        var add_stmt = try db.prepare(ADD_MIGRATION);
        defer add_stmt.finalize();

        try add_stmt.bind(1, Sql.Text{ .data = filename });
        try add_stmt.exec();
    }

    return db;
}

fn initTestEnvironment(
    io: std.Io,
    allocator: std.mem.Allocator,
) !struct { std.testing.TmpDir, std.Io.Dir, std.ArrayList(u8) } {
    var path_buf: [4096]u8 = undefined;

    var test_dir = std.testing.tmpDir(.{});

    try test_dir.dir.createDirPath(io, "./migrations");
    errdefer test_dir.cleanup();

    const migration_dir = try test_dir.dir.openDir(io, "./migrations", .{ .iterate = true });

    const len = try test_dir.dir.realPath(io, &path_buf);

    var db_name: std.ArrayList(u8) = try .initCapacity(allocator, 4096 + 14);
    errdefer db_name.deinit(allocator);

    db_name.appendSliceAssumeCapacity(path_buf[0..len]);
    db_name.appendSliceAssumeCapacity("/database.sql");
    db_name.appendAssumeCapacity(0);

    return .{ test_dir, migration_dir, db_name };
}

const TEST_MIGRATION =
    \\-- RoverUp
    \\CREATE TABLE books (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    author TEXT
    \\);
    \\
    \\-- RoverDown
    \\DROP TABLE books;
    \\
;
test "create migration file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp, const migration_dir, var db_name = try initTestEnvironment(io, allocator);
    defer {
        tmp.cleanup();
        db_name.deinit(allocator);
    }

    create(io, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), "test_migration") catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to create migration test: {s}", .{err});
        return e;
    };
}
test "can update db" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp, const migration_dir, var db_name = try initTestEnvironment(io, allocator);
    defer {
        tmp.cleanup();
        db_name.deinit(allocator);
    }

    create(io, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), "test_migration") catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to create migration test: {s}", .{err});
        return e;
    };

    var f = try migration_dir.openFile(io, "0000_test_migration.sql", .{ .mode = .write_only });
    try f.writeStreamingAll(io, TEST_MIGRATION);
    f.close(io);

    upTo(io, allocator, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), 1) catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to update test: {s}", .{err});
        return e;
    };
}
test "can rollback db" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp, const migration_dir, var db_name = try initTestEnvironment(io, allocator);
    defer {
        tmp.cleanup();
        db_name.deinit(allocator);
    }

    create(io, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), "test_migration") catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to create migration test: {s}", .{err});
        return e;
    };

    var f = try migration_dir.openFile(io, "0000_test_migration.sql", .{ .mode = .write_only });
    try f.writeStreamingAll(io, TEST_MIGRATION);
    f.close(io);

    upTo(io, allocator, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), 1) catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to update test: {s}", .{err});
        return e;
    };

    downTo(io, allocator, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), 0) catch |e| {
        const err: [:0]const u8 = Sql.err.messageFromError(e) orelse @errorName(e);
        std.testing.failPrint("Failed to update test: {s}", .{err});
        return e;
    };
}
