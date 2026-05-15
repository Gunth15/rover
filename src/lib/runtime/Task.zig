pc: u32 = 0,
context: *anyopaque,
resume_context: fn (*anyopaque, pc: u32) State,
const Self = @This();

pub const State = enum(u4) { YIELD, OK };
pub fn resumeCtxt(f: *Self) State {
    const state = f.resume_context(f.context, f.pc);
    f.pc += 1;
    return state;
}
