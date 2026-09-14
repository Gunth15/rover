const std = @import("std");
const lib = @import("../../lib.zig");
const Runtime = lib.Runtime;
const Io = std.Io;
const Lua = lib.Lua;
const runtime_log = std.log.scoped(.runtime);

const FailEntry = struct {
    test_name: []const u8,
    reason: []const u8,
};
const TestStatus = union(enum) {
    pass: void,
    fail: FailEntry,
};
const TestFileR = struct {
    file_name: []const u8,
    entries: []TestStatus,
};
const TestFileReturn = union(enum) {
    status: TestFileR,
};

const LibRover = @embedFile("../librover.lua");
pub fn runTestMode(r: *Runtime, test_dir_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const io = r.io;

    var writer = Io.File.stderr().writer(io, &buf);
    defer writer.flush() catch {};

    const test_dir = try Io.Dir.cwd().openDir(io, test_dir_path, .{ .iterate = true });

    var select: Io.Select(TestFileReturn) = .init(io, try r.allocator.alloc(TestFileReturn, 100));
    errdefer _ = select.cancel();

    var iter = test_dir.iterate();
    var filecount: usize = 0;
    while (try iter.next(r.io)) |entry| {
        switch (entry.kind) {
            .file => {
                select.async(.status, startTestEnv, .{ r, entry, test_dir });
                filecount += 1;
            },
            else => continue,
        }
    }

    var pass: usize = 0;
    var fail: usize = 0;
    while (filecount > 0) : (filecount -= 1) {
        const ret = try select.await();
        var first_fail = true;
        for (ret.status.entries) |entry| {
            switch (entry) {
                .pass => pass += 1,
                .fail => |fail_entry| {
                    if (first_fail) {
                        writer.interface.print("{s}\n", .{ret.status.file_name}) catch {};
                        first_fail = false;
                    }
                    writer.interface.print("\t({s}) ERROR:\t{s}\n", .{ fail_entry.test_name, fail_entry.reason }) catch {};
                    fail += 1;
                },
            }
        }
    }
    writer.interface.print("{s}\nPASS: {d}\tFAIL: {d}\n", .{ "-" ** 30, pass, fail }) catch {};
}

inline fn startTestEnv(r: *Runtime, entry: Io.Dir.Entry, test_dir: Io.Dir) TestFileR {
    const io = r.io;
    var buff: [256]u8 = undefined;
    const len = test_dir.realPathFile(io, entry.name, &buff) catch |e| @panic(@errorName(e));
    var list: std.ArrayList(TestStatus) = .empty;

    const file_name = r.allocator.dupeZ(u8, buff[0..len]) catch |e| @panic(@errorName(e));

    var lua = Lua.init(.{ .allocator = &r.allocator }) catch |e| @panic(@errorName(e));
    defer lua.deinit();

    lua.openLibs();
    Runtime.openLibRoverNoLVM(r, &lua);

    lua.doFile(file_name) catch |e| @panic(@errorName(e));

    //Add core lib
    const core_file = @embedFile("core.lua");
    lua.doString(core_file) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        @panic(err);
    };
    const core_idx = lua.getAbs(-1);

    //Run test
    if (lua.getGlobal("rover") != .table) @panic("TODO: ERROR");
    if (lua.getField(-1, "test") != .func) @panic("TODO: ERROR");
    lua.remove(-2);
    lua.insert(core_idx);
    lua.pcall(1, 1) catch {
        const err = lua.to(Lua.String, -1) catch unreachable;
        @panic(err);
    };

    //Run each test in the file
    if (lua.getField(-1, "tests") != .table) @panic("TODO: ERROR");
    const tests_idx = lua.getAbs(-1);
    lua.push(null);
    while (lua.Next(tests_idx) != .nil) {
        const value_idx = lua.getAbs(-1);
        const key_idx_top = lua.getTop() - 1;

        if (lua.Luatype(value_idx) != .table) @panic("TODO: Error");

        if (lua.getField(value_idx, "name") != .string) @panic("TODO: Error");
        const func_name = lua.to(Lua.String, -1) catch unreachable;
        lua.pop(1); // pop name string now that we've read it

        if (lua.getField(value_idx, "func") != .func) @panic("TODO: Error");

        const status: TestStatus = run_test: {
            lua.pcall(0, 0) catch {
                const err = lua.to(Lua.String, -1) catch unreachable;
                lua.pop(1); // pop error message
                break :run_test .{
                    .fail = .{
                        .test_name = r.allocator.dupe(u8, func_name) catch |e| @panic(@errorName(e)),
                        .reason = r.allocator.dupe(u8, err) catch |e| @panic(@errorName(e)),
                    },
                };
            };
            break :run_test .{ .pass = {} };
        };

        lua.setTop(key_idx_top);
        list.append(r.allocator, status) catch |e| @panic(@errorName(e));
    }
    return .{
        .file_name = std.fs.path.basename(file_name),
        .entries = list.items,
    };
}
