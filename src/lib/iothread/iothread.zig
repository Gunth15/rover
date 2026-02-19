const std = @import("std");
const Io = @import("io/io.zig").Io;
const config = @import("config");
const ring_cluster = @import("../util/ring_cluster.zig");

const Token = struct { queue_id: usize, transaction: Io.Transaction };
const TokenPool = std.heap.MemoryPoolExtra(Token, .{});

pub fn IOHandle(RingCount: comptime_int) type {
    return struct {
        _thread: std.Thread = undefined,
        _cluster: IOCluster = .{},
        //maybe a linked list queue for tokens that hvae not been submitted and those that hvae not been staged fo rocmpletion yet
        _io: Io,
        const IOCluster = ring_cluster.Cluster(Io.Operation, Io.Completion, RingCount, config.io_ring_size);
        pub const IOCompletionRing = IOCluster.CompletionRing;
        pub const IOSubmissionRing = IOCluster.SubmissionRing;
        const Self = @This();
        pub fn init() Self {
            return .{
                ._cluster = .{},
                //TODO: be able to pass params
                ._io = .init(.{}),
            };
        }
        pub inline fn start(io_handle: *Self) !void {
            io_handle._thread = try std.Thread.spawn(.{}, main, .{io_handle});
        }
        pub inline fn wait(io_handle: *Self) void {
            io_handle._thread.join();
        }
        pub inline fn aqcuire_queues(io_handle: *Self) struct { usize, *IOSubmissionRing, *IOCompletionRing } {}
        pub inline fn release_queues(io_handle: *Self, id: usize) void {}

        fn main(io_handle: *Self, alloc: std.mem.Allocator) !void {
            var token_pool: std.heap.MemoryPoolExtra(Token, .{}) = try .initCapacity(alloc, config.io_ring_size);
            defer token_pool.deinit();
            defer io_handle._io.deinit();

            //handle graceful shutdown
            while (true) {
                io_handle.handle_submissions(token_pool) catch |e| std.debug.print("An error happend while trying to submissions completions: {any}", .{e});
                io_handle.handle_completions(token_pool) catch |e| std.debug.print("An error happend while trying to process completions: {any}", .{e});
            }
        }
        inline fn handle_submissions(io_handle: *Self, token_pool: TokenPool) !void {
            //handle owned queue
            //handle those submitted to cluster
            var submisison: [config.io_ring_size]Io.Io.Operation = undefined;
            for (io_handle._cluster.submission_pool.len) |id| {
                const slice = io_handle._cluster.pullSubmissions(id, &submisison);
                for (slice) |sub| {
                    const token = try token_pool.create();
                    token.queue_id = id;
                    token.payload = .{ .pending = sub };
                    try io_handle._io.submit(token.transaction);
                }
            }
        }
        inline fn handle_completions(io_handle: *Self, token_pool: TokenPool) !void {
            var transacs: [config.io_ring_size * 4]Io.Transaction = undefined;
            const slice = try io_handle._io.flush(&transacs);
            for (slice) |transaction| {
                const token: Token = @fieldParentPtr("payload", transaction);

                std.debug.assert(token.transaction == .completion);
                //put unqueued transactions in a backup queue rn We dont care
                try io_handle._cluster.completion_pool[token.queue_id].enqueue(token.transaction.completion);
                token_pool.destroy(token);
            }
        }
    };
}
