const builtin = @import("builtin");
const std = @import("std");
const linux = std.c;
const native_os = @import("builtin").os.tag;

var pressed: std.atomic.Value(bool) = .init(false);

fn interrupt_handler(sig: linux.SIG) callconv(.c) void {
    switch (sig) {
        .INT => pressed.store(true, .release),
        else => {},
    }
}

pub fn isPressed() bool {
    return pressed.load(.monotonic);
}

pub fn init() void {
    switch (native_os) {
        .windows => @compileError("Ctrl-c not implemented yet lol."),
        else => {
            var set: linux.sigset_t = undefined;
            _ = linux.sigemptyset(&set);

            const act: linux.Sigaction = .{
                .flags = 0,
                .handler = .{ .handler = interrupt_handler },
                .mask = set,
            };
            _ = linux.sigaction(.INT, &act, null);
        },
    }
}
