main_thread: Thread,
job_queue: *JobQueue,

const LVM = @This();
const std = @import("std");
const lib = @import("../lib.zig");
const Lua = lib.Lua;
pub const JobQueue = std.Io.Queue(Job);
pub const Job = struct {
    run: VMFunc,
    thread: Thread,
    userdata: *anyopaque,
};

pub const Thread = struct {
    ref: c_int,
    state: Lua,
    //TODO: make a more elegant way deinit a thread (maybe a boolean that tells you if it is finished)

    pub fn yield(t: *Thread, io: std.Io, vm: *LVM, resume_func: VMFunc, ud: *anyopaque) !void {
        vm.enqueueOne(io, .{
            .run = resume_func,
            .userdata = ud,
            .thread = t.*,
        });
    }
};

pub const VMFunc = *const fn (*Thread, userdata: *anyopaque) void;
fn run(lvm: *LVM, io: std.Io) void {
    var buff: [100]Job = undefined;
    while (!lib.Util.ctrlC.isPressed()) {
        const jobs = lvm.job_queue.get(io, &buff, 1) catch break;
        const available_jobs = buff[0..jobs];
        for (available_jobs) |job| job.run(@constCast(&job.thread), job.userdata);
    }
}
const Options = struct {
    custom_alloc_lua: ?*const std.mem.Allocator = null,
};
pub fn init(queue: *JobQueue, opts: Options) !LVM {
    return .{
        .job_queue = queue,
        .main_thread = .{
            .ref = 0,
            .state = try Lua.init(.{ .allocator = opts.custom_alloc_lua }),
        },
    };
}
pub fn deinit(lvm: *LVM, io: std.Io) void {
    lvm.main_thread.state.deinit();
    lvm.job_queue.close(io);
}
pub fn start(lvm: *LVM, io: std.Io) std.Io.ConcurrentError!std.Io.Future(void) {
    //TODO: HAndle future
    return try io.concurrent(run, .{ lvm, io });
}
pub fn enqueue(lvm: *LVM, io: std.Io, job: []Job, min: usize) !void {
    try lvm.job_queue.put(io, job, min);
}
//TODO: make this function private and force users to use new api
pub fn enqueueOne(lvm: *LVM, io: std.Io, job: Job) !void {
    try lvm.job_queue.putOne(io, job);
}
pub fn runOnMain(lvm: *LVM, io: std.Io, func: VMFunc, ud: *anyopaque) !void {
    try lvm.main_thread.yield(io, lvm, func, ud);
}
