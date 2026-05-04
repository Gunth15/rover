conn: *ConnectionContext,
ctxt: *anyopaque,
vtable: *const VTable,
const ConnectionContext = @import("ConnectionContext.zig");
const Runtime = @import("Runtime.zig");
const Future = @This();
pub const State = enum { waiting, finished, failed };
pub const VTable = struct {
    wake: *const fn (*Future, *Runtime) State,
    cancel: *const fn (*Future, *Runtime) void,
};
pub inline fn wake(f: *Future, runtime: *Runtime) State {
    return f.vtable.wake(f, runtime);
}
//canel is called don failure
pub inline fn cancel(f: *Future, runtime: *Runtime) void {
    return f.vtable.cancel(f, runtime);
}

///accumulator future is the future that controls the flow
///second args is a pointer to the output fro the previous entry
pub const FutureFunc = *const fn (*Future, ?*anyopaque) Future;
pub const Group = struct {
    futures: []*Future,
    future_funcs: []FutureFunc,
    idx: usize = 0,

    ///This function taakes a future and changes the future's state based on the context pointer
    ///run one after another. If one fails, the next is not ran
    ///Uses one future and the output of the previous future is used by the next(stored in the context)
    pub fn seq(g: *Group, conn: *ConnectionContext) Future {
        const cb = struct {
            fn wake(f: *Future, runtime: *Runtime) State {
                const gr: *Group = @ptrCast(f.ctxt);
                const fut = gr.futures[0];
                switch (fut.wake(runtime)) {
                    .waiting => return .waiting,
                    .failed => return .failed,
                    .finished => {
                        gr.idx += 1;
                        if (gr.idx == gr.future_funcs.len) return .finished;
                        const func = gr.future_funcs[gr.idx];
                        fut.* = func(f, fut.ctxt);
                        return .waiting;
                    },
                }
            }

            fn cancel(f: *Future, runtime: *Runtime) void {
                f.cancel(runtime);
            }
        };
        return .{
            .conn = conn,
            .ctxt = g,
            .vtable = &.{
                .wake = cb.wake,
                .cancel = cb.cancel,
            },
        };
    }
    ///runs all at the same time and returns when all have finished
    pub fn group(g: *Group, conn: ConnectionContext) Future {
        const cb = struct {
            fn wake(f: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) State {
                _ = f;
                const gr: *Group = @ptrCast(@alignCast(ptr));
                var all_done = true;
                for (gr.futures) |fut| {
                    switch (fut.wake(runtime)) {
                        //NOTE: see how this will work were I need it
                        .waiting => {
                            all_done = false;
                        },
                        .failed => {
                            // Record failure but keep polling others.
                            // idx doubles as a "seen a failure" flag here;
                            // callers can inspect individual futures for details.
                            gr.idx += 1;
                            all_done = false; // still need to drain
                        },
                        .finished => {},
                    }
                }
                if (all_done) return .finished;
                return .waiting;
            }
            fn cancel(_: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) void {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                for (gr.futures) |fut| fut.cancel(runtime);
            }
        };
        return .{
            .conn = conn,
            .ctxt = g,
            .vtable = &.{
                .wake = cb.wake,
                .cancel = cb.cancel,
            },
        };
    }

    ///runs all at the same time; if any one fails, the rest are cancelled and the group fails
    pub fn failGroup(g: *Group, conn: ConnectionContext) Future {
        const cb = struct {
            fn wake(f: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) State {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                var pending: usize = 0;
                for (gr.futures) |fut| {
                    switch (fut.wake(runtime)) {
                        .waiting => pending += 1,
                        .failed => {
                            f.cancel(runtime);
                            return .failed;
                        },
                        .finished => {},
                    }
                }
                if (pending == 0) return .finished;
                return .waiting;
            }
            fn cancel(_: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) void {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                for (gr.futures) |fut| fut.cancel(runtime);
            }
        };
        return .{
            .conn = conn,
            .ctxt = g,
            .vtable = &.{
                .wake = cb.wake,
                .cancel = cb.cancel,
            },
        };
    }

    ///first future to finish wins; failures are skipped. If all fail, the group fails.
    pub fn select(g: *Group, conn: ConnectionContext) Future {
        const cb = struct {
            fn wake(f: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) State {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                var all_failed = true;
                for (gr.futures) |fut| {
                    switch (fut.wake(runtime)) {
                        .waiting => {
                            all_failed = false;
                        },
                        .failed => {
                            // Skip this one; keep trying the rest.
                        },
                        .finished => {
                            // Cancel remaining and report success.
                            f.cancel(runtime);
                            return .finished;
                        },
                    }
                }
                if (all_failed) return .failed;
                return .waiting;
            }
            fn cancel(_: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) void {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                for (gr.futures) |fut| fut.cancel(runtime);
            }
        };
        return .{
            .conn = conn,
            .ctxt = g,
            .vtable = &.{
                .wake = cb.wake,
                .cancel = cb.cancel,
            },
        };
    }

    ///first future to settle (finish OR fail) wins; the others are cancelled
    pub fn failSelect(g: *Group, conn: *ConnectionContext) Future {
        const cb = struct {
            fn wake(f: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) State {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                for (gr.futures) |fut| {
                    switch (fut.wake(runtime)) {
                        .waiting => {},
                        .failed => {
                            f.cancel(runtime);
                            return .failed;
                        },
                        .finished => {
                            f.cancel(runtime);
                            return .finished;
                        },
                    }
                }
                return .waiting;
            }
            fn cancel(_: *Future, runtime: *Runtime, _: *ConnectionContext, ptr: *anyopaque) void {
                const gr: *Group = @ptrCast(@alignCast(ptr));
                for (gr.futures) |fut| fut.cancel(runtime);
            }
        };
        return .{
            .conn = conn,
            .ctxt = g,
            .vtable = &.{ .wake = cb.wake, .cancel = cb.cancel },
        };
    }
};

