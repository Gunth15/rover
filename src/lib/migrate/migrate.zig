const std = @import("std");
const lib = @import("../lib.zig");
const sql = lib.Sqlite;
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
    name: sql.Text,
    applied_at: ?sql.Text,
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
        var alloc_writer: std.Io.Writer.Allocating = try .init(allocator);
        defer alloc_writer.deinit();

        const token: Token = .begin;

        var mfile: MigrationFile = undefined;
        token: switch (token) {
            .begin => {
                if (std.mem.eql(u8, "-- RoverUp\n", try r.peek(11))) {
                    r.toss(11);
                    token = .rover_up;
                    break :token token;
                } else try r.streamExact(&alloc_writer.writer, 11);
                _ = try r.streamDelimiter(&alloc_writer.writer, '\n');
                break :token token;
            },
            .rover_up => {
                if (std.mem.eql(u8, "-- RoverDown\n", try r.peek(13))) {
                    r.toss(13);
                    mfile.up = try alloc_writer.toOwnedSlice();
                    alloc_writer.clearRetainingCapacity();
                    token = .rover_down;
                    break :token token;
                } else try r.streamExact(&alloc_writer.writer, 13);
                _ = try r.streamDelimiter(&alloc_writer.writer, '\n');
                break :token token;
            },
            .rover_down => {
                _ = try r.streamRemaining(&alloc_writer.writer);
                mfile.down = try alloc_writer.toOwnedSlice();
                token = .eof;
                break :token token;
            },
            .eof => {
                return mfile;
            },
        }
        unreachable;
    }
    fn deinit(self: *MigrationFile, allocator: std.mem.Allocator) void {
        allocator.free(self.up);
        allocator.free(self.down);
        self.* = undefined;
    }
};

fn printError(w: *std.Io.Writer, e: anyerror) void {
    w.print("{s}", .{@errorName(e)}) catch {};
    if (sql.err.messageFromError(e)) |message| {
        w.print(" (sqlite code {d}: {s})", .{ sql.err.codeFromError(e).?, message }) catch {};
    }
}

inline fn migrationFailure(w: *std.Io.Writer, e: anyerror) void {
    w.writeAll("Migration command Failed: ") catch {};
    printError(w, e);
    w.writeAll("\n") catch {};
}

pub fn create(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    filename: []const u8,
) !void {
    //TODO: remove allocator requirment since filames can only be 256 characters realistically
    writer.writeAll("[1/4] Checking database integrity\n") catch {};

    var db = try initDb(io, migration_dir, database_file);
    defer db.close();

    writer.writeAll("[2/4] Updating migration directory\n") catch {};
    var fname: std.ArrayList(u8) = .empty;
    defer fname.deinit(allocator);

    var v_stmt = try db.prepare(GET_CURRENT_VERSION);
    defer v_stmt.finalize();

    const version = (try v_stmt.QueryOnce(struct { u64 })).@"0";

    try fname.print(allocator, "{d:0>4}_{s}.sql", .{ version, filename });

    const new_migration = try migration_dir.createFile(io, fname.items, .{});
    defer new_migration.close(io);
    try new_migration.writeStreamingAll(io, MIGRATION_TEMPLATE);

    writer.writeAll("[3/4] Committing migration\n") catch {};
    var add_stmt = try db.prepare(ADD_MIGRATION);
    defer add_stmt.finalize();

    try add_stmt.bind(1, sql.Text{ .data = fname.items });
    try add_stmt.exec();

    writer.writeAll("[4/4] Creation success\n") catch {};
}
pub fn upTo(
    io: std.Io,
    alllocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    version: u64,
) void {
    var rbuff: [4096]u8 = undefined;
    writer.writeAll("[1/4] Checking database integrity\n") catch {};
    var db = initDb(io, migration_dir, database_file) catch |e| return migrationFailure(writer, e);
    defer db.close();

    writer.writeAll("[2/4] Querying migrations\n") catch {};
    var get_smt = db.prepare(GET_MIGRATIONS_UP_TO_N) catch |e| migrationFailure(writer, e);
    defer get_smt.finalize();

    get_smt.bind(1, version) catch |e| migrationFailure(writer, e);

    var iter = get_smt.Query(MigrationRow) catch |e| migrationFailure(writer, e);

    var update_smt = db.prepare(UPDATE_APPLIED_AT) catch |e| migrationFailure(writer, e);
    defer update_smt.finalize();

    writer.writeAll("[3/4] Applying migrations\n") catch {};
    while (iter.next() catch |e| migrationFailure(writer, e)) {
        defer update_smt.reset();

        const row: MigrationRow = iter.row() catch |e| migrationFailure(writer, e);

        //if not applied, apply it
        if (row.applied_at != null) continue;

        //Parse Migration file
        const fname = row.name;

        // Run necesarry migration
        const file = migration_dir.openFile(io, fname, .{}) catch |e| migrationFailure(writer, e);
        defer file.close(io);

        var reader = try file.reader(io, &rbuff);

        var migration = MigrationFile.parse(&reader, alllocator) catch |e| migrationFailure(writer, e);
        defer migration.deinit(alllocator);

        db.exec(migration.up) catch |e| migrationFailure(writer, e);

        //Update migration table
        update_smt.bind(1, row.version) catch |e| migrationFailure(writer, e);
        update_smt.exec() catch |e| migrationFailure(writer, e);
    }
    writer.print("[4/4] Database upgraded, databse version: {d}\n", .{version}) catch {};
}

