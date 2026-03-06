const std = @import("std");
const atomic = std.atomic;

//WARNING: Undefined Behavior if tqil goes beyond 2^64 -1
//TODO: add crash when that happens or handle gracefully

pub fn ThreadRing(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cursor = struct {
            v: atomic.Value(usize) = .init(0),
            _padding: [atomic.cache_line - @sizeOf(atomic.Value(usize))]u8 = undefined,
        };

        head: Cursor align(atomic.cache_line) = .{},
        tail: Cursor align(atomic.cache_line) = .{},
        data: []T = undefined,

        pub fn init(alloc: std.mem.Allocator, capacity: usize) !Self {
            if (!std.math.isPowerOfTwo(capacity))
                return error.NotPowerOfTwo;

            return .{
                .data = try alloc.alloc(T, capacity),
            };
        }

        pub fn enqueue(q: *Self, value: T) !void {
            const tail = q.tail.v.load(.acquire);

            if (tail - q.head.v.load(.acquire) >= q.data.len)
                return error.RingFull;

            const index = tail & (q.data.len - 1);
            q.data[index] = value;

            q.tail.v.store(tail + 1, .release);
        }

        pub fn dequeue(q: *Self) ?T {
            const head = q.head.v.load(.acquire);

            if (head == q.tail.v.load(.acquire))
                return null;

            const value = q.data[head & (q.data.len - 1)];

            q.head.v.store(head + 1, .release);
            return value;
        }

        pub fn deinit(q: *const Self, alloc: std.mem.Allocator) void {
            alloc.free(q.data);
        }
    };
}

pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        head: usize = 0,
        tail: usize = 0,
        data: []T = undefined,

        pub fn init(alloc: std.mem.Allocator, capacity: usize) !Self {
            if (!std.math.isPowerOfTwo(capacity))
                return error.NotPowerOfTwo;

            return .{
                .data = try alloc.alloc(T, capacity),
            };
        }

        pub fn enqueue(q: *Self, value: T) !void {
            const tail = q.tail;

            if (tail - q.head >= q.data.len)
                return error.RingFull;

            const index = tail & (q.data.len - 1);
            q.data[index] = value;

            q.tail += 1;
        }

        pub fn dequeue(q: *Self) ?T {
            const head = q.head;

            if (head == q.tail)
                return null;

            const value = q.data[head & (q.data.len - 1)];
            q.head += 1;

            return value;
        }

        pub fn deinit(q: *Self, alloc: std.mem.Allocator) void {
            alloc.free(q.data);
        }
    };
}

pub fn Cluster(Submission: type, Completion: type) type {
    return struct {
        pub const Self = @This();

        pub const SubmissionRing = ThreadRing(Submission);
        pub const CompletionRing = ThreadRing(Completion);
        submission_pool: []SubmissionRing,
        completion_pool: []CompletionRing,

        //Bulk dequeue on given queue
        pub fn init(alloc: std.mem.Allocator, ring_size: usize, ring_count: usize) error{ NotPowerOfTwo, OutOfMemory }!Self {
            const completion_pool = try alloc.alloc(CompletionRing, ring_count);
            const submission_pool = try alloc.alloc(SubmissionRing, ring_count);
            for (0..completion_pool.len) |i| completion_pool[i] = try .init(alloc, ring_size);
            for (0..submission_pool.len) |i| submission_pool[i] = try .init(alloc, ring_size);
            return .{
                .completion_pool = completion_pool,
                .submission_pool = submission_pool,
            };
        }
        pub fn pullSubmissions(c: *Self, id: usize, submission: []Submission) []Submission {
            if (submission.len == 0) return submission;
            var sq = &c.submission_pool[id];
            const head = sq.head.v.load(.acquire);
            const tail = sq.tail.v.load(.acquire);
            const entries: usize = tail - head;

            const dequeueable = if (entries > submission.len) submission.len else entries;
            for (0..dequeueable) |i| {
                submission[i] = sq.data[(head + i) & (sq.data.len - 1)];
            }
            sq.head.v.store(head + dequeueable, .release);
            return submission[0..dequeueable];
        }
        pub fn deinit(c: *Self, alloc: std.mem.Allocator) void {
            for (c.completion_pool) |cq| cq.deinit(alloc);
            for (c.submission_pool) |sq| sq.deinit(alloc);
            alloc.free(c.completion_pool);
            alloc.free(c.submission_pool);
        }
    };
}

test "general ring buffer test" {
    var ring: Ring(u64) = try .init(std.testing.allocator, 256);
    defer ring.deinit(std.testing.allocator);

    for (0..256) |i| {
        const e = ring.enqueue(i);
        if (i == 256) try std.testing.expectEqual(error.RingFull, e);
    }
    for (0..256) |i| {
        const num = ring.dequeue();
        if (i == 256) try std.testing.expect(num == null) else {
            try std.testing.expect(num == i);
        }
    }
}

test "multithreaded cluster test" {
    const THREADS = 5;
    const RINGSIZE = 4096;
    const COUNT = 4096;
    const RingCluster = Cluster(u64, u64);
    const producercb = struct {
        var COMPLETED: [THREADS][COUNT]bool = .{.{false} ** COUNT} ** THREADS;
        fn push_numbers(id: usize, s: *RingCluster.SubmissionRing, c: *RingCluster.CompletionRing) void {
            for (0..COUNT) |i| s.enqueue(i) catch std.debug.print("[{d} was not enqueued]\n\n", .{i});
            var received: usize = COUNT;
            while (received > 0) {
                if (c.dequeue()) |i| {
                    COMPLETED[id][i] = true;
                    received -= 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };
    const consumercb = struct {
        var SUBMITTED: [THREADS][COUNT]bool = .{.{false} ** COUNT} ** THREADS;
        fn pop_numbers(cluster: *RingCluster) void {
            var expected: u64 = COUNT * THREADS;
            while (expected > 0) {
                var buf: [256]u64 = undefined;
                for (0..THREADS) |id| {
                    const slice = cluster.pullSubmissions(id, &buf);
                    for (slice) |i| {
                        //Pretend work was done to i(submission) creating i(completion)
                        SUBMITTED[id][i] = true;
                        cluster.completion_pool[id].enqueue(i) catch {};
                        expected -= 1;
                    }
                }
            }
        }
    };

    var cluster: RingCluster = try .init(std.testing.allocator, RINGSIZE, THREADS);
    defer cluster.deinit(std.testing.allocator);

    var thread: [THREADS]std.Thread = undefined;
    for (0..THREADS) |i| {
        thread[i] = try std.Thread.spawn(.{}, producercb.push_numbers, .{ i, &cluster.submission_pool[i], &cluster.completion_pool[i] });
    }
    consumercb.pop_numbers(&cluster);
    for (consumercb.SUBMITTED) |thread_completion| {
        for (thread_completion) |completed| {
            try std.testing.expect(completed);
        }
    }
    for (thread) |t| t.join();
    for (producercb.COMPLETED) |thread_completion| {
        for (thread_completion) |completed| {
            try std.testing.expect(completed);
        }
    }
}
