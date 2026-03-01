const std = @import("std"); //Based on Michael scott Two-lock concurrent queue

//To avoid queue metadata, I use an intrusive linked list where the field "next ?T" is embedded in T
pub fn BlockingQueue(T: type) type {
    return struct {
        head: *Node = undefined,
        tail: *Node = undefined,
        h_lock: std.Thread.Mutex = .{},
        t_lock: std.Thread.Mutex = .{},
        alloc: NodeAllocator,
        const Self = @This();

        const Node = struct {
            data: T,
            next: ?*Node,
        };

        const NodeAllocator = struct {
            free_list: ?*Node = null,
            arena: std.heap.ArenaAllocator,
            alloc_mutex: std.Thread.Mutex = .{},

            inline fn create(alloc: *NodeAllocator) !*Node {
                alloc.alloc_mutex.lock();
                defer alloc.alloc_mutex.unlock();
                const node = alloc.free_list orelse {
                    const node = try alloc.arena.allocator().create(Node);
                    node.next = null;
                    return node;
                };
                alloc.free_list = node.next;
                node.next = null;
                return node;
            }
            inline fn destroy(alloc: *NodeAllocator, node: *Node) void {
                alloc.alloc_mutex.lock();
                defer alloc.alloc_mutex.unlock();
                const old_head = alloc.free_list;
                node.next = old_head;
                alloc.free_list = node;
            }
        };

        pub inline fn init(q: *Self, alloc: std.mem.Allocator) !void {
            q.alloc = .{
                .free_list = null,
                .arena = std.heap.ArenaAllocator.init(alloc),
            };
            q.head = try q.alloc.create();
            q.tail = q.head;
        }
        pub inline fn deinit(q: Self) void {
            q.alloc.arena.deinit();
        }
        pub inline fn enqueue(q: *Self, value: T) !void {
            var node = try q.alloc.create();
            node.data = value;

            q.t_lock.lock();
            defer q.t_lock.unlock();

            q.tail.next = node;
            q.tail = node;
        }
        pub inline fn dequeue(q: *Self) ?T {
            q.h_lock.lock();
            defer q.h_lock.unlock();

            const node = q.head;
            defer q.alloc.destroy(node);

            //TODO: make this a separate function for reusability
            const new_head = node.next orelse {
                return null;
            };
            const n = new_head.data;
            q.head = new_head;
            return n;
        }
        pub inline fn try_dequeue(q: *Self) ?T {
            if (!q.h_lock.tryLock()) return null;
            defer q.h_lock.unlock();

            //TODO: make this a separate function for reusability
            const node = q.head;
            defer q.alloc.destroy(node);

            const new_head = node.next orelse {
                return null;
            };
            const n = new_head.data;
            q.head = new_head;
            return n;
        }
        //TODO: make a function that enqueues multiple nodes all at once to reduce lock usage
        //TODO: make a function that dequeues multiple nodes all at once to reduce lock usage
    };
}

test "BlockingQueue MPMC stress" {
    //TODO: Make this test more determinant(CHATGPT made a not so good test)
    const Thread = std.Thread;

    const Producers = 10;
    const Consumers = 4;
    const ItemsPerProducer = 50_000;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var queue: BlockingQueue(u32) = undefined;
    try queue.init(gpa.allocator());
    defer queue.deinit();

    var produced = std.atomic.Value(u32).init(0);
    var consumed = std.atomic.Value(u32).init(0);

    const producer = struct {
        fn produce(q: *BlockingQueue(u32), p: *std.atomic.Value(u32)) void {
            var i: u32 = 0;
            while (i < ItemsPerProducer) : (i += 1) {
                _ = q.enqueue(i) catch unreachable;
                _ = p.fetchAdd(1, .acq_rel);
            }
        }
    };

    const conusmer = struct {
        fn consume(q: *BlockingQueue(u32), c: *std.atomic.Value(u32)) void {
            var received: u32 = 0;

            while (true) {
                if (q.dequeue()) |_| {
                    _ = c.fetchAdd(1, .acq_rel);
                    received += 1;
                }
                std.Thread.yield() catch {};
                std.Thread.yield() catch {};
                if (c.load(.acquire) >= Producers * ItemsPerProducer)
                    break;
            }
        }
    };

    var threads: [Producers + Consumers]Thread = undefined;

    // start producers
    inline for (0..Producers) |i| {
        threads[i] = try Thread.spawn(.{}, producer.produce, .{ &queue, &produced });
    }

    // start consumers
    inline for (0..Consumers) |i| {
        threads[Producers + i] = try Thread.spawn(.{}, conusmer.consume, .{ &queue, &consumed });
    }

    inline for (threads) |t| t.join();

    try std.testing.expectEqual(
        produced.load(.monotonic),
        consumed.load(.monotonic),
    );
}
