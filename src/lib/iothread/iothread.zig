const std = @import("std");
const Io = @import("io/io.zig").Io;
const config = @import("config");
const ring_cluster = @import("../util/ring_cluster.zig");

const Token = struct { queue_id: usize, transaction: Io.Transaction, next: ?*Token = null };
const TokenQueue = struct {
    head: ?*Token = null,
    tail: ?*Token = null,
    inline fn push_head(q: *TokenQueue, other_q: *TokenQueue) void {
        if (other_q.head == null) return;
        const old_head = q.head;
        q.head = other_q.head;
        other_q.tail.?.next = old_head orelse {
            q.tail = other_q.tail;
            return;
        };
    }
    inline fn enqueue(q: *TokenQueue, token: *Token) void {
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
    inline fn dequeue(q: *TokenQueue) ?*Token {
        const token = q.head orelse return null;
        q.head = token.next;
        if (q.head == null) {
            q.tail = null;
        }
        return token;
    }
};
const TokenPool = std.heap.MemoryPoolExtra(Token, .{});

//TODO: add a context to Operations and Compleations so that user data can be pased back
pub fn IOHandle(RingCount: comptime_int) type {
    return struct {
        _thread: std.Thread = undefined,
        _io: Io,
        _cluster: IOCluster = .{},
        _waiting: std.atomic.Value(bool) = .init(false),
        _halt: std.atomic.Value(bool) = .init(false),
        _eventfd: usize,
        const WAKERID = (1 << 64) - 1;
        const IOCluster = ring_cluster.Cluster(Io.Transaction, Io.Transaction, RingCount, config.io_ring_size);
        pub const IOCompletionRing = IOCluster.CompletionRing;
        pub const IOSubmissionRing = IOCluster.SubmissionRing;
        pub const Dispatcher = struct {
            waker: usize,
            _is_waiting: *std.atomic.Value(bool),
            sq: *IOSubmissionRing,
            cq: *IOCompletionRing,
            pub inline fn enqueue(d: *Dispatcher, transaction: Io.Transaction) error{RingFull}!void {
                try d.sq.enqueue(transaction);
                if (d._is_waiting.load(.monotonic)) d.wake();
            }
            pub inline fn dequeue(d: *Dispatcher) ?Io.Transaction {
                return d.cq.dequeue();
            }
            inline fn wake(d: *Dispatcher) void {
                const buf: [1]u8 = .{1};
                _ = std.os.linux.write(@intCast(d.waker), &buf, 1);
            }
        };
        const Self = @This();

        pub fn init() !Self {
            return .{ ._cluster = .{}, ._io = try .init(.{}), ._eventfd = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK) };
        }
        pub inline fn start(io_handle: *Self, alloc: std.mem.Allocator) !void {
            io_handle._thread = try std.Thread.spawn(.{}, main, .{ io_handle, alloc });
        }
        pub inline fn wait(io_handle: *Self) void {
            io_handle._thread.join();
        }
        pub inline fn aqcuireDispatcher(io_handle: *Self, id: usize) Dispatcher {
            return .{ .sq = &io_handle._cluster.submission_pool[id], .cq = &io_handle._cluster.completion_pool[id], .waker = io_handle._eventfd, ._is_waiting = &io_handle._waiting };
        }
        pub inline fn halt(io_handle: *Self) void {
            const buf: [1]u8 = .{1};
            _ = std.os.linux.write(@intCast(io_handle._eventfd), &buf, 1);
            io_handle._halt.store(true, .monotonic);
            io_handle.wait();
        }

        fn main(io_handle: *Self, alloc: std.mem.Allocator) !void {
            defer io_handle._io.deinit();

            var token_pool: TokenPool = try .initPreheated(alloc, config.io_ring_size);
            defer token_pool.deinit();

            var pending: TokenQueue = .{};
            var completed: TokenQueue = .{};

            //TODO: handle graceful shutdown
            //NOTE: realistically, you will never have 999 submission queues, so it is considered a special queue here
            var w_buf: [1]u8 = undefined;
            var waiter_transac: Token = .{ .queue_id = WAKERID, .transaction = .{ .context = &w_buf, .status = .{ .pending = .{ .read = .{ .buffer = &w_buf, .fd = @intCast(io_handle._eventfd), .offset = 0 } } } } };
            try io_handle._io.submit(&waiter_transac.transaction);
            while (!io_handle._halt.load(.acquire)) {
                io_handle.flush_tokens(&token_pool, &pending, &completed);
                io_handle.handle_submissions(&token_pool, &pending) catch |e| std.debug.print("An error happend while trying to submissions completions: {any}", .{e});
                io_handle.handle_completions(&token_pool, &completed) catch |e| std.debug.print("An error happend while trying to process completions: {any}", .{e});
                io_handle.flush_tokens(&token_pool, &pending, &completed);
            }
        }
        inline fn flush_tokens(io_handle: *Self, token_pool: *TokenPool, pending: *TokenQueue, completed: *TokenQueue) void {
            var temp_pending: TokenQueue = .{};
            var temp_completed: TokenQueue = .{};
            while (pending.dequeue()) |token| io_handle._io.submit(&token.transaction) catch temp_pending.enqueue(token);
            while (completed.dequeue()) |token| {
                io_handle._cluster.completion_pool[token.queue_id].enqueue(token.transaction) catch {
                    temp_completed.enqueue(token);
                    continue;
                };
                token_pool.destroy(token);
            }
            pending.push_head(&temp_pending);
            completed.push_head(&temp_completed);
        }
        inline fn handle_submissions(io_handle: *Self, token_pool: *TokenPool, pending: *TokenQueue) !void {
            //handle owned queue
            //handle those submitted to cluster
            var submisison: [config.io_ring_size]Io.Transaction = undefined;
            for (0..io_handle._cluster.submission_pool.len) |id| {
                const slice = io_handle._cluster.pullSubmissions(id, &submisison);
                for (slice) |t| {
                    const token = try token_pool.create();
                    token.queue_id = id;
                    token.transaction = t;
                    io_handle._io.submit(&token.transaction) catch pending.enqueue(token);
                }
            }
        }
        inline fn handle_completions(io_handle: *Self, token_pool: *TokenPool, completed: *TokenQueue) !void {
            var transacs: [config.io_ring_size * 4]*Io.Transaction = undefined;
            io_handle._waiting.store(true, .release);
            const slice = try io_handle._io.flush(&transacs);
            io_handle._waiting.store(false, .monotonic);
            for (slice) |transaction| {
                const token: *Token = @fieldParentPtr("transaction", transaction);
                if (token.queue_id == WAKERID) {
                    io_handle.rearm_waker(token);
                    try io_handle._io.submit(&token.transaction);
                } else {
                    std.debug.assert(token.transaction.status == .complete);
                    io_handle._cluster.completion_pool[token.queue_id].enqueue(token.transaction) catch {
                        completed.enqueue(token);
                        continue;
                    };
                    token_pool.destroy(token);
                }
            }
        }
        inline fn rearm_waker(io_handle: *Self, waker_token: *Token) void {
            std.debug.assert(waker_token.queue_id == WAKERID);
            const w_buf: []u8 = @ptrCast(waker_token.transaction.context);
            waker_token.transaction.status = .{ .pending = .{ .read = .{ .buffer = w_buf, .fd = @intCast(io_handle._eventfd), .offset = 0 } } };
        }
    };
}

