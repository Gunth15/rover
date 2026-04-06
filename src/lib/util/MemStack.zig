buffer: []u8,
step: usize,
free_list: struct {
    data: []usize,
    top: usize,
},

const std = @import("std");
const Allocator = std.mem.Allocator;

//Memstack is stack is a slab allocator
//can make a lot of assumptions if bufsize and step are equal to two
const MemStack = @This();
pub fn init(alloc: std.mem.Allocator, bufsize: usize, step: usize) !MemStack {
    std.debug.assert(std.math.isPowerOfTwo(step));
    std.debug.assert(std.math.isPowerOfTwo(bufsize));
    var stack: MemStack = .{
        .buffer = try alloc.alloc(u8, bufsize),
        .step = step,
        .free_list = .{
            .top = 0,
            // total pointers = bufsize/top
            .data = try alloc.alloc([]usize, @divFloor(bufsize, step)),
        },
    };

    //alocate buffers
    for (0..stack.free_list.len) |i| {
        stack.free_list[i] = step * i;
    }
}
pub fn deinit(stack: *MemStack, alloc: std.mem.Allocator) error{Empty}!void {
    alloc.destroy(stack.buffer);
}
pub fn acquire(stack: *MemStack) std.heap.FixedBufferAllocator {
    const free_list = stack.free_list.data;
    const start = stack.free_list.top;
    const end = start + stack.step;

    if (start == stack.free_list.len) return error.Empty;

    stack.free_list.top += 1;

    return .init(stack.buffer[free_list[start..end]]);
}
pub fn returnBuf(stack: *MemStack, bufalloc: std.heap.FixedBufferAllocator) void {
    bufalloc.reset();
    const index = @divExact(@intFromPtr(bufalloc.buffer.ptr) - @intFromPtr(stack.buffer.ptr), @sizeOf(u8));
    const top = stack.free_list.top;

    stack.free_list.top -= 1;
    stack.free_list.data[top] = index;
}
