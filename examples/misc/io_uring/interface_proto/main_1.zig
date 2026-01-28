const std = @import("std");
const lib = @import("iouring");

const UringEvent = union(enum) {
    accept,
    read_socket: struct {
        fd: posix.fd_t,
        id: usize,
        buf: []const u8,
    },
    write_socket: struct {
        fd: posix.fd_t,
        id: usize,
    },
    close_socket: struct {
        fd: posix.fd_t,
        id: usize,
    },
    fn fromInt(ptr: u64) *UringEvent {
        return @ptrFromInt(ptr);
    }
};

const UringEventPool = struct{
        pool: [8]UringEvent = undefined,
        bufs: [8][4096]u8 = @splat(@splat(0)),
        available: [8]usize = .{0,1,2,3,4,5,6,7},
        top: usize = 0,
        fn get(self: *UringEventPool) !usize {
            if (self.top == self.available.len ) return error.NoFree;
            const idx = self.available[self.top];
            self.top = self.top + 1;
            return idx;
        }
        fn free(self: *UringEventPool, index: usize) void {
            if (self.top == 0 ) return;
            self.top = self.top - 1;
            self.available[self.top] = index;
        }

};

fn toU64(ptr: *anyopaque) u64 {
    return @as(u64,@intFromPtr(ptr));
}

pub fn main() !void {
    var event_pool: UringEventPool = .{};
    var cqe_buf: [10]linux.io_uring_cqe = undefined;
    var server = try std.net.Address.listen(.initIp4(.{127,0,0,1},8080),.{});
    defer server.deinit();

    var iouring: std.os.linux.IoUring = try .init(8,0);
    defer iouring.deinit();

    std.debug.print("Starting server on port 8080\n",.{});

    var accept_event: UringEvent = .accept;
    //try to use direct fd insted
    _ = try iouring.accept_multishot(toU64(&accept_event),server.stream.handle,null,null,0);
    const n = try iouring.submit_and_wait(1);
    if(n != 1) return error.ExpectedOne;
    while(true) {
        const len = @as(usize,try iouring.copy_cqes(&cqe_buf,1));
        for (cqe_buf[0..len]) |cqe| {
            const res: i32 = if(cqe.err() == .SUCCESS) cqe.res else return error.BadCQEResponse;
            const uring_event = UringEvent.fromInt(cqe.user_data);
            switch(uring_event.*) {
                .accept =>  {
                    std.debug.print("New connection\n",.{});
                    const id = try event_pool.get();
                    const event = &event_pool.pool[id];
                    event.* = .{
                        .read_socket = .{
                            .fd = res,
                            .id = id,
                            .buf = &event_pool.bufs[id],
                        },
                    };
                    _ = try iouring.read(toU64(event),event.read_socket.fd,.{.buffer = @constCast(event.read_socket.buf)},0);
                },
                .read_socket => |ref| {
                    const bytes_read: usize = std.math.cast(usize,res).?;
                    const readable = ref.buf[0..bytes_read];
                    std.debug.print("Read: {s} with ({d})bytes total\n",.{readable,bytes_read});
                    const id = ref.id;
                    const fd = ref.fd;
                    uring_event.* = .{
                        .write_socket = .{
                            .fd = fd,
                            .id = id,
                        },
                    };
                    _ = try iouring.write(toU64(uring_event),uring_event.write_socket.fd,"IoUring response\n"[0..],0);
                },
                .write_socket => |ref| {
                    const fd = ref.fd;
                    const id = ref.id;
                    uring_event.* = .{
                        .close_socket = .{
                            .fd = fd,
                            .id = id,
                        },
                    };
                    _ = try iouring.close(toU64(uring_event),uring_event.close_socket.fd);
                },
                .close_socket => |ref| {
                    event_pool.free(ref.id);
                    std.debug.print("Closing\n",.{});
                },
            }
            _ = try iouring.submit();
        }
    }
}
