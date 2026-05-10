ptr: *anyopaque,
vtable: VTable,
const Generator = @This();
const Future = @import("Future.zig");
const VTable = struct {
    generate: *const fn (g: *Generator) Future,
};

pub fn generate(g: *Generator) Future {
    g.vtable.generate(g);
}