test "simple connection test" {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8083);
    const clientcb = struct {
        var succeed = false;
        fn createconnection(addr: std.net.Address) !void {
            var buf: [5]u8 = undefined;
            const client = try std.net.tcpConnectToAddress(addr);
            defer client.close();

            _ = try client.write("Hello");
            _ = try client.read(&buf);
            succeed = std.mem.eql(u8, "Hello", &buf);
        }
    };

    var buf: [10]u8 = undefined;
    var server = try std.net.Address.listen(address, .{});
    defer server.deinit();

    var io_handle = try IOHandle(4).init();
    try io_handle.start(std.testing.allocator);

    var dispatch = io_handle.aqcuireDispatcher(0);

    try dispatch.enqueue(.create(&buf, .{ .accept = .{
        .fd = server.stream.handle,
        .addr = address,
        .flags = 0,
    } }));

    const client_thread = try std.Thread.spawn(.{}, clientcb.createconnection, .{address});

    const accept_transaction: Io.Transaction = accept: {
        while (true) {
            const accept = dispatch.dequeue();
            if (accept == null) continue;
            break :accept accept.?;
        }
    };

    const handle = try accept_transaction.status.complete.accept;
    const ctx = struct {
        buf: []u8,
    };
    var c = ctx{ .buf = &buf };
    try dispatch.enqueue(.create(&c, .{ .read = .{
        .fd = handle,
        .buffer = &buf,
        .offset = 0,
    } }));

    const read_transaction: Io.Transaction = read: {
        while (true) {
            const read = dispatch.dequeue();
            if (read == null) continue;
            break :read read.?;
        }
    };
    const contex, const cmp = read_transaction.complete(ctx);
    const read = try cmp.read;
    try std.testing.expectEqualStrings("Hello", contex.buf[0..read]);

    try dispatch.enqueue(.create(&buf, .{ .write = .{
        .fd = handle,
        .buffer = &buf,
        .offset = 0,
    } }));
    const write_transaction: Io.Transaction = wrote: {
        while (true) {
            const wrote = dispatch.dequeue();
            if (wrote == null) continue;
            break :wrote wrote.?;
        }
    };
    _ = try write_transaction.status.complete.write;

    client_thread.join();
    io_handle.halt();
    try std.testing.expect(clientcb.succeed);
}
