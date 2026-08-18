const std = @import("std");
const lib = @import("../lib.zig");
const LVM = @import("../runtime/LuaVM.zig");
const Io = std.Io;
const Lua = @import("../lua/Lua.zig");
const Thread = lib.Connnection.Thread;
const assert = std.debug.assert;

const ThreadQueue = Io.Queue(c_int);

fn luaCB(t: *LVM.Thread, _: *anyopaque) !void {
    t.
}
pub fn roverAsyncFunction(lua: *Lua, runtime: *lib.Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) c_int {
    const cb = struct {
        //TODO: handle status
        fn asyncCallback(l: Lua, _: usize, ctxt: *const anyopaque) c_int {
            assert(lua.getField(Lua.RegistryIndex, "rover_runtime") == .lightud);
            const rt = lua.toUserData(lib.Runtime, -1);

            const fut: *@typeInfo(@TypeOf(function)).@"fn".return_type.? = ctxt;
            const result = fut.await(rt.io);

            l.push(result);
            return 1;
        }
        fn requeueCallback(rt: *lib.Runtime, t: *LVM.Thread, a: std.meta.ArgsTuple(@TypeOf(function))) !void {
            @call(.auto, function, a);
            rt.lvm.enqueueOne(rt.io, .{ 
                .thread = t,
                .userdata = @intCast(0),
                .run = 
            });
        }
    };
    assert(lua.getField(Lua.RegistryIndex, "rover_runtime") == .lightud);
    const rt = lua.toUserData(lib.Runtime, -1);

    //TODO: add lua function -> cal this function -> yields and places thread_id on queue when returned and await completion
    const fut = lua.newUserData(@typeInfo(@TypeOf(function)).@"fn".return_type.?) catch @panic("YOU OOMED NERD");
    fut.* = rt.io.concurrent(cb.requeueCallback, .{ thread, args }) catch {
        const f = rt.io.async(function, .{ thread, args });
        const result = f.await(rt.io);
        lua.push(result);
        return 1;
    };
    return lua.yield(0, @ptrCast(fut), cb.asyncCallback);
}
