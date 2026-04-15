conn: *ConnectionContext,
ctxt: *anyopaque,
vtable: *const VTable,
const ConnectionContext = @import("ConnectionContext.zig");
const Runtime = @import("Runtime.zig");
const Future = @This();
pub const State = enum { waiting, finished, failed };
pub const VTable = struct {
    wake: *const fn (*Future, *Runtime, *ConnectionContext, *anyopaque) State,
    cancel: *const fn (*Future, *Runtime, *ConnectionContext, *anyopaque) void,
};
pub inline fn wake(f: *Future, runtime: *Runtime) State {
    return f.vtable.wake(f, runtime, f.conn, f.ctxt);
}
//canel is called don failure
pub inline fn cancel(f: *Future, runtime: *Runtime) void {
    return f.vtable.cancel(f, runtime, f.conn, f.ctxt);
}