const std = @import("std");
const testing = std.testing;

/// A mock future that returns a scripted sequence of states.
/// The last entry in `script` is repeated once reached.
const MockFuture = struct {
    script: []const State,
    tick: usize = 0,
    cancelled: bool = false,

    fn future(self: *MockFuture) Future {
        const cb = struct {
            fn wake(_: *Future, _: *Runtime, _: *ConnectionContext, ptr: *anyopaque) State {
                const m: *MockFuture = @ptrCast(@alignCast(ptr));
                if (m.cancelled) return .failed;
                const idx = @min(m.tick, m.script.len - 1);
                const s = m.script[idx];
                m.tick += 1;
                return s;
            }
            fn cancel(_: *Future, _: *Runtime, _: *ConnectionContext, ptr: *anyopaque) void {
                const m: *MockFuture = @ptrCast(@alignCast(ptr));
                m.cancelled = true;
            }
        };
        return .{
            .conn = .{},
            .ctxt = self,
            .vtable = &.{ .wake = cb.wake, .cancel = cb.cancel },
        };
    }
};

/// Drive a future to completion (or failure), up to `limit` ticks.
/// Returns the final state.
fn drive(f: *Future, limit: usize) State {
    var rt = Runtime{};
    var s: State = .waiting;
    for (0..limit) |_| {
        s = f.wake(&rt, .{}, f.ctxt);
        if (s != .waiting) return s;
    }
    return s;
}

// ── group ─────────────────────────────────────────────────────────────────────

