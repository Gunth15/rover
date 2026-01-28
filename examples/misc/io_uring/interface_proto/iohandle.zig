pub const VTable = struct {
    on_write: *const fn(*anyopaque, []const u8) !void
    on_read:  *const fn(*anyopaque, []const u8) !void
    on_close: *const fn(*anyopaque) !void
};
pub const 
const IoHandle = union(enum){
    read:
    write

}

const FileHandle = struct {
    ptr: *anyopaque,
    read_buf: ?[]const u8,
    write_buf: ?[]const u8,
    vtable: VTable,
    pub const VTable = struct {
        on_open: *const fn(*anyopaque) !void
        on_write: *const fn(*anyopaque, []const u8) !void
        on_read:  *const fn(*anyopaque, []const u8) !void
        on_close: *const fn(*anyopaque) !void
    };
    pub inline fn on_write(e: IOHandle, buf: []const u8) { 
        return e.vtable.on_write(e.ptr,buf);
    }
    pub inline fn on_read(e: IOHandle, buf: []const u8) {
        return e.vtable.on_read(e.ptr,buf);
    }
    pub inline fn on_close(e: IOHandle) {
        return e.vtable.on_close(e.ptr);
    }
}
const ListenerHandle = struct {
    ptr: *anyopaque,
    buf: []const u8,
    vtable: VTable,
    pub const VTable = struct {
        on_write: *const fn(*anyopaque, []const u8) !void
        on_read:  *const fn(*anyopaque, []const u8) !void
        on_close: *const fn(*anyopaque) !void
    };
    pub inline fn on_write(e: IOHandle, buf: []const u8) { 
        return e.vtable.on_write(e.ptr,buf);
    }
    pub inline fn on_read(e: IOHandle, buf: []const u8) {
        return e.vtable.on_read(e.ptr,buf);
    }
    pub inline fn on_close(e: IOHandle) {
        return e.vtable.on_close(e.ptr);
    }
}
const ConnectionHandle = struct {
    ptr: *anyopaque,
    buf: []const u8,
    pub const VTable = struct {
        on_write: *const fn(*anyopaque, []const u8) !void
        on_read:  *const fn(*anyopaque, []const u8) !void
        on_close: *const fn(*anyopaque) !void
    };
}
