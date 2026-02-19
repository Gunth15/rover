const builtin = @import("builtin");
pub const Io = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported operating system"),
};
