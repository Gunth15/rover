//Based on vyokov queue (https://github.com/grivet/mpsc-queue/blob/main/mpsc-queue.h)
//Cant find the original post, but this guy sounds awesome form the legends lol
const std = @import("std");
const atomic = std.atomic;

//given type must have a field called next of type Atomic.Value(?T)
//pointers expected
pub fn MPSCQueue(T: type) type {
    return struct {
        const Self = @This();
        head: atomic.Value(*T),
        tail: atomic.Value(*T),
        stub: T,

        pub fn init() Self {
            const queue: Self = .{
                .head = .init(undefined),
                .tail = .init(undefined),
            };
            queue.head.store(&queue.stub, .monotonic);
            queue.tail.store(&queue.stub, .monotonic);
            queue.stub.next.store(null, .monotonic);
        }
        //producer api,
        //NOTE: Thread safe
        pub fn insert(queue: *Self, node: *T) void {
            queue.insertList(node, node);
        }
        //first and last are pointers into a linked
        pub fn insertList(queue: *Self, first: *T, last: *T) void {
            last.next.store(null, .monotonic);
            const prev = queue.tail.swap(queue.tail, last, .acq_rel);
            prev.next.store(first, .release);
        }
        pub fn insertBatch(queue: *Self, nodes: []T) void {
            if (nodes.len == 0) return;

            const first = nodes[0];
            const last = nodes[nodes.len - 1];

            for (nodes, nodes[1..]) |node, nxt_node| {
                node.next.store(nxt_node, .monotonic);
            }
            queue.insertList(first, last);
        }

        //consumer api
        //WARNING: Not Thread Safe
        pub fn push_front(queue: *Self, node: *T) void {
            const head = queue.head.load(.monotonic);
            node.next.store(head, .monotonic);
            queue.head.store(node, .monotonic);
        }
        pub fn is_empty(queue: *Self) bool {
            const head = queue.head.load(.monotonic);
            const next = head.next.load(.acquire);
            const tail = queue.tail.load(.acquire);

            return (head == &queue.stub and next == null and head == tail);
        }

        pub const Result = union(enum) { empty, item: *T, retry };
        fn poll(queue: *Self) Result {
            var head = queue.head.load(.monotonic);
            var next: *T = head.next.load(.acquire);
            var tail: *T = undefined;

            if (head == &queue.stub) {
                if (next == null) {
                    tail = queue.tail.load(.acquire);
                    if (tail != head)
                        return .retry
                    else
                        return .empty;
                }
                queue.head.store(next, .monotonic);
                head = next;
                next = head.next.load(.acquire);
            }

            if (next != null) {
                queue.head.store(next, .monotonic);
                return .{ .item = head };
            }

            tail = if (head != tail)
                queue.tail.load(.acquire)
            else
                return .retry;

            queue.insert(queue, &queue.stub);

            next = queue.head.load(.acquire);
            if (next != null) {
                queue.head.store(next, .monotonic);
                return .{ .item = head };
            }
            return .retry;
        }
        pub fn dequeue(queue: *Self) ?*T {
            loop: switch (queue.poll()) {
                .empty => return null,
                .item => |i| return i,
                .retry => continue :loop queue.poll(),
            }
        }
        pub fn peek_head(queue: *Self) ?*T {
            var head: *T = queue.head.load(.monotonic);
            const next: *T = head.next.load(.acquire);

            if (head == &queue.stub) {
                if (next == null) return null;
                queue.head.store(next, .monotonic);
                head = next;
            }
            return head;
        }
        pub fn iter(queue: *Self, prev: *T) ?*T {
            var next: *T = prev.next.load(.acquire);
            if (next == &queue.stub) {
                next = next.load(.aquire);
            }
            return next;
        }

        pub fn consumer(queue: *Self) type {
            return struct {
                queue: queue,
                prev: ?*T,
                pub const Consumer = @This();
                pub fn push_front(self: *Consumer, node: *T) void {
                    return self.queue.push_front(node);
                }
                pub fn is_empty(self: *Consumer) bool {
                    return self.queue.is_empty();
                }
                pub fn dequeue(self: *Consumer) ?*T {
                    return self.queue.dequeue();
                }
                pub fn peek_head(self: *Consumer) ?*T {
                    return self.queue.peek_head();
                }
                pub fn next(self: *Consumer) ?*T {
                    if (self.prev == null) self.prev = self.queue.peek_head() orelse return null;
                    return self.queue.iter(self.prev);
                }
            };
        }
        pub fn producer() type {
            return struct {
                const Producer = @This();
            };
        }
    };
}
