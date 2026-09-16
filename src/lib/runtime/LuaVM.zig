//optomize: reuse job allocations
job_queue: std.DoublyLinkedList = .{},
mut: std.Io.Mutex = .init,
cond: std.Io.Condition = .init,
vm_count: std.atomic(usize),
busy_count: std.atomic(usize),
allocator: std.mem.Allocator,

const LVM = @This();
const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
pub const JobQueue = std.Io.Queue(Job);
pub const Job = struct {
    run: VMFunc,
    thread: ?Coroutine,
    userdata: *anyopaque,
    node: std.DoublyLinkedList.Node = .{},
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
    fn deinit(t: *Coroutine) void {
        t.state.unref(t.ref);
        t.state.deinit();
    }
};
pub const VMWorker = struct {
    coro_queue: std.DoublyLinkedList = .{},
    mut: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
};

const Options = struct {
    vm_count: ?usize = null,
    job_queue_size: usize = 250,
};
pub fn init(allocator: std.mem.Allocator, opts: Options) !LVM {
    return .{
        .vm_count = opts.vm_count orelse try std.Coroutine.getCpuCount(),
        .job_queue = JobQueue.init(try allocator.alloc(Job, 250)),
        .mut = .init,
        .allocator = allocator,
    };
}
pub fn deinit(lvm: *LVM, io: std.Io) void {
    lvm.main_thread.state.deinit();
    lvm.job_queue.close(io);
}

pub const Instance = struct {
    coro: *Coroutine,
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
        const coro = i.coro;
        const work = i.worker;

        std.debug.assert(coro.status == .waiting);
        coro.status = .ready;

        const lvm = i.lvm;
        const job = try lvm.allocator.create(Job);
        job.* = .{
            .run = resume_func,
            .userdata = ud,
            .thread = null,
        };

        i.worker.mut.lock(io);
        defer i.worker.mut.unlock(io);

        work.coro_queue.append(job.node);
        work.cond.signal(io);
    }
};

pub const VMFunc = *const fn (Instance, userdata: *anyopaque) void;
fn run(lvm: *LVM, io: std.Io, vmfunc: VMFunc, ud: *anyopaque) !void {
    lvm.mut.lock(io);
    defer lvm.mut.unlock(io);

    const job = try lvm.allocator.create(Job);
    job.* = .{
        .run = vmfunc,
        .userdata = ud,
        .thread = null,
    };
    lvm.job_queue.append(job.node);
    lvm.cond.signal(io);
}
fn getJob(lvm: *LVM, io: std.Io) ?*Job {
    lvm.mut.lock(io);
    defer lvm.mut.unlock(io);

    const node = lvm.job_queue.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}
fn wait(lvm: *LVM, io: std.Io) !void {
    return try lvm.cond.wait(io, lvm.mut);
}
fn getJobs(lvm: *LVM, io: std.Io, buff: []*Job) usize {
    lvm.mut.lock(io);
    defer lvm.mut.unlock(io);

    while (lvm.job_queue.first == null) lvm.cond.wait(io, lvm.mut);

    var len: usize = 0;
    while (lvm.job_queue.popFirst()) |node| {
        buff[len] = @fieldParentPtr("node", node);
        len += 1;
    }
    return len;
}

pub fn start(lvm: *LVM, io: std.Io) std.Io.ConcurrentError!std.Io.Future(void) {
    //TODO: HAndle future
    return try io.concurrent(run, .{ lvm, io });
}

fn worker(vm: *LVM, io: std.Io) void {
    var main = try Lua.init(.{ .allocator = &vm.allocator });
    var waiting_coroutines: usize = 0;
    var work: VMWorker = .{
        .coro_queue = .{},
        .mut = .init,
    };

    var buff: [100]Job = undefined;
    while (!lib.Util.ctrlC.isPressed()) {
        const len = len: {
            var l = vm.getJobs(io, &buff) catch break;
            while (l == 0 and waiting_coroutines == 0) {
                vm.wait(io);
                l = vm.getJobs(io, &buff);
            }
            break :len l;
        };

        for (buff[0..len]) |job| {
            std.debug.assert(job.thread == null);

            job.thread = .init(&main) catch break;
            const instance: Instance = .{
                .coro = &job.thread.?,
                .worker = &work,
                .lvm = &vm,
            };
            job.run(instance, job.userdata);

            if (job.thread.?.status == .waiting) {
                waiting_coroutines += 1;
            } else job.thread.?.deinit();
        }

        {
            //Local work is prioritised
            //NOTE: guranteed SCMP
            work.mut.lock(io);
            defer work.mut.unlock(io);

            while (work.coro_queue.first == null and waiting_coroutines != 0) work.cond.wait(io, work.mut) catch break;

            while (work.coro_queue.popFirst()) |node| {
                const job: *Job = @fieldParentPtr("node", node);
                std.debug.assert(job.thread != null);
                std.debug.assert(job.thread.?.status == .ready);

                const instance: Instance = .{
                    .coro = &job.thread.?,
                    .worker = &work,
                    .lvm = &vm,
                };

                job.run(instance, job.userdata);

                if (job.thread.?.status != .waiting) {
                    waiting_coroutines -= 1;
                    job.thread.?.deinit();
                }
            }
        }
    }
}
