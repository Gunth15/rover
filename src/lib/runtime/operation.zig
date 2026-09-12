const std = @import("std");
const Io = std.Io;
const lib = @import("../lib.zig");
const Connection = lib.Connnection;
const Lua = lib.Lua;
const LVM = @import("LuaVM.zig");
const assert = std.debug.assert;

const STDERR: Io.File = .stderr();
const STDOUT: Io.File = .stdout();
const STDIN: Io.File = .stdin();

const FileWrapper = struct {
    file: std.Io.File,
    writer: ?std.Io.File.Writer = null,
    reader: ?std.Io.File.Reader = null,
};
const OperationCode = enum(u8) {
    OPEN = 0,
    READ = 1,
    WRITE = 2,
    CLOSE = 3,
    CLOCK = 4,
    CREATE = 5,
    FLUSH = 6,
    SEEK = 7,
};
pub const Operation = union(OperationCode) {
    OPEN: struct {
        file_name: []const u8,
        opts: Io.Dir.OpenFileOptions,
        read_buffer_size: usize,
        write_buffer_size: usize,
    },
    READ: struct {
        file: *FileWrapper,
        mode: ReadMode,
    },
    WRITE: struct {
        file: *FileWrapper,
        str_copy: []const u8,
    },
    CLOSE: *FileWrapper,
    CLOCK: Io.Clock,
    CREATE: struct {
        file_name: []const u8,
        opts: Io.Dir.CreateFileOptions,
        read_buffer_size: usize,
        write_buffer_size: usize,
    },
    FLUSH: *FileWrapper,
    SEEK: struct {
        file: *FileWrapper,
        mode: SeekMode = .cur,
        offset: i64,
    },

    const SeekMode = union(enum) {
        set,
        cur,
        end,
    };
    const ReadMode = union(enum) {
        line,
        all,
        number,
        read_number: usize,
    };

    pub fn decode(lua: *Lua, alloc: std.mem.Allocator, nresults: usize) !Operation {
        assert(nresults > 1);
        const op_code: OperationCode = @enumFromInt(@as(u8, @intCast(lua.to(Lua.Integer, 1) catch @panic("Not number"))));

        return try switch (op_code) {
            .OPEN => open(lua, nresults),
            .READ => read(lua, nresults),
            .WRITE => write(lua, nresults, alloc),
            .CLOSE => close(lua, nresults),
            .CLOCK => clock(lua, nresults),
            .FLUSH => flush(lua, nresults),
            .SEEK => seek(lua, nresults),
            .CREATE => create(lua, nresults),
        };
    }
    pub fn dispatch(
        op: Operation,
        ctxt: *lib.Connnection.Context,
        t: LVM.Thread,
    ) void {
        switch (op) {
            .CREATE => |args| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn createFile(context: *lib.Connnection.Context, thread: LVM.Thread, ag: @TypeOf(args)) void {
                        const io = context.runtime.io;
                        const arena = context.arena.allocator();
                        const file = Io.Dir.cwd().createFile(io, ag.file_name, ag.opts) catch @panic("TODO: handle possible errors");

                        const fw: *FileWrapper = arena.create(FileWrapper) catch @panic("TODO");
                        fw.* = .{
                            .file = file,
                            .writer = file.writer(io, arena.alloc(u8, ag.write_buffer_size) catch @panic("TODO")),
                            .reader = file.reader(io, arena.alloc(u8, ag.read_buffer_size) catch @panic("TODO")),
                        };
                        const Closure = struct {
                            connection_context: *Connection.Context,
                            file: *FileWrapper,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .file = fw,
                            .connection_context = context,
                        };

                        context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer c.connection_context.runtime.allocator.destroy(c);

                                    td.state.push(c.file);

                                    Connection.execute(td, c.connection_context);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(closure)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.createFile, .{ ctxt, t, args }) catch @panic("TODO");
            },
            .OPEN => |args| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn openFile(context: *lib.Connnection.Context, thread: LVM.Thread, ag: @TypeOf(args)) void {
                        const io = context.runtime.io;
                        const arena = context.arena.allocator();
                        const file = Io.Dir.openFile(Io.Dir.cwd(), io, ag.file_name, ag.opts) catch @panic("TODO: handle possible errors");

                        const fw: *FileWrapper = arena.create(FileWrapper) catch @panic("TODO");
                        fw.* = .{
                            .file = file,
                            .writer = file.writer(io, arena.alloc(u8, ag.write_buffer_size) catch @panic("TODO")),
                            .reader = file.reader(io, arena.alloc(u8, ag.read_buffer_size) catch @panic("TODO")),
                        };

                        const Closure = struct {
                            connection_context: *Connection.Context,
                            file: *FileWrapper,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .file = fw,
                            .connection_context = context,
                        };

                        context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer c.connection_context.runtime.allocator.destroy(c);
                                    td.state.push(c.file);
                                    Connection.execute(td, c.connection_context);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(closure)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.openFile, .{ ctxt, t, args }) catch @panic("TODO");
            },
            .READ => |args| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn readFile(context: *lib.Connnection.Context, thread: LVM.Thread, ag: @TypeOf(args)) void {
                        var writer = Io.Writer.Allocating.init(context.runtime.allocator);

                        var reader = ag.file.reader orelse @panic("FUCK");
                        const w = &writer.writer;
                        switch (ag.mode) {
                            .line => _ = reader.interface.streamDelimiter(w, '\n') catch @panic("TODO"),
                            .all => _ = reader.interface.streamRemaining(w) catch @panic("TODO"),
                            .number => {
                                var number_start: ?usize = null;
                                var number_end: ?usize = null;
                                while (number_start == null) {
                                    reader.interface.streamExact(w, 1) catch @panic("TODO");
                                    const buff = w.buffered();
                                    if (buff[buff.len - 1] == '+' or buff[buff.len - 1] == '-' or std.ascii.isWhitespace(buff[buff.len - 1])) continue
                                    //
                                    else number_start = buff.len - 1;
                                }
                                while (number_end == null) {
                                    reader.interface.streamExact(w, 1) catch @panic("TODO");
                                    const buff = w.buffered();
                                    if (std.ascii.isDigit(buff[buff.len - 1])) continue
                                    //
                                    else number_end = buff.len - 1;
                                }

                                const int = std.fmt.parseInt(u8, w.buffered()[number_start.? .. number_end.? + 1], 0) catch |e| switch (e) {
                                    error.Overflow => @panic("TODO"),
                                    error.InvalidCharacter => @panic("TODO"),
                                };

                                const Closure = struct {
                                    connection_context: *Connection.Context,
                                    number: usize,
                                };
                                const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                                closure.* = .{
                                    .connection_context = context,
                                    .number = int,
                                };
                                return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                                    .run = struct {
                                        fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                            const c: *Closure = @ptrCast(@alignCast(ct));
                                            defer c.connection_context.runtime.allocator.destroy(c);

                                            const conn = c.connection_context;
                                            td.state.push(c.number);
                                            Connection.execute(td, conn);
                                        }
                                    }.run,
                                    .userdata = @ptrCast(@alignCast(closure)),
                                    .thread = thread,
                                }) catch |e| @panic(@errorName(e));
                            },
                            .read_number => |n| reader.interface.streamExact(w, n) catch @panic("TODO"),
                        }

                        const Closure = struct {
                            connection_context: *Connection.Context,
                            str: []const u8,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .str = writer.toOwnedSlice() catch @panic("TODO"),
                            .connection_context = context,
                        };

                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer {
                                        c.connection_context.runtime.allocator.free(c.str);
                                        c.connection_context.runtime.allocator.destroy(c);
                                    }
                                    const conn = c.connection_context;
                                    td.state.push(c.str);
                                    Connection.execute(td, conn);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(closure)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.readFile, .{ ctxt, t, args }) catch @panic("TODO");
            },
            .WRITE => |args| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn writeFile(context: *lib.Connnection.Context, thread: LVM.Thread, ag: @TypeOf(args)) void {
                        const str = ag.str_copy;
                        defer context.runtime.allocator.free(str);

                        ag.file.writer.?.interface.writeAll(str) catch @panic("TODO");

                        const Closure = struct {
                            connection_context: *Connection.Context,
                            file: *FileWrapper,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .connection_context = context,
                            .file = ag.file,
                        };

                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer c.connection_context.runtime.allocator.destroy(c);

                                    const conn = c.connection_context;

                                    td.state.push(c.file);
                                    Connection.execute(td, conn);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(closure)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.writeFile, .{ ctxt, t, args }) catch @panic("TODO");
            },
            .CLOSE => |file| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn closeFile(context: *lib.Connnection.Context, thread: LVM.Thread, f: @TypeOf(file)) void {
                        f.file.close(context.runtime.io);
                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Connection.Context = @ptrCast(@alignCast(ct));
                                    Connection.execute(td, c);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(context)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.closeFile, .{ ctxt, t, file }) catch @panic("TODO");
            },
            .CLOCK => |cl| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn clockingIt(context: *lib.Connnection.Context, thread: LVM.Thread, clo: @TypeOf(cl)) void {
                        const timestamp = clo.now(context.runtime.io);

                        const Closure = struct {
                            connection_context: *Connection.Context,
                            time: i64,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .connection_context = context,
                            .time = timestamp.toMilliseconds(),
                        };
                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer c.connection_context.runtime.allocator.destroy(c);
                                    td.state.push(c.time);
                                    const conn = c.connection_context;
                                    Connection.execute(td, conn);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(context)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.clockingIt, .{ ctxt, t, cl }) catch @panic("TODO");
            },
            .FLUSH => |file| {
                _ = ctxt.runtime.io.concurrent(struct {
                    fn flushFile(context: *lib.Connnection.Context, thread: LVM.Thread, f: @TypeOf(file)) void {
                        f.writer.?.flush() catch @panic("TODO");
                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Connection.Context = @ptrCast(@alignCast(ct));
                                    Connection.execute(td, c);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(context)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.flushFile, .{ ctxt, t, file }) catch @panic("TODO");
            },
            .SEEK => |arg| {
                _ = ctxt.runtime.io.concurrent(struct {
                    //TODO:
                    fn seekFile(context: *lib.Connnection.Context, thread: LVM.Thread, ag: @TypeOf(arg)) void {
                        const reader: *Io.File.Reader = &ag.file.reader.?;
                        switch (ag.mode) {
                            .set => {
                                if (ag.offset < 0) @panic("TODO");
                                reader.seekTo(@intCast(ag.offset)) catch @panic("TODO");
                            },
                            .cur => reader.seekBy(ag.offset) catch @panic("TODO"),
                            .end => {
                                const end = reader.getSize() catch @panic("TODO");
                                reader.seekTo(end) catch @panic("TODO");
                                reader.seekBy(ag.offset) catch @panic("TODO");
                            },
                        }
                        const Closure = struct {
                            connection_context: *Connection.Context,
                            pos: u64,
                        };
                        const closure: *Closure = context.runtime.allocator.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .connection_context = context,
                            .pos = reader.logicalPos(),
                        };
                        return context.runtime.lvm.enqueueOne(context.runtime.io, .{
                            .run = struct {
                                fn run(td: *LVM.Thread, ct: *anyopaque) void {
                                    const c: *Closure = @ptrCast(@alignCast(ct));
                                    defer c.connection_context.runtime.allocator.destroy(c);
                                    td.state.push(c.pos);
                                    const conn = c.connection_context;
                                    Connection.execute(td, conn);
                                }
                            }.run,
                            .userdata = @ptrCast(@alignCast(context)),
                            .thread = thread,
                        }) catch |e| @panic(@errorName(e));
                    }
                }.seekFile, .{ ctxt, t, arg }) catch @panic("TODO");
            },
        }
    }
    fn open(lua: *Lua, nresults: usize) !Operation {
        const Options = std.Io.Dir.OpenFileOptions;
        assert(nresults <= 3);

        const filename = lua.to(Lua.String, 2) catch @panic("TODO");

        var r_size: usize = 4096;
        var w_size: usize = 4096;
        var opts: Options = .{};
        if (nresults == 3) {
            lua.check(3, .table);
            if (lua.getField(3, "mode") == .string) {
                const mode = lua.to(Lua.String, -1) catch unreachable;
                opts.mode = std.meta.stringToEnum(Options.Mode, mode) orelse lua.argError(2,
                    \\Invalid mode. Supported modes are "read_only", "write_only", and "read_write"
                );
            }
            if (lua.getField(3, "write_buffer_size") == .number) {
                w_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
                if (w_size < 0) lua.argError(3, "write_buffer_size must be a positive integer");
            }
            if (lua.getField(3, "read_buffer_size") == .number) {
                r_size = @intFromFloat(lua.to(Lua.Number, -1) catch unreachable);
                if (r_size < 0) lua.argError(3, "read_buffer_size must be a positive integer");
            }
        }

        return .{
            .OPEN = .{
                .file_name = filename,
                .read_buffer_size = r_size,
                .write_buffer_size = w_size,
                .opts = opts,
            },
        };
    }
    //NOTE: does not implement io.tmpfile, io.input,io.output,io.popen,file:setvbuf
    fn create(lua: *Lua, nresults: usize) !Operation {
        const Options = std.Io.Dir.CreateFileOptions;
        assert(nresults < 4);

        const file_path = lua.to(Lua.String, 2) catch @panic("TODO");

        var r_size: usize = 4096;
        var w_size: usize = 4096;
        var opts: Options = .{};
        if (nresults > 2) {
            lua.check(3, .table);

            if (lua.getField(3, "read") == .bool) opts.read = lua.to(Lua.Bool, -1) catch @panic("TODO");
            if (lua.getField(3, "write_buffer_size") == .number) {
                w_size = @intFromFloat(lua.to(Lua.Number, -1) catch @panic("TODO"));
                if (w_size < 0) lua.argError(3, "write_buffer_size must be a positive integer");
            }
            if (lua.getField(3, "read_buffer_size") == .number) {
                r_size = @intFromFloat(lua.to(Lua.Number, -1) catch @panic("TODO"));
                if (r_size < 0) lua.argError(3, "read_buffer_size must be a positive integer");
            }
        }

        return .{
            .CREATE = .{
                .file_name = file_path,
                .opts = opts,
                .read_buffer_size = r_size,
                .write_buffer_size = w_size,
            },
        };
    }
    fn write(lua: *Lua, nresults: usize, alloc: std.mem.Allocator) !Operation {
        assert(nresults == 3);

        //OPTIMIZE: Copy to buffer before trying to allocate
        const file: *FileWrapper = lua.toUserData(FileWrapper, 2);
        const str = lua.to(Lua.String, 3) catch @panic("TODO");
        const str_copy = try alloc.dupe(u8, str);
        return .{
            .WRITE = .{
                .file = file,
                .str_copy = @constCast(str_copy),
            },
        };
    }
    fn read(lua: *Lua, nresults: usize) !Operation {
        assert(nresults <= 3);

        const file: *FileWrapper = lua.toUserData(FileWrapper, 2);
        const mode_str = lua.to(Lua.String, 3) catch @panic("TODO");
        const mode: Operation.ReadMode = mode: {
            if (std.mem.eql(u8, mode_str, "*line")) break :mode .line
            //
            else if (std.mem.eql(u8, mode_str, "*all")) break :mode .all
            //
            else if (std.mem.eql(u8, mode_str, "*number")) break :mode .number
            //
            else {
                const number = try std.fmt.parseInt(usize, mode_str, 10);
                break :mode .{
                    .read_number = number,
                };
            }
        };
        return .{
            .READ = .{
                .file = file,
                .mode = mode,
            },
        };
    }
    fn close(lua: *Lua, nresults: usize) !Operation {
        assert(nresults == 2);

        const file = lua.toUserData(FileWrapper, 2);
        return .{ .CLOSE = file };
    }
    fn flush(lua: *Lua, nresults: usize) !Operation {
        assert(nresults == 2);

        const file = lua.toUserData(FileWrapper, 2);
        return .{ .FLUSH = file };
    }
    fn seek(lua: *Lua, nresults: usize) !Operation {
        assert(nresults > 1);
        const file = lua.toUserData(FileWrapper, 2);
        const mode_str = if (nresults < 3) "cur" else lua.to(Lua.String, 3) catch @panic("TODO");
        const mode: Operation.SeekMode = mode: {
            if (std.mem.eql(u8, mode_str, "set")) break :mode .set
            //
            else if (std.mem.eql(u8, mode_str, "cur")) break :mode .cur
            //
            else if (std.mem.eql(u8, mode_str, "end")) break :mode .end
            //TODO: Error
            else break :mode .cur;
        };
        const offset = if (nresults < 3) 0 else lua.to(Lua.Integer, 4) catch @panic("TODO");
        return .{
            .SEEK = .{
                .file = file,
                .mode = mode,
                .offset = @intCast(offset),
            },
        };
    }
    //NOTE: does not implement os.getenv and os.tmpname
    //os functions
    fn clock(lua: *Lua, nresults: usize) !Operation {
        assert(nresults <= 2);
        const clocketh: Io.Clock = c: {
            if (nresults == 2) {
                lua.check(2, .ud);
                const clock_str = lua.to(Lua.String, 2) catch unreachable;
                break :c std.meta.stringToEnum(
                    Io.Clock,
                    clock_str,
                ) orelse return error.InvalidClock;
            } else break :c .cpu_process;
        };
        return .{ .CLOCK = clocketh };
    }
    //fn rename(lua: *Lua) c_int {}
};
