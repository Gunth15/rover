state: *c.lua_State,

const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("luaconf.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const LuaState = @This();

// ─── Lifecycle ────────────────────────────────────────────────────────────────

pub fn init(alloc: *std.mem.Allocator) error{OutOfMemory}!LuaState {
    return .{
        .state = c.lua_newstate(alloctorFn, alloc) orelse return error.OutOfMemory,
    };
}

pub fn deinit(l: *LuaState) void {
    c.lua_close(l.state);
}

// ─── Execution ────────────────────────────────────────────────────────────────

const PcallError = error{
    RuntimeError,
    AllocationError,
    HandlerError,
};

/// Call a function on the stack with nargs arguments; leaves nresults on stack.
/// errh is the stack index of a message-handler (0 = none).
pub fn pcall(l: *LuaState, nargs: c_int, nresults: c_int, errh: c_int) PcallError!void {
    const ret = c.lua_pcallk(l.state, nargs, nresults, errh, 0, null);
    if (ret != c.LUA_OK) {
        return switch (ret) {
            c.LUA_ERRRUN => PcallError.RuntimeError,
            c.LUA_ERRMEM => PcallError.AllocationError,
            c.LUA_ERRERR => PcallError.HandlerError,
            else => PcallError.RuntimeError,
        };
    }
}

/// Resume a coroutine thread; from is the calling thread (null if main).
pub fn resumeThread(l: *LuaState, from: ?*LuaState, nargs: c_int, nresults: *c_int) error{RuntimeError}!void {
    const from_state: ?*c.lua_State = if (from) |f| f.state else null;
    const ret = c.lua_resume(l.state, from_state, nargs, nresults);
    if (ret != c.LUA_OK and ret != c.LUA_YIELD) return error.RuntimeError;
}

/// Raise the value on top of the stack as a Lua error.
pub fn raiseError(l: *LuaState) noreturn {
    _ = c.lua_error(l.state);
    unreachable;
}

/// Push a formatted error string, then raise it.
pub fn newError(l: *LuaState, comptime fmt: [:0]const u8, args: anytype) noreturn {
    _ = c.luaL_error(l.state, fmt, args);
    unreachable;
}

// ─── Stack control ────────────────────────────────────────────────────────────

/// Remove n values from the top of the stack.
pub fn pop(l: *LuaState, n: c_int) void {
    c.lua_pop(l.state, n);
}

/// Ensure at least extra free slots on the stack; returns false if it cannot grow.
pub fn checkStack(l: *LuaState, extra: c_int) bool {
    return c.lua_checkstack(l.state, extra) != 0;
}

/// Returns the number of values currently on the stack (also the index of the top).
pub fn getTop(l: *LuaState) c_int {
    return c.lua_gettop(l.state);
}

// ─── Thread / coroutine ───────────────────────────────────────────────────────

pub fn newThread(l: *LuaState) error{OutOfMemory}!LuaState {
    return .{ .state = c.lua_newthread(l.state) orelse return error.OutOfMemory };
}

// ─── Table helpers ────────────────────────────────────────────────────────────

/// Push an empty table onto the stack.
pub fn newTable(l: *LuaState) void {
    c.lua_newtable(l.state);
}

/// Push an empty table pre-sized for narr array slots and nrec hash slots.
pub fn createTable(l: *LuaState, narr: c_int, nrec: c_int) void {
    c.lua_createtable(l.state, narr, nrec);
}

/// t[k] = v  where t is at index, k is a string, v is on top; pops v.
pub fn setField(l: *LuaState, index: c_int, k: [:0]const u8) void {
    c.lua_setfield(l.state, index, k.ptr);
}

/// Pushes t[k] onto the stack where t is at index and k is a string.
pub fn getField(l: *LuaState, index: c_int, k: [:0]const u8) c_int {
    return c.lua_getfield(l.state, index, k.ptr);
}

/// t[k] = v  (raw, no metamethods).  k and v are on the stack; both popped.
pub fn setTable(l: *LuaState, index: c_int) void {
    c.lua_settable(l.state, index);
}

/// Registers an array of luaL_Reg functions into the table on top of the stack.
pub fn getFuncs(l: *LuaState, regs: []const c.luaL_Reg, nup: c_int) void {
    // luaL_setfuncs expects a sentinel { null, null } at the end.
    c.luaL_setfuncs(l.state, regs.ptr, nup);
}

/// Push t[i] (integer key, no metamethods).
pub fn getRawI(l: *LuaState, index: c_int, i: c.lua_Integer) c_int {
    return c.lua_rawgeti(l.state, index, i);
}

/// t[i] = v  (integer key, no metamethods); pops v.
pub fn setRawI(l: *LuaState, index: c_int, i: c.lua_Integer) void {
    c.lua_rawseti(l.state, index, i);
}

/// Push t[i] (integer key, with metamethods).
pub fn getI(l: *LuaState, index: c_int, i: c.lua_Integer) c_int {
    return c.lua_geti(l.state, index, i);
}

/// t[i] = v  (integer key, with metamethods); pops v.
pub fn setI(l: *LuaState, index: c_int, i: c.lua_Integer) void {
    c.lua_seti(l.state, index, i);
}

// ─── Metatables ───────────────────────────────────────────────────────────────

/// Push (or create) the metatable named tname in the registry.
/// Returns true if a new metatable was created.
pub fn newMetaTable(l: *LuaState, tname: [:0]const u8) bool {
    return c.luaL_newmetatable(l.state, tname.ptr) != 0;
}

/// Push the metatable of the value at index (returns false if none).
pub fn getMetaTable(l: *LuaState, index: c_int) bool {
    return c.lua_getmetatable(l.state, index) != 0;
}

/// Pop a table and set it as the metatable of the value at index.
pub fn setMetaTable(l: *LuaState, index: c_int) void {
    _ = c.lua_setmetatable(l.state, index);
}

// ─── Globals ──────────────────────────────────────────────────────────────────

/// Push the global named name onto the stack.
pub fn getGlobal(l: *LuaState, name: [:0]const u8) c_int {
    return c.lua_getglobal(l.state, name.ptr);
}

/// Pop a value and assign it to the global named name.
pub fn setGlobal(l: *LuaState, name: [:0]const u8) void {
    c.lua_setglobal(l.state, name.ptr);
}

// ─── Userdata ─────────────────────────────────────────────────────────────────

/// Allocate a new full userdata of size @sizeOf(T) with 1 uservalue.
/// Returns a pointer to the allocated memory cast to *T.
pub fn newUserData(l: *LuaState, comptime T: type) error{OutOfMemory}!*T {
    const ptr = c.lua_newuserdatauv(l.state, @sizeOf(T), 1) orelse return error.OutOfMemory;
    return @as(*T, @ptrCast(@alignCast(ptr)));
}

/// Check that the value at index is a userdata with metatable tname; return pointer.
pub fn checkUdata(l: *LuaState, comptime T: type, index: c_int, tname: [:0]const u8) *T {
    const ptr = c.luaL_checkudata(l.state, index, tname.ptr);
    return @as(*T, @ptrCast(@alignCast(ptr)));
}

/// Return a pointer to the raw userdata block at index (no metatable check).
pub fn toUserData(l: *LuaState, comptime T: type, index: c_int) ?*T {
    const ptr = c.lua_touserdata(l.state, index) orelse return null;
    return @as(*T, @ptrCast(@alignCast(ptr)));
}

// ─── Lib registration ────────────────────────────────────────────────────────

/// Register a module: create a new table, populate it with funcs, leave on stack.
pub fn newLib(l: *LuaState, regs: []const c.luaL_Reg) void {
    // luaL_newlib macro: createtable then setfuncs with 0 upvalues.
    c.lua_createtable(l.state, 0, @intCast(regs.len));
    c.luaL_setfuncs(l.state, regs.ptr, 0);
}

// ─── String buffer ────────────────────────────────────────────────────────────

/// Initialise a luaL_Buffer tied to this state.  The buffer itself must be
/// kept alive on the Zig side until bufFinish is called.
pub fn initBuf(l: *LuaState, buf: *c.luaL_Buffer) void {
    c.luaL_buffinit(l.state, buf);
}

/// Finish the buffer and push the resulting string onto the stack.
pub fn bufFinish(_: *LuaState, buf: *c.luaL_Buffer) void {
    c.luaL_pushresult(buf);
}

// ─── Argument checking (luaL_check*) ─────────────────────────────────────────

/// Error if argument arg is not present.
pub fn checkAny(l: *LuaState, arg: c_int) void {
    c.luaL_checkany(l.state, arg);
}

/// Return the number at argument arg, raising a Lua error on failure.
pub fn checkNumber(l: *LuaState, arg: c_int) c.lua_Number {
    return c.luaL_checknumber(l.state, arg);
}

/// Return the integer at argument arg, raising a Lua error on failure.
pub fn checkInteger(l: *LuaState, arg: c_int) c.lua_Integer {
    return c.luaL_checkinteger(l.state, arg);
}

/// Return the string at argument arg, raising a Lua error on failure.
pub fn checkString(l: *LuaState, arg: c_int) [:0]const u8 {
    var len: usize = 0;
    const ptr = c.luaL_checklstring(l.state, arg, &len);
    return ptr[0..len :0];
}

/// Generic argument error with a descriptive message.
pub fn argCheck(l: *LuaState, cond: bool, arg: c_int, msg: [:0]const u8) void {
    if (!cond) _ = c.luaL_argerror(l.state, arg, msg.ptr);
}

// ─── Push values ─────────────────────────────────────────────────────────────

pub fn pushFunction(l: *LuaState, f: c.lua_CFunction) void {
    c.lua_pushcfunction(l.state, f);
}

pub fn pushNumber(l: *LuaState, n: c.lua_Number) void {
    c.lua_pushnumber(l.state, n);
}

pub fn pushInt(l: *LuaState, n: c.lua_Integer) void {
    c.lua_pushinteger(l.state, n);
}

pub fn pushNil(l: *LuaState) void {
    c.lua_pushnil(l.state);
}

pub fn pushBool(l: *LuaState, b: bool) void {
    c.lua_pushboolean(l.state, @intFromBool(b));
}

/// Push a copy of the string slice (Lua makes its own copy).
pub fn pushString(l: *LuaState, s: []const u8) void {
    _ = c.lua_pushlstring(l.state, s.ptr, s.len);
}

/// Push a light userdata (unmanaged pointer; no metatable, no GC).
pub fn pushLightUserData(l: *LuaState, ptr: *anyopaque) void {
    c.lua_pushlightuserdata(l.state, ptr);
}

/// Push a formatted string (printf-style); returns the interned Lua string.
pub fn pushFString(l: *LuaState, comptime fmt: [:0]const u8, args: anytype) void {
    _ = @call(.auto, c.lua_pushfstring, .{ l.state, fmt.ptr } ++ args);
}

// ─── Read / convert values ───────────────────────────────────────────────────

/// Convert value at index to a Lua number (0 on failure).
pub fn toNumber(l: *LuaState, index: c_int) c.lua_Number {
    return c.lua_tonumber(l.state, index);
}

/// Convert value at index to a Lua integer (0 on failure).
pub fn toInteger(l: *LuaState, index: c_int) c.lua_Integer {
    return c.lua_tointeger(l.state, index);
}

/// Convert value at index to a boolean (any non-nil/false value is true).
pub fn toBool(l: *LuaState, index: c_int) bool {
    return c.lua_toboolean(l.state, index) != 0;
}

/// Convert value at index to a string slice (only valid while value stays on stack).
pub fn toString(l: *LuaState, index: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(l.state, index, &len) orelse return null;
    return ptr[0..len];
}

// ─── Allocator callback ──────────────────────────────────────────────────────

fn alloctorFn(ap: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, new_size: usize) ?*anyopaque {
    const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ap orelse unreachable));

    // free
    if (new_size == 0) {
        if (ptr) |p| {
            const slice = @as([*]u8, @ptrCast(p))[0..old_size];
            alloc.free(slice);
        }
        return null;
    }

    // alloc
    if (ptr == null) {
        const slice = alloc.alloc(u8, new_size) catch return null;
        return @ptrCast(slice.ptr);
    }

    // realloc
    const old_slice = @as([*]u8, @ptrCast(ptr.?))[0..old_size];
    const new_slice = alloc.realloc(old_slice, new_size) catch return null;
    return @ptrCast(new_slice.ptr);
}
