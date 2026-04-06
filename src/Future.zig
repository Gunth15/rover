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
fn wake(f: *Future, runtime: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) State {
    return f.vtable.wake(conn, runtime, ctxt);
}
//canel is called don failure
fn cancel(f: *Future, runtime: *Runtime, conn: *ConnectionContext, ctxt: *anyopaque) void {
    f.vtable.cancel(conn, runtime, ctxt);
}
