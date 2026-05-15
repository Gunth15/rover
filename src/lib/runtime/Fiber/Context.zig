rsp: usize,
vstack: []u8,

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const Context = @This();
pub const Handle = *opaque {};

comptime {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const x86 = @embedFile("x86_64.asm");
            asm (x86);
        },
        else => @compileError("Unsupported cpu architecture"),
    }
}
pub const StackAlignment =
    switch (builtin.cpu.arch) {
        .x86_64 => std.mem.Alignment.@"16",
        else => @compileError("Unsupported cpu architecture"),
    };
pub extern fn switch_context(from: *Context, to: *Context) void;
fn context_bootstrap() void {
    var start: *const fn (us: *anyopaque) void = undefined;
    var userdata: *anyopaque = undefined;
    switch (builtin.cpu.arch) {
        .x86_64 => asm(
            \\ movq %%r12, %[user]
            \\ movq %%r13, %[start]
            : [user] "=r" (userdata),
            [start] "=r" (start),
        ),
        else => @compileError("Unsupported cpu architecture"),
    }
    return start(userdata);

}
pub fn init(
    stack: []u8,
    start: *const fn (us: *anyopaque) void,
    userdata: *anyopaque,
) Context {
    assert(StackAlignment.check(@intFromPtr(stack.ptr)));

    const top = @intFromPtr(stack.ptr) + stack.len;
    const atop = top & ~@as(usize, 0xF);
    var sp: [*]usize = @ptrFromInt(atop);

    sp -= 1;
    sp[0] = 0;
    sp -= 1;
    sp[0] = @intFromPtr(&context_bootstrap);

    sp -= 6;
    @memset(sp[0..6], 0);

    //store userdta in r12
    sp[3] = @intFromPtr(userdata);
    //store func in r13
    sp[2] = @intFromPtr(start);

    return Context{
        .rsp = @intFromPtr(sp),
        .vstack = stack,
    };
}

var main_context: Context = undefined;
var worker_context: Context = undefined;

const UserData = struct {
    id: u32,
    message: []const u8,
};

fn workerWithData(ptr: *anyopaque) void {
    const data: *UserData = @ptrCast(@alignCast(ptr));

    // Use the data!
    std.debug.print("Context {d} says: {s}\n", .{ data.id, data.message });

    // Yield back
    switch_context(&worker_context, &main_context);
}

test "passing userdata" {
    var my_data = UserData{ .id = 42, .message = "Hello from the stack!" };

    const stack = try std.testing.allocator.alignedAlloc(u8, StackAlignment, 4096);
    defer std.testing.allocator.free(stack);

    // We pass the address of context_entry_point as the return address,
    // and the address of workerWithData as the thing to jump to.
    worker_context = Context.init(stack, workerWithData, &my_data);
    switch_context(&main_context, &worker_context);
}
