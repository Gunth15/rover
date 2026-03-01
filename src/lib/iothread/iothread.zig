const std = @import("std");
const Io = @import("io/io.zig");
const config = @import("config");
const ring_cluster = @import("../util/ring_cluster.zig");

const IOEventQueue = struct {
    head: ?*Io.Event = null,
    tail: ?*Io.Event = null,
    inline fn push_head(q: *IOEventQueue, other_q: *IOEventQueue) void {
        if (other_q.head == null) return;
        const old_head = q.head;
        q.head = other_q.head;
        other_q.tail.?.next = old_head orelse {
            q.tail = other_q.tail;
            return;
        };
    }
    inline fn enqueue(q: *IOEventQueue, token: *Io.Event) void {
        token.next = null;
        if (q.head == null) {
            q.head = token;
            q.tail = token;
            return;
        }
        const old_tail = q.tail.?;
        q.tail = token;
        old_tail.next = token;
    }
    inline fn dequeue(q: *IOEventQueue) ?*Io.Event {
        const event = q.head orelse return null;
        q.head = event.next;
        if (q.head == null) {
            q.tail = null;
        }
        return event;
    }
};
const IOEventPool = std.heap.MemoryPoolExtra(Io.Event, .{});

pub fn IOHandle(RingCount: comptime_int) type {
    return struct {
        _thread: std.Thread = undefined,
        //TODO: move io into the main loop so that iouring single htreaded flag can be used
        _io: Io,
        _cluster: IOCluster = .{},
        //TODO: change to __state and use enum;
        _waiting: std.atomic.Value(bool) = .init(false),
        _halted: std.atomic.Value(bool) = .init(false),
        const Self = @This();
        const wakerCtx = struct {
            buf: [1]u8 = .{0},
        };
        const IOCluster = ring_cluster.Cluster(Io.Submission, Io.Completion, RingCount, config.io_ring_size);
        pub const IOCompletionRing = IOCluster.CompletionRing;
        pub const IOSubmissionRing = IOCluster.SubmissionRing;
        //TODO: Make wake be work better lol
        pub const Dispatcher = struct {
            _is_waiting: *std.atomic.Value(bool),
            _io: *Io,
            sq: *IOSubmissionRing,
            cq: *IOCompletionRing,
            pub inline fn enqueue(d: *Dispatcher, sub: Io.Submission) error{RingFull}!void {
                try d.sq.enqueue(sub);
                if (d._is_waiting.load(.monotonic)) d.wake();
            }
            pub inline fn dequeue(d: *Dispatcher) ?Io.Completion {
                return d.cq.dequeue();
            }
            inline fn wake(d: *Dispatcher) void {
                d._io.wake();
            }
            pub inline fn accept(d: *Dispatcher, context: *anyopaque, handle: Io.Handle, addr: std.net.Address) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{
                        .accept = .{
                            .handle = handle,
                            .addr = addr,
                        },
                    },
                };
                try d.enqueue(submission);
            }
            pub inline fn openat(d: *Dispatcher, context: *anyopaque, handle: Io.Handle, path: []const u8, options: Io.OpenOptions) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{
                        .openat = .{ .handle = handle, .options = options, .path = path },
                    },
                };
                try d.enqueue(submission);
            }
            pub inline fn read(d: *Dispatcher, context: *anyopaque, handle: Io.Handle, buffer: []u8, offset: u64) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{ .read = .{
                        .buffer = buffer,
                        .handle = handle,
                        .offset = offset,
                    } },
                };
                try d.enqueue(submission);
            }
            pub inline fn write(d: *Dispatcher, context: *anyopaque, handle: Io.Handle, buffer: []const u8, offset: u64) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{
                        .write = .{
                            .handle = handle,
                            .buffer = buffer,
                            .offset = offset,
                        },
                    },
                };
                try d.enqueue(submission);
            }
            pub inline fn send(d: *Dispatcher, context: *anyopaque, handle: Io.Handle, buffer: []const u8, options: Io.SendOptions) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{
                        .send = .{
                            .handle = handle,
                            .buffer = buffer,
                            .options = options,
                        },
                    },
                };
                try d.enqueue(submission);
            }
            pub inline fn close(d: *Dispatcher, context: *anyopaque, handle: Io.Handle) !void {
                const submission: Io.Submission = .{
                    .context = context,
                    .op = .{
                        .close = .{
                            .handle = handle,
                        },
                    },
                };
                try d.enqueue(submission);
            }
        };

        pub fn init() !Self {
            return .{
                ._cluster = .{},
                ._io = try .init(.{}),
            };
        }
        pub inline fn start(io_handle: *Self, alloc: std.mem.Allocator) !void {
            io_handle._thread = try std.Thread.spawn(.{}, main, .{ io_handle, alloc });
        }
        pub inline fn aqcuireDispatcher(io_handle: *Self, id: usize) Dispatcher {
            return .{
                .sq = &io_handle._cluster.submission_pool[id],
                .cq = &io_handle._cluster.completion_pool[id],
                ._io = &io_handle._io,
                ._is_waiting = &io_handle._waiting,
            };
        }
        pub inline fn stop(io_handle: *Self) void {
            io_handle._halted.store(true, .monotonic);
            io_handle._thread.join();
        }

        fn main(io_handle: *Self, alloc: std.mem.Allocator) void {
            defer io_handle._io.deinit();

            var event_pool = IOEventPool.initPreheated(alloc, config.io_ring_size) catch return std.debug.print("Could not preheat mempool(FATAL ERROR)", .{});
            defer event_pool.deinit();

            var pending: IOEventQueue = .{};
            var completed: IOEventQueue = .{};

            //TODO: handle graceful shutdown(go back to basic thread)
            while (!io_handle._halted.load(.monotonic)) {
                io_handle.flush_tokens(&event_pool, &pending, &completed);
                io_handle.handle_submissions(&event_pool, &pending) catch |e| std.debug.print("An error happend while trying to submissions completions: {any}", .{e});
                io_handle.handle_completions(&event_pool, &completed) catch |e| std.debug.print("An error happend while trying to process completions: {any}", .{e});
                io_handle.flush_tokens(&event_pool, &pending, &completed);
            }
        }
        fn flush_tokens(io_handle: *Self, event_pool: *IOEventPool, pending: *IOEventQueue, completed: *IOEventQueue) void {
            var temp_pending: IOEventQueue = .{};
            var temp_completed: IOEventQueue = .{};
            while (pending.dequeue()) |event| {
                std.debug.assert(event.status == .pending);

                io_handle._io.submit(event) catch temp_pending.enqueue(event);
            }
            while (completed.dequeue()) |event| {
                std.debug.assert(event.status == .complete);

                io_handle._cluster.completion_pool[event.queue_id].enqueue(event.status.complete) catch {
                    temp_completed.enqueue(event);
                    continue;
                };
                event_pool.destroy(event);
            }
            pending.push_head(&temp_pending);
            completed.push_head(&temp_completed);
        }
        fn handle_submissions(io_handle: *Self, event_pool: *IOEventPool, pending: *IOEventQueue) !void {
            //handle owned queue handle those submitted to cluster
            var submisisons: [config.io_ring_size]Io.Submission = undefined;
            for (0..io_handle._cluster.submission_pool.len) |id| {
                const slice = io_handle._cluster.pullSubmissions(id, &submisisons);
                for (slice) |sub| {
                    const event = try event_pool.create();
                    event.queue_id = id;
                    event.status = .{ .pending = sub };
                    io_handle._io.submit(event) catch pending.enqueue(event);
                }
            }
        }
        fn handle_completions(io_handle: *Self, event_pool: *IOEventPool, completed: *IOEventQueue) !void {
            var events: [config.io_ring_size * 4]*Io.Event = undefined;

            io_handle._waiting.store(true, .release);
            //flush is IO dependent
            const slice = try io_handle._io.flush(&events);
            io_handle._waiting.store(false, .monotonic);

            for (slice) |event| {
                std.debug.assert(event.status == .complete);
                io_handle._cluster.completion_pool[event.queue_id].enqueue(event.status.complete) catch {
                    completed.enqueue(event);
                    continue;
                };
                event_pool.destroy(event);
            }
        }
    };
}

