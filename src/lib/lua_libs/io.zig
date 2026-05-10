const std = @import("std");
const Lua = @import("../lua/Lua.zig");
const Io = @import("../io/io.zig");
const Reader = @import("../util/Reader.zig");
const Writer = @import("../util/Writer.zig");
//TODO: move everything to lib
const Runtime = @import("../../Runtime.zig");
const Context = @import("../../ConnectionContext.zig");
const Future = @import("../../Future.zig");

const LIB: [_]Lua.LuaLib = .{
    .{ "open", open },
    .{ "close", close },
    .{ "read", read },
    .{ "write", write },
    .{ "mkdir", mkdir },
};
const FILEOBJ: [_]Lua.LuaLib = .{};
const DIROBJ: [_]Lua.LuaLib = .{
    .{ "open", open },
    .{ "read", open },
};
//assumes runtime is available
pub fn initIoLib(lua: *Lua) void {
    lua.newLib(LIB);
}

const Dir = struct {
    handle: Io.Handle,
    fn open(lua: *Lua) void {}
    fn read(lua: *Lua) void {}
    fn close(lua: *Lua) void {}
};
const File = struct {
    handle: Io.Handle,
    reader: ?Reader = null,
    writer: ?Writer = null,
    fn initFileMeta(lua: *Lua) void {}
    fn new(lua: *Lua) !*File {
        const file = try lua.newUserData(File);
        std.debug.assert(lua.getGlobal("rover") == .table);
        std.debug.assert(lua.getField("io") == .table);
        std.debug.assert(lua.getField("File") == .table);
        lua.setMetaTable(-4);
        lua.pop(2);
        return file;
    }
    fn read(lua: *Lua) void {}
    fn write(lua: *Lua) void {}
    fn close(lua: *Lua) void {}
    fn lines(lua: *Lua) void {}
};
//NOTE: Thread cancelling is a bigger problem that needs to be properly handled at the connection level
fn open(lua: *Lua, path: Lua.String) void {
    const cb = struct {
        fn wake(f: *Future, r: *Runtime) Future.State {
            const event: *Io.Event = @ptrCast(f.ctxt);
            std.debug.assert(event.status == .complete);
            std.debug.assert(event.status.complete == .openat);

            //TODO: make future take a thread_id
            const thread: *Lua = f.conn.req_threads[f.thread_id];
            const file = thread.toUserData(File, -1);
            file.handle = event.status.complete.openat catch {
                thread.fmtError("Could not open file for some reason lol", .{});
            };
        }
        fn cancel(_: *Future, _: *Runtime) void {
            //TODO: implent cancel the read in iouring
            return;
        }
    };
    std.debug.assert(lua.getField(Lua.RegistryIndex, "runtime") == .ud);
    const runtime = lua.toUserData(Runtime, -1);

    //registry[thread].context
    lua.pushThread();
    std.debug.assert(lua.getTable(Lua.RegistryIndex) == .table);
    std.debug.assert(lua.getField(-1, "context") == .ud);
    const conn_context = lua.toUserData(Context, -1);

    _ = File.new(lua) catch @panic("Unexpected error");

    //TODO: make call backs
    const event = runtime.event_pool.create() catch lua.fmtError("Reached maximum permitted I/O", .{});
    const fut = runtime.future_pool.create() catch lua.fmtError("Reached maximum permitted I/O", .{});
    fut.* = .{
        .conn = conn_context,
        .ctxt = event,
        .vtable = &.{
            .wake = cb.wake,
            .cancel = cb.cancel,
        },
    };
    event.* = .openat(fut, 0, path, .{});
    runtime.io.submit(event);
}
fn readDir(lua: *Lua) void {}
