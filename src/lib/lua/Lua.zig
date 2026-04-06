//NOTE: the REGISTRY is a place in lua that only C/non-lua can access
state: *c.lua_State,

const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("luaconf.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const LuaState = @This();
pub const Number = f64;
pub const Integer = isize;
pub const Float = f64;
pub const Bool = bool;
pub const String = []const u8;
pub const Function = c.lua_CFunction;
pub const Any = union(LuaType) {
    string: []const u8,
    bool: bool,
    //manually manipulate the table on the stack
    table: void,
    number: f64,
    //both are opaque pointers
    lightud: *anyopaque,
    ud: *anyopaque,
    func: Function,
    nil: void,
    nan: void,
    thread: void,
};
const LuaType = enum(c_int) {
    string = c.LUA_TSTRING,
    bool = c.LUA_TBOOLEAN,
    table = c.LUA_TTABLE,
    number = c.LUA_TNUMBER,
    lightud = c.LUA_TLIGHTUSERDATA,
    ud = c.LUA_TUSERDATA,
    func = c.LUA_TFUNCTION,
    nil = c.LUA_TNIL,
    nan = c.LUA_TNONE,
    thread = c.LUA_TTHREAD,
};

//have to use pointer
pub const Options = struct {
    allocator: ?*const std.mem.Allocator,
};
pub fn init(comptime op: Options) error{OutOfMemory}!LuaState {
    const alloc, const fun = if (op.allocator) |a| .{ a, alloctorFn } else .{ null, null };
    return .{
        .state = c.lua_newstate(fun, @constCast(alloc)) orelse return error.OutOfMemory,
    };
}
pub fn deinit(l: *LuaState) void {
    return c.lua_close(l.state);
}
const LoadError = error{ NoMemory, SyntaxError };
//LoadString loads, but does not execute the given string
pub fn loadString(l: *LuaState, str: [:0]const u8) LoadError!void {
    switch (c.luaL_loadstring(l.state, str)) {
        c.LUA_OK => return,
        c.LUA_ERRMEM => return error.NoMemory,
        c.LUA_ERRSYNTAX => return error.SyntaxError,
        else => unreachable,
    }
}
//DoString loads, and executes given string
pub fn doString(l: *LuaState, str: [:0]const u8) !void {
    try l.loadString(str);
    _ = try l.pcall(0, c.LUA_MULTRET);
}
pub fn loadFile(l: *LuaState, file_name: [:0]const u8) LoadError!void {
    switch (c.luaL_loadfile(l.state, file_name)) {
        c.LUA_OK => return,
        c.LUA_ERRMEM => return error.NoMemory,
        c.LUA_ERRSYNTAX => return error.SyntaxError,
        else => unreachable,
    }
}
//add traceback as msgh
const CallError = error{ RuntimeError, AllocationError, HandlerError,
    //Not realy an error, but somet;hing that can happen
    Yielded } || TypeError;
//If this function is yielded or an error occurs, you have to use L.yieldresult or l.errorresult() to form the error
pub fn call(l: *LuaState, func: [:0]const u8, args: anytype, ResultType: type) CallError!ResultType {
    //get Function
    const g_type = l.getGlobal(func);
    std.debug.assert(g_type == .func);

    //push args
    const ArgsType = @typeInfo(@TypeOf(args));
    comptime if (ArgsType != .@"struct") @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    const arg_struct = ArgsType.@"struct";
    const nargs: comptime_int = arg_struct.fields.len;
    inline for (arg_struct.fields) |field| l.push(@field(args, field.name));

    //pop result
    //const ResultInfo = @typeInfo(ResultType);
    //comptime if (ResultInfo != .@"struct") @compileError("expected tuple or struct argument, found " ++ @typeName(ResultType));
    //const res_struct = ResultInfo.@"struct";
    const nres: comptime_int = 1; //res_struct.field.len;

    //call function
    const result = c.lua_pcallk(l.state, nargs, nres, 0, 0, null);
    switch (result) {
        c.LUA_OK => return l.to(ResultType, -1),
        c.LUA_YIELD => return CallError.Yielded,
        c.LUA_ERRRUN => return CallError.RuntimeError,
        c.LUA_ERRMEM => return CallError.AllocationError,
        c.LUA_ERRERR => return CallError.HandlerError,
        else => unreachable,
    }
    l.pop(nres);
}

///Pushes given value to lua
///structs are passed using their luaPush method if one exist, oterwise they are mapped to a luatable
///pointers are passed as light userdata in lua
pub inline fn push(l: *LuaState, arg: anytype) void {
    const ArgType = @TypeOf(arg);
    switch (@typeInfo(ArgType)) {
        .@"struct" => if (std.meta.hasMethod(ArgType, "luaPush")) arg.luaPush(l.state) else structToTable(arg),
        .int, .comptime_int => c.lua_pushinteger(l.state, arg),
        .float, .comptime_float => c.lua_pushnumber(l.state, arg),
        .bool => c.lua_pushboolean(l.state, if (arg) 1 else 0),
        .null => c.lua_pushnil(l.state),
        .optional => if (arg) |val| l.push(val) else c.lua_pushnil(l.state),
        //if not a string, pointers are pushed as lightuserdata(very unsafe lol)
        .pointer => |info| if (info.size == .slice and info.child == u8 and info.is_const) c.lua_pushlstring(l.state, arg.ptr, arg.len) else c.lua_pushlightuserdata(l.state, arg),
        .@"fn" => {
            //mask closure that handles arguments and expected return value

        },
        else => @compileError(@typeName(ArgType) ++ " cannot be converted to lua type"),
    }
}
///Pops given value to lua
///structs are interpretted using their luaTo method, if it one does not exit, it is treated as a table.
///pointers are returned
///strings should be treated as refereces that will be garbage collected at some point
///the only function that can be returned is a generic LuaFunction
pub const TypeError = error{
    ExpectedInt,
    ExpectedUnsigned,
    ExpectedFloat,
    ExepectedNumber,
    ExpectedBool,
    ExpectedNull,
    ExpectedPointer,
};
pub fn to(l: *LuaState, T: type, index: isize) TypeError!T {
    switch (@typeInfo(T)) {
        .@"struct" => if (std.meta.hasMethod(T, "luaTo")) T.luaTo(l.state) else return try l.structFromTable(T),
        .int,
        => |info| {
            comptime std.debug.assert(info.signedness == .signed);
            var isnum: c_int = 0;
            const int = @as(Integer, c.lua_tointegerx(l.state, @intCast(index), &isnum));
            return if (isnum > 0) @intCast(int) else error.ExpectedInt;
        },
        .comptime_int => {
            var isnum: c_int = 0;
            const int = @as(Integer, c.lua_tointegerx(l.state, @intCast(index), &isnum));
            return if (isnum > 0) @intCast(int) else error.ExpectedInt;
        },
        .float, .comptime_float => {
            var isnum: c_int = 0;
            const f = @as(Float, c.lua_tonumberx(l.state, @intCast(index), &isnum));
            return if (isnum == 1) @as(f64, f) else error.ExpectedFloat;
        },
        .bool => {
            const n: c_int = @intCast(index);
            if (c.lua_isboolean(l.state, n)) return if (c.lua_toboolean(l.state, n) > 0) true else false else return error.ExpectedBool;
        },
        .null => {
            const n: c_int = @intCast(index);
            return if (c.lua_isnoneornil(l.state, n)) null else error.ExpectedNull;
        },
        .optional => |info| {
            const n: c_int = @intCast(index);
            return if (c.lua_isnoneornil(l.state, n)) null else l.to(info.child, index);
        },
        .pointer => |info| {
            //if not a string, pointers are pushed as lightuserdata(very unsafe lol)
            if (info.size == .slice and info.child == u8) {
                var len: usize = 0;
                const ptr = c.lua_tolstring(l.state, @intCast(index), &len);
                return ptr[0..len];
            } else return @ptrCast(c.lua_touserdata(l.state, @intCast(index)) orelse return error.ExpectedPointer);
        },
        .@"fn" => |info| {
            if (info.params.len != 1 and info.params[0].type != *c.lua_State) @compileError("Only type" ++ @typeName(Function) ++ "is allowed to be returned as a function from lua");
            return c.lua_tocfunction(l.state, index);
        },
        else => @compileError(@typeName(T) ++ "cannot be converted from lua type"),
    }
}
///protected call to lua, only use this instead of call if you require more manual control
///Ex. wanting to pop values your way
///Ex. wanting to run functions passed to a function
///
pub fn pcall(l: *LuaState, nargs: isize, nres: isize) CallError!usize {
    return @intCast(c.lua_pcallk(l.state, @intCast(nargs), @intCast(nres), 0, 0, null));
}

pub fn register(l: *LuaState, name: [:0]const u8, comptime func: anytype) void {
    return c.lua_register(l.state, name, toLuaFuntcion(func));
}

pub fn openLibs(l: *LuaState) void {
    return c.luaL_openlibs(l.state);
}

//pops n values form the stack
pub fn pop(l: *LuaState, n: i64) void {
    const int: c_int = @intCast(n);
    return c.lua_pop(l.state, int);
}
//uses value at top of stck as err object
pub fn raiseError(l: *LuaState) noreturn {
    _ = c.lua_error(l);
    unreachable;
}
pub fn newTable(l: *LuaState) void {
    return c.lua_newtable(l.state);
}
pub fn newUserData(l: *LuaState, T: type) error{OutOfMemory}!T {
    return @as(T, c.lua_newuserdatauv(l.state, @sizeOf(T), 1)) orelse error.OutOfMemory;
}
pub fn newUserDataRaw(l: *LuaState, size: usize) error{OutOfMemory}![]u8 {
    return @as([]u8, c.lua_newuserdatauv(l.state, @intCast(size), 1)) orelse error.OutOfMemory;
}
pub fn newThread(l: *LuaState) error{OutOfMemory}!LuaState {
    return .{ .state = c.lua_newthread(l.state) orelse return error.OutOfMemory };
}

const LuaLib = struct { [:0]const u8, *const anyopaque };

///creates new library
pub fn newLib(l: *LuaState, comptime lib: []LuaLib) void {
    const regs: [lib.len + 1]c.luaL_Reg = undefined;
    comptime {
        for (lib, 0..) |lib_func, i| {
            const name, const func = lib_func;

            regs[i] = .{
                .name = name.ptr,
                .func = toLuaFuntcion(func),
            };
        }
        regs[lib.len] = .{ null, null };
    }
    return c.luaL_newlib(l.state, regs);
}
///Creates a object
pub fn newObj(l: *LuaState, comptime tname: [:0]const u8, comptime methods: []LuaLib) void {
    const meths: [methods.len + 1]c.luaL_Reg = undefined;
    comptime {
        for (methods, 0..) |lib_func, i| {
            const name, const func = lib_func;

            meths[i] = .{
                .name = name.ptr,
                .func = toLuaFuntcion(func),
            };
        }
        meths[meths.len] = .{ null, null };
    }
    //meta = newmetable()
    l.newMetaTable(tname);
    //for each function meta.key = method
    c.luaL_setfuncs(l.state, methods, 0);
}
pub fn newMetaTable(l: *LuaState, tname: [*:0]const u8) void {
    _ = c.luaL_newmetatable(l.state, tname.ptr);
}

pub const LuaBuffer = c.luaL_Buffer;
pub fn initBuf(l: *LuaState, buf: *LuaBuffer) void {
    c.luaL_buffinit(l.state, buf);
}
pub fn initBufCapcity(l: *LuaState, buf: *LuaBuffer, len: usize) void {
    _ = c.luaL_buffinitsize(l.state, buf, len);
}

//sequenced is how many elements expected to be contiguous, expeted is th eexpected size of the table
pub fn createTable(l: *LuaState, sequenced: isize, expected: isize) void {
    c.lua_createtable(l.state, sequenced, expected);
}
pub fn argCheck(l: *LuaState, cond: bool, arg: usize, msg: [*:0]const u8) void {
    _ = c.luaL_argcheck(l.state, cond, arg, msg.ptr);
}
pub fn Luatype(l: *LuaState, index: usize) LuaType {
    return @enumFromInt(c.lua_type(l.state, @as(c_int, index)));
}
pub fn checkAny(l: *LuaState, arg: usize) void {
    c.luaL_checkany(l.state, arg);
}
pub fn err(l: *LuaState) noreturn {
    _ = c.lua_error(l.state);
    unreachable;
}
pub fn fmtError(l: *LuaState, fmt: [:0]const u8, args: anytype) noreturn {
    _ = @call(.auto, c.luaL_error, .{ l.state, fmt } ++ args);
    unreachable;
}
pub fn argError(l: *LuaState, arg: usize, msg: [*:0]const u8) noreturn {
    _ = c.luaL_argerror(l.state, @intCast(arg), msg);
    unreachable;
}
pub fn resumeT(l: *LuaState, from: ?*LuaState, nargs: usize, nresults: *usize) CallError!enum { OK, YIELDED } {
    const from_state: ?*c.lua_State = if (from) |f| f.state else null;
    const ret = c.lua_resume(l.state, from_state, nargs, nresults);
    return switch (ret) {
        c.LUA_OK => .OK,
        c.LUA_YIELD => .YIELDED,
        c.LUA_ERRERR => CallError.HandlerError,
        c.LUA_ERRMEM => CallError.AllocationError,
        c.LUA_ERRRUN => CallError.RuntimeError,
        else => unreachable,
    };
}
///equivalent to t[k] = v if k and v are on top of the stack and t is the index of the table
pub fn setTable(l: *LuaState, index: isize) void {
    return c.lua_settable(l.state, @as(c_int, index));
}
pub fn getMetaTable(l: *LuaState, index: usize) error{NotPushed}!void {
    return if (c.lua_getmetatable(l, index) != 0) {} else return error.NotPushed;
}
///t[n] where to is the table of the given index, the value pushed on top of the stack
pub fn getI(l: *LuaState, index: isize, n: isize) LuaType {
    return @enumFromInt(c.lua_geti(l.state, @as(c_int, index), @as(c.lua_Integer, n)));
}
///t[i]=v where v is on top of the stack
pub fn setI(l: *LuaState, index: isize, i: isize) void {
    c.lua_seti(l.state, @as(c_int, index), @as(c_longlong, i));
}
//use these for tables without metadata
pub fn getRawI(l: *LuaState, index: isize, n: isize) LuaType {
    return @enumFromInt(c.lua_rawgeti(l.state, @as(c_int, index), @as(c.lua_Integer, n)));
}
pub fn setRawI(l: *LuaState, index: isize, i: isize) void {
    c.lua_rawseti(l.state, @as(c_int, index), @as(c_longlong, i));
}
pub fn getField(l: *LuaState, index: isize, name: [:0]const u8) LuaType {
    return @enumFromInt(c.lua_getfield(l.state, @as(c_int, index), name));
}
pub fn getTop(l: *LuaState) isize {
    return @intCast(c.lua_gettop(l.state));
}
pub fn getGlobal(l: *LuaState, name: [:0]const u8) LuaType {
    return @enumFromInt(c.lua_getglobal(l.state, name));
}
pub fn setGlobal(l: *LuaState, name: [:0]const u8) void {
    c.lua_setglobal(l.state, name);
}

pub fn toUserData(l: *LuaState, T: type, index: isize) *T {
    return @ptrCast(c.lua_touserdata(l.state, @as(c_int, index)));
}
pub fn checkStack(l: *LuaState, extra: usize) bool {
    return c.lua_checkstack(l.state, extra) != 0;
}
pub fn ref(l: *LuaState) c_int {
    return c.luaL_ref(l.state, c.LUA_REGISTRYINDEX);
}
pub fn unref(l: *LuaState, reference: c_int) void {
    return c.luaL_unref(l.state, c.LUA_REGISTRYINDEX, reference);
}
///Assumes table is on top of the stack
fn structFromTable(l: *LuaState, T: type) TypeError!T {
    const TypeInfo = @typeInfo(T);
    comptime std.debug.assert(TypeInfo == .@"struct");
    const StructInfo = TypeInfo.@"struct";

    var ret: T = undefined;
    inline for (StructInfo.fields) |field| {
        const key = field.name;
        //table[key]
        _ = l.getField(-1, key);
        @field(ret, key) = try l.to(field.type, -1);
        l.pop(1);
    }
    return ret;
}
///Puts new table on top of the lua stack from given struct
fn structToTable(l: *LuaState, table: anytype) void {
    const TypeInfo = @typeInfo(@TypeOf(table));
    comptime std.debug.assert(TypeInfo == .@"struct");
    const StructInfo = TypeInfo.@"struct";

    l.createTable(0, StructInfo.fields.len);
    inline for (StructInfo.fields) |field| {
        const key = field.name;
        const value = @field(table, key);
        //table[key] = value
        l.push(key);
        l.push(value);
        l.setTable(-3);
    }
}
//TODO: support anytype using a union
fn toLuaFuntcion(comptime func: anytype) Function {
    const FuncType = @TypeOf(func);
    const FuncInfo = @typeInfo(FuncType);
    comptime if (FuncInfo != .@"fn") @compileError(@typeName(FuncType) ++ "is not a function");
    comptime if (FuncInfo.@"fn".params[0].type != *LuaState) @compileError("Functions are required to have " ++ @typeName(LuaState) ++ " as first argument to be passed to lua " ++ @typeName(FuncType) ++ " does not");
    const closure = struct {
        fn close(l: ?*c.lua_State) callconv(.c) c_int {
            const ArgTuple = std.meta.ArgsTuple(FuncType);
            var state: LuaState = .{ .state = l orelse return 0 };

            //get args from stack
            var args: ArgTuple = undefined;
            const fields = @typeInfo(ArgTuple).@"struct".fields;
            const given = state.getTop();
            if (given != fields.len - 1) return state.fmtError("Expected %d arguments, but received %d", .{ fields.len, given });
            inline for (fields[1..], 1..) |field, i| {
                @field(args, field.name) = state.to(field.type, i) catch return state.argError(@intCast(i), "expected" ++ @typeName(field.type));
            }
            //call function
            args.@"0" = &state;
            const ret = @call(.auto, func, args);
            //serialize return value, always returns one value
            //NOTE: A possible improvment to the api would could allow more than one return value
            state.push(ret);
            return 1;
        }
    };
    return closure.close;
}
fn alloctorFn(ap: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque {
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

test "can call basic lua function" {
    var lua = try init(.{ .allocator = &std.testing.allocator });
    defer lua.deinit();

    try lua.doString("function test(a,b) return a+b end");

    const int = try lua.call("test", .{ 1, 2 }, Integer);
    try std.testing.expectEqual(3, int);
}

test "Basic types" {
    var lua: LuaState = try .init(.{ .allocator = &std.testing.allocator });
    defer lua.deinit();

    try lua.doString(
        \\function add(a, b) return a + b end
        \\function echo_int(x) return x end
        \\function echo_float(x) return x end
        \\function echo_bool(x) return x end
    );

    try std.testing.expectEqual(@as(i32, 3), try lua.call("add", .{ 1, 2 }, i32));

    try std.testing.expectEqual(@as(i32, 42), try lua.call("echo_int", .{42}, i32));

    try std.testing.expectEqual(@as(f64, 3.14), try lua.call("echo_float", .{3.14}, f64));

    try std.testing.expectEqual(true, try lua.call("echo_bool", .{true}, bool));
}

test "register a lua function and call it" {
    const AddCB = struct {
        fn add(_: *LuaState, a: Integer, b: Integer) Integer {
            return a + b;
        }
    };
    var lua = try init(.{ .allocator = &std.testing.allocator });
    defer lua.deinit();

    lua.register("test", AddCB.add);

    const int = lua.call("test", .{ 1, 2 }, Integer) catch |e| {
        const lua_err = try lua.to(String, -1);
        lua.pop(-1);

        std.debug.print("{s}\n", .{lua_err});
        return e;
    };
    try std.testing.expectEqual(3, int);
}
