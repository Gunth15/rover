const std = @import("std");
const engine = @import("engine.zig");
const Io = std.Io;

const EXAMPLE = "example.html";
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, "example.html", .{ .mode = .read_only });
    const out = try cwd.createFile(io, "example.lua", .{});

    var reader = file.reader(io, try alloc.alloc(u8, 4096));

    var writer = out.writer(io, try alloc.alloc(u8, 4096));
    defer writer.flush() catch {};

    try engine.compile("example", &reader.interface, &writer.interface);
}
