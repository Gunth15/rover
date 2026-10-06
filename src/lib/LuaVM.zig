//OPTOMIZE: reuse job allocations
job_queue: std.DoublyLinkedList = .{},

workers: []?*VMWorker,

running: std.atomic.Value(bool) = .init(true),

ready_count: std.atomic.Value(usize) = .init(0),
vm_count: usize,
last_vm: usize = 0,

pending_cond: std.Io.Condition = .init,

mut: std.Io.Mutex = .init,
group: std.Io.Group = .init,
allocator: std.mem.Allocator,

const LVM = @This();
const std = @import("std");
const lib = @import("lib.zig");
const Lua = lib.Lua;

const MAXQUEUESIZE = 256;
const Segment = struct {
    queue: std.Deque(Job),
    buff: [MAXQUEUESIZE]Job,
    node: std.DoublyLinkedList.Node = .{},
};
pub const Job = struct {
    run: VMFunc,
    thread: ?Coroutine,
    userdata: *anyopaque,
};

pub const Coroutine = struct {
    ref: c_int,
    state: Lua,
    status: enum { running, waiting, ready },

    fn init(l: *Lua) !Coroutine {
        return .{
            .state = try l.newThread(),
            .ref = l.ref(),
            .status = .running,
        };
    }

    //TODO: make a more elegant way deinit a thread (maybe a boolean that tells you if it is finished)
    fn deinit(t: *Coroutine, main: *Lua) void {
        main.unref(t.ref);
    }
};

pub const VMWorker = struct {
    id: usize,
    local_queue: std.Io.Queue(Job),
    sem: std.Io.Semaphore = .{},
};

const Options = struct {
    vm_count: ?usize = null,
};
pub inline fn init(allocator: std.mem.Allocator, opts: Options) !LVM {
    return .{
        .vm_count = opts.vm_count orelse try std.Thread.getCpuCount(),
        .job_queue = .{},
        .workers = try allocator.alloc(?*VMWorker, opts.vm_count orelse try std.Thread.getCpuCount()),
        .allocator = allocator,
    };
}
pub fn deinit(lvm: *LVM, io: std.Io) void {
    lvm.mut.lock(io) catch {};
    while (lvm.job_queue.first) |_|
        lvm.pending_cond.wait(io, &lvm.mut) catch {};
    lvm.mut.unlock(io);

    lvm.running.store(false, .monotonic);
    lvm.group.await(io) catch {};

    while (lvm.job_queue.popFirst()) |node| {
        const segment: *Segment = @fieldParentPtr("node", node);
        lvm.allocator.destroy(segment);
    }
    lvm.allocator.free(lvm.workers);
}

pub const Instance = struct {
    coro: Coroutine,
    worker: *VMWorker,
    lvm: *LVM,

    pub inline fn run(i: *Instance, io: std.Io, resume_func: VMFunc, ud: *anyopaque) !void {
        const lvm = i.lvm;
        lvm.run(io, resume_func, ud);
    }
    ///assumes the function does not return anything and that is will resume the Instance when it needs to
    pub inline fn yield(i: *Instance, io: std.Io, function: anytype, args: std.meta.ArgsTuple(function)) !void {
        i.coro.status = .waiting;
        _ = try io.concurrent(function, args);
    }
    pub fn resumeC(i: *Instance, io: std.Io, resume_func: VMFunc, ud: *anyopaque) !void {
        var coro = i.coro;
        const work = i.worker;

        std.debug.assert(coro.status == .waiting);
        coro.status = .ready;

        const job: Job = .{
            .run = resume_func,
            .userdata = ud,
            .thread = coro,
        };

        work.sem.post(io);
        try work.local_queue.putOne(io, job);
    }
};

pub const VMFunc = *const fn (*Instance, userdata: *anyopaque) void;
pub fn run(lvm: *LVM, io: std.Io, vmfunc: VMFunc, ud: *anyopaque) !void {
    ////VM MUTEX BORROW
    try lvm.mut.lock(io);
    defer lvm.mut.unlock(io);

    const job: Job = .{
        .run = vmfunc,
        .userdata = ud,
        .thread = null,
    };

    if (lvm.job_queue.last) |last| {
        const seg: *Segment = @fieldParentPtr("node", last);
        seg.queue.pushBackBounded(job) catch {
            const new_segment = try lvm.allocateNewSegment();
            new_segment.queue.pushBackAssumeCapacity(job);
        };
    } else {
        const new_segment = try lvm.allocateNewSegment();
        new_segment.queue.pushBackAssumeCapacity(job);
    }

    //NOTE: round-robin scheduling
    const w = lvm.workers[lvm.last_vm].?;
    w.sem.post(io);
    lvm.last_vm = (lvm.last_vm + 1) % lvm.vm_count;
    ////VM MUTEX BORROW
}
fn getJobs(lvm: *LVM, io: std.Io, buff: []Job) !usize {
    ////VM MUTEX BORROW
    try lvm.mut.lock(io);
    defer lvm.mut.unlock(io);

    var size: usize = 0;
    while (size < buff.len) {
        const node = lvm.job_queue.first orelse break;
        const seg: *Segment = @fieldParentPtr("node", node);

        while (size < buff.len) : (size += 1) {
            buff[size] = seg.queue.popFront() orelse {
                lvm.job_queue.remove(node);
                lvm.allocator.destroy(seg);
                break;
            };
        }
    }
    return size;
    ////VM MUTEX BORROW
}

