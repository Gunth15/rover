const std = @import("std");
const lib = @import("../../lib.zig");
const Runtime = lib.Runtime;
const Io = std.Io;
const Lua = lib.Lua;
const LVM = lib.LVM;
const operations = lib.operation;

const core_source = @embedFile("core.lua");

const driver_source =
    \\return function(tests)
    \\    local results = {}
    \\    for _, t in pairs(tests) do
    \\        local ok, err = pcall(t.func)
    \\        results[#results + 1] = {
    \\            name = t.name,
    \\            ok = ok,
    \\            err = (not ok) and tostring(err) or nil,
    \\        }
    \\    end
    \\    return results
    \\end
;

const FailEntry = struct {
    test_name: []const u8,
    reason: []const u8,
};
const TestStatus = union(enum) {
    pass: void,
    fail: FailEntry,
};

const FileJob = struct {
    io: Io,
    done: *Io.Semaphore,
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    name: []const u8,
    entries: std.ArrayList(TestStatus) = .empty,

    inline fn recordFailure(job: *FileJob, test_name: []const u8, reason: []const u8) void {
        job.entries.append(job.arena.allocator(), .{
            .fail = .{ .test_name = test_name, .reason = reason },
        }) catch @panic("Out of memory");
    }

    inline fn takeError(job: *FileJob, lua: *Lua) []const u8 {
        const msg = lua.to(Lua.String, -1) catch return "unknown error";
        defer lua.pop(1);

        return job.arena.allocator().dupe(u8, msg) catch @panic("Out of memory");
    }

    inline fn fieldString(job: *FileJob, lua: *Lua, idx: anytype, field: anytype) ?[]const u8 {
        if (lua.getField(idx, field) != .string) return null;
        defer lua.pop(1);

        const s = lua.to(Lua.String, -1) catch return null;
        return job.arena.allocator().dupe(u8, s) catch @panic("Out of memory");
    }

    inline fn finish(job: *FileJob) void {
        job.done.post(job.io);
    }

    inline fn setup(job: *FileJob, lua: *Lua) ?[]const u8 {
        lua.doFile(job.path) catch return job.takeError(lua);

        lua.doString(core_source) catch return job.takeError(lua);
        const core_idx = lua.getAbs(-1);

        if (lua.getGlobal("rover") != .table) return "global `rover` is not a table";
        if (lua.getField(-1, "test") != .func) return "`rover.test` is not a function";
        lua.remove(-2);
        lua.insert(core_idx);
        lua.pcall(1, 1) catch return job.takeError(lua);

        if (lua.getField(-1, "tests") != .table) return "test suite has no `tests` table";
        const tests_idx = lua.getAbs(-1);

        lua.doString(driver_source) catch return job.takeError(lua);
        lua.insert(tests_idx);
        return null;
    }

    inline fn collect(job: *FileJob, lua: *Lua) void {
        const results_idx = lua.getAbs(-1);
        lua.push(null);
        while (lua.Next(results_idx) != .nil) {
            const entry_idx = lua.getAbs(-1);
            const key_top = lua.getTop() - 1;

            const test_name = job.fieldString(lua, entry_idx, "name") orelse "<unnamed>";

            var ok = false;
            if (lua.getField(entry_idx, "ok") == .bool) ok = lua.to(Lua.Bool, -1) catch false;
            lua.pop(1);

            if (ok) {
                job.entries.append(job.arena.allocator(), .{ .pass = {} }) catch @panic("Out of memory");
            } else {
                const err = job.fieldString(lua, entry_idx, "err") orelse "unknown error";
                job.recordFailure(test_name, trimReason(err));
            }

            lua.setTop(key_top);
        }
    }
};

fn runFile(inst: *LVM.Instance, ud: *anyopaque) void {
    const job: *FileJob = @ptrCast(@alignCast(ud));
    var lua = inst.coro.state;

    if (job.setup(&lua)) |reason| {
        job.recordFailure("<setup>", reason);
        job.finish();
        return;
    }
    step(inst, ud);
}

fn step(inst: *LVM.Instance, ud: *anyopaque) void {
    const job: *FileJob = @ptrCast(@alignCast(ud));
    var lua = inst.coro.state;
    var nresults: usize = 0;

    const status = lua.resumeT(null, 1, &nresults) catch {
        job.recordFailure("<runtime>", job.takeError(&lua));
        job.finish();
        return;
    };

    switch (status) {
        .OK => {
            job.collect(&lua);
            job.finish();
        },
        .YIELDED => {
            const op = operations.Operation.decode(&lua, job.arena.allocator(), nresults) catch |e| {
                job.recordFailure("<runtime>", @errorName(e));
                job.finish();
                return;
            };
            op.dispatch(inst, job.io, job.arena.allocator(), step, job, FileJob);
        },
    }
}

fn createJob(r: *Runtime, done: *Io.Semaphore, dir: Io.Dir, entry: Io.Dir.Entry) !*FileJob {
    const job = try r.allocator.create(FileJob);
    errdefer r.allocator.destroy(job);
    job.* = .{
        .io = r.io,
        .done = done,
        .arena = .init(r.allocator),
        .path = undefined,
        .name = undefined,
    };
    errdefer job.arena.deinit();

    var buf: [4096]u8 = undefined;
    const len = try dir.realPathFile(r.io, entry.name, &buf);
    job.path = try job.arena.allocator().dupeZ(u8, buf[0..len]);
    job.name = std.fs.path.basename(job.path);
    return job;
}

fn destroyJob(r: *Runtime, job: *FileJob) void {
    job.arena.deinit();
    r.allocator.destroy(job);
}

pub fn runTestMode(r: *Runtime, test_dir_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const io = r.io;

    var writer = Io.File.stderr().writer(io, &buf);
    defer writer.flush() catch {};

    const test_dir = try Io.Dir.cwd().openDir(io, test_dir_path, .{ .iterate = true });

    var done: Io.Semaphore = .{};
    var jobs: std.ArrayList(*FileJob) = .empty;
    defer {
        for (jobs.items) |job| destroyJob(r, job);
        jobs.deinit(r.allocator);
    }

    var iter = test_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                const job = try createJob(r, &done, test_dir, entry);
                jobs.append(r.allocator, job) catch |e| {
                    destroyJob(r, job);
                    return e;
                };
            },
            else => continue,
        }
    }

    var submitted: usize = 0;
    var submit_err: ?anyerror = null;
    for (jobs.items) |job| {
        r.lvm.run(io, runFile, job) catch |e| {
            submit_err = e;
            break;
        };
        submitted += 1;
    }

    for (0..submitted) |_| done.wait(io) catch {};
    if (submit_err) |e| return e;

    var pass: usize = 0;
    var fail: usize = 0;
    for (jobs.items) |job| {
        var first_fail = true;
        for (job.entries.items) |entry| {
            switch (entry) {
                .pass => pass += 1,
                .fail => |fail_entry| {
                    if (first_fail) {
                        writer.interface.print("{s}\n", .{job.name}) catch {};
                        first_fail = false;
                    }
                    writer.interface.print("\t({s}) {s}\n", .{ fail_entry.test_name, fail_entry.reason }) catch {};
                    fail += 1;
                },
            }
        }
    }
    writer.interface.print("{s}\nPASS: {d}\tFAIL: {d}\n", .{ "-" ** 30, pass, fail }) catch {};
}

fn trimReason(full_reason: []const u8) []const u8 {
    const idx = std.mem.find(u8, full_reason, ":") orelse return full_reason;
    return std.mem.trim(u8, full_reason[idx + 1 ..], " ");
}