test "simple connection test" {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8083);
    const clientcb = struct {
        fn createconnection(addr: std.net.Address) !void {
            var buf: [5]u8 = undefined;
            const client = try std.net.tcpConnectToAddress(addr);
            defer client.close();

            _ = try client.write("Hello");
            _ = try client.read(&buf);
            try std.testing.expectEqualStrings("Hello", &buf);
        }
    };

    var buf: [10]u8 = undefined;
    var server = try address.listen(.{});
    defer server.deinit();

    var io_handle = try IOHandle(4).init();
    try io_handle.start(std.testing.allocator);
    defer io_handle.stop();

    var dispatch = io_handle.aqcuireDispatcher(0);

    try dispatch.accept(&.{}, server.stream.handle, address);

    const client_thread = try std.Thread.spawn(.{}, clientcb.createconnection, .{address});
    defer client_thread.join();

    const accept_cmp: Io.Completion = accept: {
        while (true) {
            const accept = dispatch.dequeue();
            if (accept == null) continue;
            break :accept accept.?;
        }
    };

    const handle = try accept_cmp.ret.accept;
    const ctx = struct {
        buf: []u8,
    };

    var c = ctx{ .buf = &buf };
    try dispatch.read(&c, handle, &buf, 0);

    //loop until we get the read event back
    const read_cmp: Io.Completion = read: {
        while (true) {
            const read = dispatch.dequeue();
            if (read == null) continue;
            break :read read.?;
        }
    };
    const contex = read_cmp.formContext(ctx);
    const read = try read_cmp.ret.read;
    try std.testing.expectEqualStrings("Hello", contex.buf[0..read]);

    try dispatch.write(&c, handle, buf[0..read], 0);
    const write_cmp: Io.Completion = wrote: {
        while (true) {
            const wrote = dispatch.dequeue();
            if (wrote == null) continue;
            break :wrote wrote.?;
        }
    };
    const five = try write_cmp.ret.write;
    try std.testing.expect(five == 5);
}
