state: Lua,
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
};

const VMFunc = *const fn (*Thread, userdata: *anyopaque) void;
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
        .state = try Lua.init(.{ .allocator = opts.custom_alloc_lua }),
    };
}
pub fn deinit(lvm: *LVM, io: std.Io) void {
    lvm.state.deinit();
    lvm.job_queue.close(io);
}
pub fn start(lvm: *LVM, io: std.Io) std.Io.ConcurrentError!std.Io.Future(void) {
    //TODO: HAndle future
    return try io.concurrent(run, .{ lvm, io });
}
pub fn enqueue(lvm: *LVM, io: std.Io, job: []Job, min: usize) !void {
    try lvm.job_queue.put(io, job, min);
}
pub fn enqueueOne(lvm: *LVM, io: std.Io, job: Job) !void {
    try lvm.job_queue.putOne(io, job);
}
pub fn mainThread(lvm: *LVM) Thread {
    return .{
        .state = lvm.state,
        .ref = 0,
    };
}
