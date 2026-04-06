const std = @import("std");

//intrusive, data must ahave field next: *T
pub fn Queue(T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        const Self = @This();

        pub inline fn enqueue(q: *Self, data: *T) void {
            //should be fine unless you reuse pointers too fast
            if (q.head == null) {
                q.head = data;
                q.tail = data;
                return;
            }
            q.tail.?.next = data;
            q.tail = data;
        }
        pub inline fn dequeue(q: *Self) ?*T {
            const node = q.head orelse return null;
            defer node.next = null;

            const new_head = node.next;
            q.head = new_head;
            return node;
        }
    };
}
