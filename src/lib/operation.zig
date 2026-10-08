const std = @import("std");
const Io = std.Io;
const lib = @import("lib.zig");
const Connection = lib.Connnection;
const Lua = lib.Lua;
const LVM = lib.LVM;
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
        t: *LVM.Instance,
        io: Io,
        allocator: std.mem.Allocator,
        callback: LVM.VMFunc,
        ctxt: *anyopaque,
        comptime ContextType: type,
    ) void {
        const ctx: *ContextType = @ptrCast(@alignCast(ctxt));

        switch (op) {
            .CREATE => |args| {
                _ = t.yield(io, struct {
                    fn createFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        ag: @TypeOf(args),
                    ) void {
                        const file = Io.Dir.cwd().createFile(cio, ag.file_name, ag.opts) catch @panic("TODO: handle possible errors");

                        const fw: *FileWrapper = alloc.create(FileWrapper) catch @panic("TODO");
                        fw.* = .{
                            .file = file,
                            .writer = file.writer(cio, alloc.alloc(u8, ag.write_buffer_size) catch @panic("TODO")),
                            .reader = file.reader(cio, alloc.alloc(u8, ag.read_buffer_size) catch @panic("TODO")),
                        };

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            file: *FileWrapper,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .alloc = alloc,
                            .context = c,
                            .file = fw,
                            .callback = cb,
                        };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const co = cl.context;
                                const f = cl.file;
                                const callb = cl.callback;
                                a.destroy(cl);

                                inst.coro.state.push(f);
                                callb(inst, co);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.createFile, .{ t.*, io, allocator, callback, ctx, args }) catch @panic("TODO");
            },

            .OPEN => |args| {
                _ = t.yield(io, struct {
                    fn openFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        ag: @TypeOf(args),
                    ) void {
                        const file = Io.Dir.openFile(Io.Dir.cwd(), cio, ag.file_name, ag.opts) catch @panic("TODO: handle possible errors");

                        const fw: *FileWrapper = alloc.create(FileWrapper) catch @panic("TODO");
                        fw.* = .{
                            .file = file,
                            .writer = file.writer(cio, alloc.alloc(u8, ag.write_buffer_size) catch @panic("TODO")),
                            .reader = file.reader(cio, alloc.alloc(u8, ag.read_buffer_size) catch @panic("TODO")),
                        };

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            file: *FileWrapper,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{
                            .alloc = alloc,
                            .context = c,
                            .file = fw,
                            .callback = cb,
                        };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const co = cl.context;
                                const f = cl.file;
                                const callb = cl.callback;
                                a.destroy(cl);

                                inst.coro.state.push(f);
                                callb(inst, co);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.openFile, .{ t.*, io, allocator, callback, ctx, args }) catch @panic("TODO");
            },

            .READ => |args| {
                _ = t.yield(io, struct {
                    fn readFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        ag: @TypeOf(args),
                    ) void {
                        var writer = Io.Writer.Allocating.init(alloc);
                        const w = &writer.writer;

                        const reader: *Io.File.Reader = if (ag.file.reader) |*r| r else @panic("file not opened for reading");

                        switch (ag.mode) {
                            .line => _ = reader.interface.streamDelimiter(w, '\n') catch @panic("TODO"),
                            .all => _ = reader.interface.streamRemaining(w) catch @panic("TODO"),
                            .read_number => |n| reader.interface.streamExact(w, n) catch @panic("TODO"),
                            .number => {
                                var number_start: ?usize = null;
                                var number_end: ?usize = null;
                                while (number_start == null) {
                                    reader.interface.streamExact(w, 1) catch @panic("TODO");
                                    const buff = w.buffered();
                                    const ch = buff[buff.len - 1];
                                    if (ch == '+' or ch == '-' or std.ascii.isWhitespace(ch)) continue;
                                    number_start = buff.len - 1;
                                }
                                while (number_end == null) {
                                    reader.interface.streamExact(w, 1) catch @panic("TODO");
                                    const buff = w.buffered();
                                    if (std.ascii.isDigit(buff[buff.len - 1])) continue;
                                    number_end = buff.len - 1;
                                }

                                const int = std.fmt.parseInt(usize, w.buffered()[number_start.?..number_end.?], 0) catch |e| switch (e) {
                                    error.Overflow => @panic("TODO"),
                                    error.InvalidCharacter => @panic("TODO"),
                                };
                                writer.deinit();

                                const Closure = struct {
                                    alloc: std.mem.Allocator,
                                    context: *ContextType,
                                    number: usize,
                                    callback: LVM.VMFunc,
                                };
                                const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                                closure.* = .{ .alloc = alloc, .context = c, .number = int, .callback = cb };

                                instance.resumeC(cio, struct {
                                    fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                        const cl: *Closure = @ptrCast(@alignCast(ct));
                                        const a = cl.alloc;
                                        const contxt = cl.context;
                                        const n = cl.number;
                                        const callb = cl.callback;
                                        a.destroy(cl);

                                        inst.coro.state.push(n);
                                        callb(inst, contxt);
                                    }
                                }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                                return;
                            },
                        }

                        const str = writer.toOwnedSlice() catch @panic("TODO");

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            str: []const u8,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .str = str, .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const contxt = cl.context;
                                const callb = cl.callback;
                                a.destroy(cl);

                                inst.coro.state.push(cl.str);
                                a.free(cl.str);

                                callb(inst, contxt);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.readFile, .{ t.*, io, allocator, callback, ctx, args }) catch @panic("TODO");
            },

            .WRITE => |args| {
                _ = t.yield(io, struct {
                    fn writeFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        ag: @TypeOf(args),
                    ) void {
                        const str = ag.str_copy;
                        defer alloc.free(str);

                        ag.file.writer.?.interface.writeAll(str) catch @panic("TODO");

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            file: *FileWrapper,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .file = ag.file, .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const contxt = cl.context;
                                const f = cl.file;
                                const callb = cl.callback;
                                a.destroy(cl);

                                inst.coro.state.push(f);
                                callb(inst, contxt);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.writeFile, .{ t.*, io, allocator, callback, ctx, args }) catch @panic("TODO");
            },

            .CLOSE => |file| {
                _ = t.yield(io, struct {
                    fn closeFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        f: @TypeOf(file),
                    ) void {
                        if (f.writer) |*w| w.interface.flush() catch @panic("TODO");
                        f.file.close(cio);

                        if (f.writer) |*w| alloc.free(w.interface.buffer);
                        if (f.reader) |*r| alloc.free(r.interface.buffer);
                        alloc.destroy(f);

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const contxt = cl.context;
                                const callb = cl.callback;
                                a.destroy(cl);

                                callb(inst, contxt);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.closeFile, .{ t.*, io, allocator, callback, ctx, file }) catch @panic("TODO");
            },

            .CLOCK => |cl_arg| {
                _ = t.yield(io, struct {
                    fn clockingIt(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        clo: @TypeOf(cl_arg),
                    ) void {
                        const timestamp = clo.now(cio);

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            time: i64,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .time = timestamp.toMilliseconds(), .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const contxt = cl.context;
                                const callb = cl.callback;

                                inst.coro.state.push(cl.time);

                                a.destroy(cl);
                                callb(inst, contxt);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.clockingIt, .{ t.*, io, allocator, callback, ctx, cl_arg }) catch @panic("TODO");
            },

            .FLUSH => |file| {
                _ = t.yield(io, struct {
                    fn flushFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        f: @TypeOf(file),
                    ) void {
                        f.writer.?.interface.flush() catch @panic("TODO");

                        const Closure = struct {
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                const a = cl.alloc;
                                const callb = cl.callback;

                                a.destroy(cl);
                                callb(inst, cl.context);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.flushFile, .{ t.*, io, allocator, callback, ctx, file }) catch @panic("TODO");
            },

            .SEEK => |arg| {
                _ = t.yield(io, struct {
                    fn seekFile(
                        instance: LVM.Instance,
                        cio: Io,
                        alloc: std.mem.Allocator,
                        cb: LVM.VMFunc,
                        c: *ContextType,
                        ag: @TypeOf(arg),
                    ) void {
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
                            alloc: std.mem.Allocator,
                            context: *ContextType,
                            pos: u64,
                            callback: LVM.VMFunc,
                        };
                        const closure: *Closure = alloc.create(Closure) catch @panic("TODO");
                        closure.* = .{ .alloc = alloc, .context = c, .pos = reader.logicalPos(), .callback = cb };

                        instance.resumeC(cio, struct {
                            fn run(inst: *LVM.Instance, ct: *anyopaque) void {
                                const cl: *Closure = @ptrCast(@alignCast(ct));
                                defer cl.alloc.destroy(cl);

                                inst.coro.state.push(cl.pos);
                                cl.callback(inst, cl.context);
                            }
                        }.run, @ptrCast(closure)) catch |e| @panic(@errorName(e));
                    }
                }.seekFile, .{ t.*, io, allocator, callback, ctx, arg }) catch @panic("TODO");
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
