conn: *ConnectionContext,
ctxt: *anyopaque,
vtable: *const VTable,
const ConnectionContext = @import("ConnectionContext.zig");
const Runtime = @import("Runtime.zig");
const Future = @This();
pub const State = enum { waiting, finished, failed };
const VTable = struct {
    wake: *const fn (*Future, *Runtime, *ConnectionContext, *anyopaque) State,
    cancel: *const fn (*Future, *Runtime, *ConnectionContext, *anyopaque) void,
};
fn create(conn: *ConnectionContext, ctxt: *anyopaque) Future {
    return Future{
        .conn = conn,
        .ctxt = ctxt,
    };
}
fn wake(f: *Future, runtime: *Runtime) State {
    return f.vtable.wake(f, runtime, f.conn, f.ctxt);
}
//canel is called don failure
fn cancel(f: *Future, runtime: *Runtime) void {
    return f.vtable.cancel(f, runtime, f.conn, f.ctxt);
}
