const std = @import("std");
const lib = @import("../lib.zig");
const Io = std.Io;
const Lua = @import("../lua/Lua.zig");
const Thread = lib.Connnection.Thread;
const assert = std.debug.assert;

const ThreadQueue = Io.Queue(c_int);

pub fn roverAsyncFunction(lua: *Lua, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) c_int {
    const cb = struct {
        //TODO: handle status
        fn asyncCallback(l: Lua, status: usize, ctxt: *const anyopaque) c_int {
            assert(l.getField(Lua.RegistryIndex, "rover_io") == .lightud);
            const io = l.toUserData(Io, -1);

            assert(l.getField(Lua.RegistryIndex, "rover_io_queue") == .lightud);
            const queue = l.toUserData(ThreadQueue, -1);

            assert(l.getField(Lua.RegistryIndex, "rover_thread_id") == .number);
            const id: c_int = @intFromFloat(l.to(Lua.Number, -1) catch unreachable);

            const fut: *@typeInfo(@TypeOf(function)).@"fn".return_type.? = ctxt;
            const result = fut.await(io);

            queue.putOne(io, id) catch |e| lua.fmtError("%s", .{@errorName(e)});
            l.push(result);
            return 1;
        }
    };
    assert(lua.getField(Lua.RegistryIndex, "rover_io") == .lightud);
    const io = lua.toUserData(Io, -1);

    //TODO: add lua function -> cal this function -> yields and places thread_id on queue when returned and await completion
    const fut = lua.newUserData(@typeInfo(@TypeOf(function)).@"fn".return_type.?) catch @panic("YOU OOMED NERD");
    fut.* = io.concurrent(function, args) catch {
        const f = io.async(function, args);
        const result = f.await(io);
        lua.push(result);
        return 1;
    };
    return lua.yield(0, @ptrCast(fut), cb.asyncCallback);
}
