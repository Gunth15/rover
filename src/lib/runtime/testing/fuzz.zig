const std = @import("std");
const GlobalMap = std.StringHashMap(bool);
const LocalMap = std.StringHashMap(u32);
//References:
//https://github.com/golang/go/blob/master/src/internal/fuzz/mutator.go
//https://lcamtuf.coredump.cx/afl/technical_details.txt

//Form what I understand
//branches can be described as A->B or B->C where a is the letters are edges
//
//Each run gets it's own bitmap ans it is compared the the global bitmat wich tells use if a path has been seen or not
//In Lua, each instruction can be encoded as file+function_name+line
//The bitmap id is (curr ^ prev ) & MAPSIZE
