const std = @import("std");
const atomic = std.atomic;

//WARNING: Undefined Behavior if tqil goes beyond 2^64 -1
//TODO: add crash when that happens or handle gracefully
pub fn Ring(T: type, comptime Size: comptime_int) type {
    comptime {
        if (!std.math.isPowerOfTwo(Size)) @compileError("Given ring buffer size is not a power of two");
    }
    return struct {
        const Self = @This();
        pub const MASK = Size - 1;
        head: atomic.Value(usize) align(atomic.cache_line) = .init(0),
        tail: atomic.Value(usize) align(atomic.cache_line) = .init(0),
        //Fit on four cache lines
        data: [Size]T = undefined,

        pub fn enqueue(q: *Self, data: T) error{RingFull}!void {
            const tail = q.tail.load(.acquire);
            const index = tail & MASK;
            //Can only load use n-1 elemnts in the array for sake of simplicity
            //should be negligable
            if (tail - q.head.load(.acquire) >= q.data.len) return error.RingFull;
            q.data[index] = data;
            q.tail.store(tail + 1, .release);
        }
        pub fn dequeue(q: *Self) ?T {
            const head = q.head.load(.acquire);
            if (head == q.tail.load(.acquire)) return null;
            //Can only load use n-1 elemnts in the array for sake of simplicity
            //should be negligable
            const val = q.data[head & MASK];
            q.head.store(head + 1, .release);
            return val;
        }
    };
}

pub fn Cluster(Submission: type, Completion: type, RingCount: comptime_int, RingSize: comptime_int) type {
    return struct {
        pub const Self = @This();
        pub const SubmissionRing = Ring(Submission, RingSize);
        pub const CompletionRing = Ring(Completion, RingSize * 2);

        submission_pool: [RingCount]SubmissionRing = .{SubmissionRing{}} ** RingCount,
        completion_pool: [RingCount]CompletionRing = .{CompletionRing{}} ** RingCount,

        //Bulk dequeue on given queue
        pub fn pullSubmissions(c: *Self, id: usize, submission: []Submission) []Submission {
            if (submission.len == 0) return submission;
            var sq = &c.submission_pool[id];
            const head = sq.head.load(.acquire);
            const tail = sq.tail.load(.acquire);
            const entries: usize = tail - head;

            const dequeueable = if (entries > submission.len) submission.len else entries;
            for (0..dequeueable) |i| {
                submission[i] = sq.data[(head + i) & SubmissionRing.MASK];
            }
            sq.head.store(head + dequeueable, .release);
            return submission[0..dequeueable];
        }
    };
}

test "general ring buffer test" {
    var ring: Ring(u64, 256) = .{};

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
    const RingCluster = Cluster(u64, u64, THREADS, RINGSIZE);
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

    var cluster: RingCluster = .{};

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
