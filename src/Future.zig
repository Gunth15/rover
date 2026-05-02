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
///run one after another. If one fails, the next is not ran
pub fn seq() Future {}
///runs all at the same time and returns all results
pub fn group() Future {}
///If one fails, they all fail and are cancelled
pub fn failGroup() Future {}
///First one to finish is returned without failure, the others are cancelled(doe snot gurantee the others will be completed however)
pub fn select() Future {}
///First one to finish is returned, even if it fails, the others are cancelled
pub fn failSelect() Future {}