test "group: all finish" {
    var a = MockFuture{ .script = &.{ .waiting, .finished } };
    var b = MockFuture{ .script = &.{.finished} };
    var c = MockFuture{ .script = &.{ .waiting, .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var fc = c.future();
    var futures = [_]*Future{ &fa, &fb, &fc };
    var g = Group{ .futures = &futures };
    var f = g.group(.{});

    try testing.expectEqual(.finished, drive(&f, 10));
}

test "group: one fails, rest continue, group still finishes" {
    var a = MockFuture{ .script = &.{.failed} };
    var b = MockFuture{ .script = &.{ .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.group(.{});

    // group does NOT short-circuit on failure
    try testing.expectEqual(.finished, drive(&f, 10));
    try testing.expectEqual(false, b.cancelled);
}

test "group: cancel propagates to all" {
    var a = MockFuture{ .script = &.{.waiting} };
    var b = MockFuture{ .script = &.{.waiting} };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.group(.{});

    var rt = Runtime{};
    f.cancel(&rt, .{}, f.ctxt);
    try testing.expectEqual(true, a.cancelled);
    try testing.expectEqual(true, b.cancelled);
}

// ── failGroup ─────────────────────────────────────────────────────────────────

test "failGroup: all finish" {
    var a = MockFuture{ .script = &.{.finished} };
    var b = MockFuture{ .script = &.{ .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failGroup(.{});

    try testing.expectEqual(.finished, drive(&f, 10));
}

test "failGroup: one fails, others are cancelled" {
    var a = MockFuture{ .script = &.{ .waiting, .failed } };
    var b = MockFuture{ .script = &.{ .waiting, .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failGroup(.{});

    try testing.expectEqual(.failed, drive(&f, 10));
    try testing.expectEqual(true, b.cancelled);
}

test "failGroup: failure on first tick" {
    var a = MockFuture{ .script = &.{.failed} };
    var b = MockFuture{ .script = &.{.waiting} };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failGroup(.{});

    try testing.expectEqual(.failed, drive(&f, 10));
    try testing.expectEqual(true, b.cancelled);
}

// ── select ────────────────────────────────────────────────────────────────────

test "select: first to finish wins, others cancelled" {
    var a = MockFuture{ .script = &.{ .waiting, .finished } };
    var b = MockFuture{ .script = &.{ .waiting, .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.select(.{});

    try testing.expectEqual(.finished, drive(&f, 10));
    try testing.expectEqual(true, b.cancelled);
}

test "select: failed futures are skipped" {
    var a = MockFuture{ .script = &.{.failed} };
    var b = MockFuture{ .script = &.{ .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.select(.{});

    // a fails immediately but b should still win
    try testing.expectEqual(.finished, drive(&f, 10));
}

test "select: all fail returns failed" {
    var a = MockFuture{ .script = &.{.failed} };
    var b = MockFuture{ .script = &.{.failed} };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.select(.{});

    try testing.expectEqual(.failed, drive(&f, 10));
}

// ── failSelect ────────────────────────────────────────────────────────────────

test "failSelect: first to finish wins, others cancelled" {
    var a = MockFuture{ .script = &.{ .waiting, .finished } };
    var b = MockFuture{ .script = &.{ .waiting, .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failSelect(.{});

    try testing.expectEqual(.finished, drive(&f, 10));
    try testing.expectEqual(true, b.cancelled);
}

test "failSelect: first to fail also wins, others cancelled" {
    var a = MockFuture{ .script = &.{.failed} };
    var b = MockFuture{ .script = &.{ .waiting, .finished } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failSelect(.{});

    // failure counts as settling — b should be cancelled before it finishes
    try testing.expectEqual(.failed, drive(&f, 10));
    try testing.expectEqual(true, b.cancelled);
}

test "failSelect: fail beats a slower finish" {
    var a = MockFuture{ .script = &.{ .waiting, .waiting, .finished } };
    var b = MockFuture{ .script = &.{ .waiting, .failed } };
    var fa = a.future();
    var fb = b.future();
    var futures = [_]*Future{ &fa, &fb };
    var g = Group{ .futures = &futures };
    var f = g.failSelect(.{});

    try testing.expectEqual(.failed, drive(&f, 10));
    try testing.expectEqual(true, a.cancelled);
}