pub fn downTo(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
    version: u64,
) !void {
    var rbuff: [4096]u8 = undefined;
    writer.writeAll("[1/4] Checking database integrity\n") catch {};
    var db = initDb(io, migration_dir, database_file) catch |e| return migrationFailure(writer, e);
    defer db.close();

    writer.writeAll("[2/4] Querying migrations\n") catch {};
    var get_smt = db.prepare(GET_MIGRATIONS_DOWN_TO_N) catch |e| migrationFailure(writer, e);
    defer get_smt.finalize();

    get_smt.bind(1, version) catch |e| migrationFailure(writer, e);

    var iter = get_smt.Query(MigrationRow) catch |e| migrationFailure(writer, e);

    var del_smt = db.prepare() catch |e| migrationFailure(writer, e);
    defer del_smt.finalize();

    writer.writeAll("[3/4] Rolling back migrations\n") catch {};
    while (iter.next() catch |e| migrationFailure(writer, e)) {
        defer del_smt.reset();

        const row: MigrationRow = iter.row() catch |e| migrationFailure(writer, e);

        //if not applied, apply it
        if (row.applied_at != null) continue;

        //Parse Migration file
        const fname = row.name;

        // Run necesarry migration
        const file = migration_dir.openFile(io, fname, .{}) catch |e| migrationFailure(writer, e);
        defer file.close(io);

        var reader = try file.reader(io, &rbuff);

        var migration = MigrationFile.parse(&reader, allocator) catch |e| migrationFailure(writer, e);
        defer migration.deinit(allocator);

        db.exec(migration.down) catch |e| migrationFailure(writer, e);

        //Update migration table
        del_smt.bind(1, row.version) catch |e| migrationFailure(writer, e);
        del_smt.exec() catch |e| migrationFailure(writer, e);
    }
    writer.print("[4/4] Database rolled back, databse version: {d}\n", .{version}) catch {};
}
pub fn getVersion(
    io: std.Io,
    writer: *std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
) !void {
    var db = initDb(io, migration_dir, database_file) catch |e| migrationFailure(writer, e);

    var stmt = db.prepare(GET_CURRENT_VERSION) catch |e| migrationFailure(writer, e);
    defer stmt.finalize();

    const version, _ = stmt.QueryOnce(struct { u64 }) catch |e| migrationFailure(writer, e);
    writer.print("Database version: {d:0>4}\n", .{version});
}
pub fn status(
    io: std.Io,
    writer: std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: [:0]const u8,
) !void {
    var db = initDb(io, migration_dir, database_file) catch |e| migrationFailure(writer, e);

    var stmt = db.prepare(GET_ALL_MIGRATIONS) catch |e| migrationFailure(writer, e);
    defer stmt.finalize();

    writer.writeAll("Applied At                  Migration  \n") catch {};
    writer.writeAll("=======================================\n") catch {};
    const iter = stmt.Query(MigrationRow);
    while (iter.next() catch |e| migrationFailure(writer, e)) {
        const mig = iter.row() catch |e| migrationFailure(writer, e);
        writer.print("{s} -- {s}\n", .{
            mig.applied_at.?,
            mig.name,
        }) catch {};
    }
}

inline fn initDb(io: std.Io, migration_dir: std.Io.Dir, database_file: [:0]const u8) !sql {
    var db = try sql.open(database_file);
    errdefer db.close();

    try db.exec(CREATE_MIGRATION_TABLE_STATEMENT);

    var iter = migration_dir.iterate();
    while (try iter.next(io)) |entry| {
        const filename = entry.name;

        //INSERT INTO DATABSE IF NOT EXIST
        var add_stmt = try db.prepare(ADD_MIGRATION);
        defer add_stmt.finalize();

        try add_stmt.bind(1, sql.Text{ .data = filename });
        try add_stmt.exec();
    }

    return db;
}

/// Harness for the "create migration file" test. It keeps the test setup in one
/// place and reports the SQLite code and message whenever creation fails.
fn runCreateMigrationFileTest(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    var path_buf: [4096]u8 = undefined;

    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    try test_dir.dir.createDirPath(io, "./migrations");
    const migration_dir = try test_dir.dir.openDir(io, "./migrations", .{ .iterate = true });

    const len = try test_dir.dir.realPath(io, &path_buf);

    var db_name: std.ArrayList(u8) = try .initCapacity(allocator, 4096 + 14);
    defer db_name.deinit(allocator);

    db_name.appendSliceAssumeCapacity(path_buf[0..len]);
    db_name.appendSliceAssumeCapacity("/database.sql");
    db_name.appendAssumeCapacity(0);

    create(io, allocator, writer, migration_dir, @as([:0]const u8, @ptrCast(db_name.items)), "test_migration") catch |e| {
        writer.writeAll("create migration file test failed: ") catch {};
        printError(writer, e);
        writer.writeAll("\n") catch {};
        return e;
    };
}

test "create migration file" {
    const io = std.testing.io;
    var wbuff: [4096]u8 = undefined;

    var writer = std.Io.File.stderr().writer(io, &wbuff);
    defer writer.flush() catch {};

    return runCreateMigrationFileTest(io, std.testing.allocator, &writer.interface);
}
test "can update db" {}
test "can rollback db" {}
test "can update db by 2 then go back up by two" {}