pub fn start(lvm: *LVM, io: std.Io, startfn: ?*const fn (*Lua, ?*anyopaque) void, start_data: ?*anyopaque) !void {
    for (0..lvm.vm_count) |i| try lvm.group.concurrent(io, worker, .{ lvm, io, i, startfn, start_data });
    while (lvm.ready_count.load(.monotonic) < lvm.vm_count) std.atomic.spinLoopHint();
}

fn allocateNewSegment(lvm: *LVM) !*Segment {
    //NOTE: assume lock is being held
    const segment = try lvm.allocator.create(Segment);
    segment.queue = .initBuffer(&segment.buff);
    lvm.job_queue.append(&segment.node);
    return segment;
}

fn worker(vm: *LVM, io: std.Io, id: usize, startfn: ?*const fn (*Lua, ?*anyopaque) void, start_data: ?*anyopaque) void {
    var main = Lua.init(.{ .allocator = &vm.allocator }) catch @panic("Unable to start worker");
    defer main.deinit();

    if (startfn) |func| func(&main, start_data);

    var lbuff: [MAXQUEUESIZE]Job = undefined;
    var work: VMWorker = .{
        .id = id,
        .local_queue = .init(&lbuff),
    };
    defer work.local_queue.close(io);

    ////VM MUTEX BORROW?
    vm.mut.lock(io) catch return;
    vm.workers[id] = &work;
    _ = vm.ready_count.fetchAdd(1, .monotonic);
    vm.mut.unlock(io);
    ////VM MUTEX BORROW

    var check: u32 = 0;
    var buff: [MAXQUEUESIZE]Job = undefined;
    worker_loop: while (vm.running.load(.acquire)) {
        if (check == 64) {
            const len = vm.getJobs(io, &buff) catch break :worker_loop;
            for (buff[0..len]) |job| {
                std.debug.assert(job.thread == null);

                var instance: Instance = .{
                    .coro = Coroutine.init(&main) catch @panic("Thread failure"),
                    .worker = &work,
                    .lvm = vm,
                };
                job.run(&instance, job.userdata);

                if (instance.coro.status == .waiting) {} else {
                    instance.coro.deinit(&main);
                }
            }

            if (len == 0) {
                vm.pending_cond.broadcast(io);
                work.sem.wait(io) catch break;
            }
            check %= 64;
        }

        const size = work.local_queue.get(io, &buff, 0) catch break;
        for (buff[0..size]) |job| {
            std.debug.assert(job.thread.?.status == .ready);
            var thread = job.thread.?;

            var instance: Instance = .{
                .coro = thread,
                .worker = &work,
                .lvm = vm,
            };
            job.run(&instance, job.userdata);

            if (instance.coro.status != .waiting) {
                thread.deinit(&main);
            }
        }
        check += 1;
    }
}

test "LVM test" {
    const c = struct {
        var sum: std.atomic.Value(f64) = .init(0);
        fn fib(instance: *Instance, _: *anyopaque) void {
            var lua = instance.coro.state;
            lua.doString(
                \\function fib(n)
                \\    if n <= 1 then
                \\        return n
                \\    end
                \\    return fib(n - 1) + fib(n - 2)
                \\end
                \\return fib(10)
            ) catch |e| @panic(@errorName(e));
            const number = lua.to(Lua.Number, -1) catch |e| @panic(@errorName(e));
            std.testing.expectEqual(55, number) catch |e| @panic(@errorName(e));
            _ = sum.fetchAdd(number, .monotonic);
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var lvm = try LVM.init(allocator, .{});

    try lvm.start(io, null, null);

    for (0..1000) |_| try lvm.run(io, c.fib, @ptrCast(@constCast(&{})));

    lvm.deinit(io);
    try std.testing.expectEqual(55 * 1000, c.sum.load(.monotonic));
}
