const builtin = @import("builtin");
const std = @import("std");
const linux = std.c;
const native_os = @import("builtin").os.tag;

var pressed: std.atomic.Value(bool) = .init(false);

fn interrupt_handler(sig: linux.SIG) callconv(.c) void {
    switch (sig) {
        .INT => pressed.store(true, .acq_rel),
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
            const act: linux.Sigaction = .{
                .flags = 0,
                .handler = .{
                    &interrupt_handler,
                },
                .mask = @splat(0),
            };
            linux.sigaction(.INT, &act, null);
        },
    }
}
