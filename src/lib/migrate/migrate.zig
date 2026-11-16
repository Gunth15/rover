const std = @import("std");
const lib = @import("../lib.zig");
const sql = lib.Sqlite;

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

const MigrationRow = struct {
    version: u64,
    name: sql.Text,
    applied_at: ?sql.Text,
};
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
    \\CREATE TABLE IF NOT EXIST rover_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  applied_at DATETIME,
    \\  name TEXT NOT NULL UNIQUE,
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
    \\UPDATE migrations
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

inline fn migrationFailure(w: *std.Io.Writer, e: anyerror) void {
    w.interface.print("Migration command Failed: {s}\n", @errorName(e)) catch {};
}
pub fn create(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: []const u8,
    filename: []const u8,
) void {
    writer.interface.writeAll("[1/4] Checking database integrity\n") catch {};

    var db = initDb(io, migration_dir, database_file) catch |e| return migrationFailure(&writer, e);
    defer db.close();

    writer.interface.writeAll("[2/4] Updating migration directory\n") catch {};
    const name_writer: std.Io.Writer.Allocating = .init(allocator);
    defer name_writer.deinit();

    var v_stmt = db.prepare(GET_CURRENT_VERSION) catch |e| return migrationFailure(&writer, e);
    defer v_stmt.finalize();

    const version, _ = v_stmt.QueryOnce(struct { u64 }) catch |e| return migrationFailure(&writer, e);

    name_writer.writer.print("{d:0>4}_{s}.sql", .{ version, filename }) catch |e| migrationFailure(writer, e);
    const fname = name_writer.written();

    const new_migration = migration_dir.createFile(io, fname, .{}) catch |e| migrationFailure(writer, e);
    defer new_migration.close(io);
    new_migration.writeStreamingAll(io, MIGRATION_TEMPLATE) catch |e| migrationFailure(writer, e);

    writer.interface.writeAll("[3/4] Committing migration\n") catch {};
    var add_stmt = db.prepare(ADD_MIGRATION) catch |e| return migrationFailure(&writer, e);
    defer add_stmt.finalize();

    add_stmt.bind(1, fname) catch |e| return migrationFailure(&writer, e);
    add_stmt.exec() catch |e| return migrationFailure(&writer, e);

    writer.interface.writeAll("[4/4] Creation success\n") catch {};
}
pub fn upTo(
    io: std.Io,
    alllocator: std.mem.Allocator,
    writer: std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: []const u8,
    version: u64,
) void {
    var rbuff: [4096]u8 = undefined;
    writer.interface.writeAll("[1/4] Checking database integrity\n") catch {};
    var db = initDb(io, migration_dir, database_file) catch |e| return migrationFailure(&writer, e);
    defer db.close();

    writer.interface.writeAll("[2/4] Querying migrations\n") catch {};
    var get_smt = db.prepare(GET_MIGRATIONS_UP_TO_N) catch |e| migrationFailure(&writer, e);
    defer get_smt.finalize();

    get_smt.bind(1, version) catch |e| migrationFailure(&writer, e);

    var iter = get_smt.Query(MigrationRow) catch |e| migrationFailure(&writer, e);

    var update_smt = db.prepare(UPDATE_APPLIED_AT) catch |e| migrationFailure(&writer, e);
    defer update_smt.finalize();

    writer.interface.writeAll("[3/4] Applying migrations\n") catch {};
    while (iter.next() catch |e| migrationFailure(&writer, e)) {
        defer update_smt.reset();

        const row: MigrationRow = iter.row() catch |e| migrationFailure(&writer, e);

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
        update_smt.bind(1, row.version) catch |e| migrationFailure(&writer, e);
        update_smt.exec() catch |e| migrationFailure(writer, e);
    }
    writer.interface.print("[4/4] Database upgraded, databse version: {d}\n", .{version}) catch {};
}

pub fn downTo(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,
    migration_dir: std.Io.Dir,
    database_file: []const u8,
    version: u64,
) !void {
    var rbuff: [4096]u8 = undefined;
    writer.interface.writeAll("[1/4] Checking database integrity\n") catch {};
    var db = initDb(io, migration_dir, database_file) catch |e| return migrationFailure(&writer, e);
    defer db.close();

    writer.interface.writeAll("[2/4] Querying migrations\n") catch {};
    var get_smt = db.prepare(GET_MIGRATIONS_DOWN_TO_N) catch |e| migrationFailure(&writer, e);
    defer get_smt.finalize();

    get_smt.bind(1, version) catch |e| migrationFailure(&writer, e);

    var iter = get_smt.Query(MigrationRow) catch |e| migrationFailure(&writer, e);

    var del_smt = db.prepare() catch |e| migrationFailure(&writer, e);
    defer del_smt.finalize();

    writer.interface.writeAll("[3/4] Rolling back migrations\n") catch {};
    while (iter.next() catch |e| migrationFailure(&writer, e)) {
        defer del_smt.reset();

        const row: MigrationRow = iter.row() catch |e| migrationFailure(&writer, e);

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
        del_smt.bind(1, row.version) catch |e| migrationFailure(&writer, e);
        del_smt.exec() catch |e| migrationFailure(writer, e);
    }
    writer.interface.print("[4/4] Database rolled back, databse version: {d}\n", .{version}) catch {};
}
pub fn getVersion(writer: std.Io.Writer, database_file: []const u8) !void {}

inline fn initDb(io: std.Io, migration_dir: std.Io.Dir, database_file: []const u8) !sql {
    var db = try sql.open(database_file);
    defer db.close();

    try db.exec(CREATE_MIGRATION_TABLE_STATEMENT);

    var iter = migration_dir.iterate();
    while (try iter.next(io)) |entry| {
        const filename = entry.name;

        //INSERT INTO DATABSE IF NOT EXIST
        var add_stmt = try db.prepare(ADD_MIGRATION);
        defer add_stmt.finalize();

        try add_stmt.bind(1, filename);
        try add_stmt.exec();
    }

    return db;
}
