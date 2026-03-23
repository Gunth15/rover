pub const Context = packed struct {
    //where you last left off
    rsp: *anyopaque,
    //genral purpose register
    rbx: *anyopaque,
    //frame pointer(not too important, but used by compilers)
    rbp: *anyopaque,
    //use for inflight opertions like push, op, etc
    r12: *anyopaque,
    r13: *anyopaque,
    r14: *anyopaque,
    r15: *anyopaque,
};
extern fn switch_context(old: *Context, new: *Context) void;

test "can the context be switched?" {
    const test = struct {
        fn continue() u64 {
        }
        fn start_counter() u64 {

        }

    };
    var c1: Context = undefined;
    var c2: Context = undefined;

}
