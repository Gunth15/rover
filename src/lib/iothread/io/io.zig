impl: Impl,

const builtin = @import("builtin");
const interface = @import("interface.zig");

const Io = @This();

pub const Handle = interface.Handle;
pub const Event = interface.Event;
pub const Status = interface.Status;
pub const Completion = interface.Completion;
pub const Submission = interface.Submission;
pub const Operation = interface.Operation;
pub const CompletionReturn = interface.CompletionReturn;
pub const OpenOptions = interface.OpenOptions;
pub const SendOptions = interface.SendOptions;

//Implementation must define 4 functions
// 1. init: how to initialize async io
// 2. deinit: how to deinitialize async io
// 3. submit: how to submit task to io
// 4. flush: how to drain io and wait if needed
// 5. wake: notifies IO to exit blocking state
// Sadly specific IO errors are not part of the interface, so must be debugged in the implementation
const Impl = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported operating system"),
};
pub inline fn init(options: interface.Options) !Io {
    return .{
        .impl = try Impl.init(options),
    };
}
pub inline fn deinit(self: *Io) void {
    return self.impl.deinit();
}
pub inline fn submit(self: *Io, sub: *Event) error{ IOFull, PathTooLong }!void {
    return self.impl.submit(sub);
}
pub inline fn flush(self: *Io, events: []*Event) error{UnableToFlush}![]*Event {
    return self.impl.flush(events);
}
pub inline fn wake(self: *Io) void {
    return self.impl.wake();
}
