const std = @import("std");
const parser_log = @import("std").log.scoped(.parser);

pub const Command = enum {
    run,
    routes,
    tests,
    config,
    help,
};

pub const RunArgs = struct {
    main_file: ?[:0]const u8 = null,
    config_path: ?[:0]const u8 = null,
    memory: ?usize = null,
    max_read: ?usize = null,
    address: ?std.Io.net.IpAddress = null,
    single_threaded: ?bool = null,
    lua_threads: ?usize = null,
};

pub const RoutesArgs = struct {
    main_file: ?[:0]const u8 = null,
    config_path: ?[:0]const u8 = null,
};

pub const TestsArgs = struct {
    test_dir: ?[:0]const u8 = null,
};

pub const ConfigArgs = struct {
    config_path: ?[:0]const u8 = null,
};

pub const HelpArgs = struct {
    topic: ?Command = null,
};

pub const Args = union(Command) {
    run: RunArgs,
    routes: RoutesArgs,
    tests: TestsArgs,
    config: ConfigArgs,
    help: HelpArgs,
};

pub const Outcome = union(enum) {
    /// Run this command.
    command: Args,
    /// Print help for this command, or general help when null.
    help: ?Command,
    /// A diagnostic was already logged; the caller should exit non-zero.
    invalid,
};

const Opt = struct {
    short: ?u8 = null,
    long: []const u8,
    field: []const u8 = "",
    metavar: ?[]const u8 = null,
    help: []const u8,
};

const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    options: []const Opt,
};

const file_opt: Opt = .{ .short = 'f', .long = "file", .field = "main_file", .metavar = "path", .help = "Lua script to execute" };
const config_opt: Opt = .{ .short = 'c', .long = "config", .field = "config_path", .metavar = "path", .help = "Specify config file" };

const run_options = [_]Opt{
    file_opt,
    config_opt,
    .{ .short = 'm', .long = "memory", .field = "memory", .metavar = "bytes", .help = "Limit memory allocations for the entire process" },
    .{ .short = 'r', .long = "read", .field = "max_read", .metavar = "bytes", .help = "Max read buffer per connection" },
    .{ .short = 'a', .long = "addr", .field = "address", .metavar = "addr:port", .help = "Address to bind (e.g. 127.0.0.1:8080)" },
    .{ .short = 's', .long = "single_threaded", .field = "single_threaded", .help = "Run the server in single-threaded mode" },
    .{ .short = 'l', .long = "lua_threads", .field = "lua_threads", .metavar = "count", .help = "Number of threads dedicated to Lua workers" },
};

const routes_options = [_]Opt{ file_opt, config_opt };

const tests_options = [_]Opt{
    .{ .short = 'd', .long = "dir", .field = "test_dir", .metavar = "dir", .help = "Directory to look for tests" },
};

const config_options = [_]Opt{config_opt};

const help_spec = CommandSpec{
    .name = "help",
    .summary = "Show help for a command",
    .options = &.{},
};

const run_spec = CommandSpec{
    .name = "run",
    .summary = "Runs a Rover program (defaults to main.lua)",
    .options = &run_options,
};

const routes_spec = CommandSpec{
    .name = "routes",
    .summary = "Displays all routes",
    .options = &routes_options,
};

const tests_spec = CommandSpec{
    .name = "tests",
    .summary = "Runs tests from the test directory",
    .options = &tests_options,
};

const config_spec = CommandSpec{
    .name = "config",
    .summary = "Prints the current configuration",
    .options = &config_options,
};

const commands = [_]CommandSpec{ run_spec, routes_spec, tests_spec, config_spec, help_spec };

pub fn parse(cargs: std.process.Args) Outcome {
    var iter = cargs.iterate();
    return parseWith(&iter);
}

fn parseWith(it: anytype) Outcome {
    _ = it.next(); // program name

    const command_arg = it.next() orelse return .{ .help = null };
    if (std.mem.eql(u8, command_arg, "-h") or std.mem.eql(u8, command_arg, "--help")) {
        return .{ .help = null };
    }
    const command = std.meta.stringToEnum(Command, std.mem.sliceTo(command_arg, 0)) orelse {
        parser_log.err("unknown command: {s}", .{command_arg});
        return .invalid;
    };

    return switch (command) {
        .help => {
            const topic_arg = it.next() orelse return .{ .command = .{ .help = .{} } };
            const topic = std.meta.stringToEnum(Command, std.mem.sliceTo(topic_arg, 0)) orelse {
                parser_log.err("unknown help topic: {s}", .{topic_arg});
                return .invalid;
            };
            if (it.next() != null) {
                parser_log.err("help accepts at most one command name", .{});
                return .invalid;
            }
            return .{ .command = .{ .help = .{ .topic = topic } } };
        },
        .run => {
            const args = parseOptions(RunArgs, it, run_spec.options) catch |err| return parseFailure(err, .run);
            return .{ .command = .{ .run = args } };
        },
        .routes => {
            const args = parseOptions(RoutesArgs, it, routes_spec.options) catch |err| return parseFailure(err, .routes);
            return .{ .command = .{ .routes = args } };
        },
        .tests => {
            const args = parseOptions(TestsArgs, it, tests_spec.options) catch |err| return parseFailure(err, .tests);
            return .{ .command = .{ .tests = args } };
        },
        .config => {
            const args = parseOptions(ConfigArgs, it, config_spec.options) catch |err| return parseFailure(err, .config);
            return .{ .command = .{ .config = args } };
        },
    };
}

const ParseError = error{ HelpRequested, Invalid };

fn parseFailure(err: ParseError, comptime command: Command) Outcome {
    return switch (err) {
        error.HelpRequested => .{ .help = command },
        error.Invalid => .invalid,
    };
}

fn parseOptions(comptime T: type, it: anytype, comptime options: []const Opt) ParseError!T {
    var out: T = .{};

    outer: while (it.next()) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }

        var name: []const u8 = arg;
        var inline_value: ?[:0]const u8 = null;
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }

        var matched = false;
        inline for (options) |opt| {
            const short_match = if (opt.short) |short|
                name.len == 2 and name[0] == '-' and name[1] == short
            else
                false;
            const long_match = name.len > 2 and name[0] == '-' and name[1] == '-' and std.mem.eql(u8, name[2..], opt.long);

            if (!matched and (short_match or long_match)) {
                matched = true;
                const Field = @TypeOf(@field(out, opt.field));

                if (comptime Field == ?bool) {
                    if (inline_value != null) {
                        parser_log.err("option --{s} does not take a value", .{opt.long});
                        return error.Invalid;
                    }
                    @field(out, opt.field) = true;
                } else {
                    const value = inline_value orelse it.next() orelse {
                        parser_log.err("option --{s} requires a value", .{opt.long});
                        return error.Invalid;
                    };
                    @field(out, opt.field) = try parseValue(Field, opt, value);
                }
            }
        }

        if (matched) continue :outer;

        parser_log.err("unknown option: {s}", .{arg});
        return error.Invalid;
    }

    return out;
}

fn parseValue(comptime T: type, comptime opt: Opt, value: [:0]const u8) ParseError!T {
    return switch (T) {
        ?[:0]const u8 => value,
        ?usize => std.fmt.parseInt(usize, value, 0) catch {
            parser_log.err("option --{s} expects an unsigned integer, got '{s}'", .{ opt.long, value });
            return error.Invalid;
        },
        ?std.Io.net.IpAddress => std.Io.net.IpAddress.parseLiteral(value) catch {
            parser_log.err("option --{s} expects an address like 127.0.0.1:8080, got '{s}'", .{ opt.long, value });
            return error.Invalid;
        },
        else => @compileError("unsupported option field type: " ++ @typeName(T)),
    };
}

fn optLabel(comptime opt: Opt) []const u8 {
    comptime var label: []const u8 = "  ";
    if (opt.short) |short| {
        label = label ++ "-" ++ [_]u8{short} ++ ", ";
    } else {
        label = label ++ "    ";
    }
    label = label ++ "--" ++ opt.long;
    if (opt.metavar) |metavar| label = label ++ " <" ++ metavar ++ ">";

    comptime var padding: []const u8 = "";
    comptime var i: usize = label.len;
    while (i < 32) : (i += 1) padding = padding ++ " ";

    return label ++ padding ++ opt.help;
}

fn buildHelp(comptime topic: ?Command) []const u8 {
    if (comptime topic == null) {
        comptime var out: []const u8 = "Rover 0.0.1\nCameron W.\n\nUsage: rover <command> [options]\n\nCommands:\n";
        inline for (commands) |spec| {
            out = out ++ "  " ++ spec.name;
            comptime var padding: []const u8 = "";
            comptime var i: usize = spec.name.len;
            while (i < 8) : (i += 1) padding = padding ++ " ";
            out = out ++ padding ++ spec.summary ++ "\n";
        }
        out = out ++ "\nRun 'rover help <command>' or 'rover <command> --help' for command options.\n";
        return out;
    }

    const spec = switch (topic.?) {
        .run => run_spec,
        .routes => routes_spec,
        .tests => tests_spec,
        .config => config_spec,
        .help => help_spec,
    };

    comptime var out: []const u8 = "Rover 0.0.1\nCameron W.\n\nUsage:\n  rover " ++ spec.name ++ " [options]\n\nOptions:\n";
    inline for (spec.options) |opt| {
        out = out ++ optLabel(opt) ++ "\n";
    }
    out = out ++ optLabel(.{ .short = 'h', .long = "help", .help = "Show this help message" }) ++ "\n";
    return out;
}

pub const help_general = buildHelp(null);
pub const help_run = buildHelp(.run);
pub const help_routes = buildHelp(.routes);
pub const help_tests = buildHelp(.tests);
pub const help_config = buildHelp(.config);

const TestIterator = struct {
    items: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *TestIterator) ?[:0]const u8 {
        if (self.index >= self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

test "unset options remain null so config.lua can supply them" {
    var it: TestIterator = .{ .items = &.{ "rover", "run" } };
    const args = switch (parseWith(&it)) {
        .command => |args| switch (args) {
            .run => |run_args| run_args,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(?std.Io.net.IpAddress, null), args.address);
    try std.testing.expectEqual(@as(?usize, null), args.max_read);
    try std.testing.expectEqual(@as(?bool, null), args.single_threaded);
}

test "top-level --help requests general help" {
    var it: TestIterator = .{ .items = &.{ "rover", "--help" } };
    const topic = switch (parseWith(&it)) {
        .help => |topic| topic,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(?Command, null), topic);
}

test "run parses options" {
    var it: TestIterator = .{ .items = &.{ "rover", "run", "-f", "app.lua", "--memory", "1024", "-s", "--addr=127.0.0.1:9000" } };
    const args = switch (parseWith(&it)) {
        .command => |args| switch (args) {
            .run => |run_args| run_args,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("app.lua", args.main_file.?);
    try std.testing.expectEqual(@as(?usize, 1024), args.memory);
    try std.testing.expectEqual(@as(?bool, true), args.single_threaded);
    try std.testing.expectEqual(@as(u16, 9000), args.address.?.getPort());
}

test "tests accepts a directory" {
    var it: TestIterator = .{ .items = &.{ "rover", "tests", "-d", "spec" } };
    const args = switch (parseWith(&it)) {
        .command => |args| switch (args) {
            .tests => |tests_args| tests_args,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("spec", args.test_dir.?);
}

test "config accepts a path" {
    var it: TestIterator = .{ .items = &.{ "rover", "config", "--config=prod.lua" } };
    const args = switch (parseWith(&it)) {
        .command => |args| switch (args) {
            .config => |config_args| config_args,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("prod.lua", args.config_path.?);
}

test "--help short-circuits command execution" {
    var it: TestIterator = .{ .items = &.{ "rover", "run", "--help" } };
    const topic = switch (parseWith(&it)) {
        .help => |topic| topic,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(?Command, .run), topic);
}

test "help command selects a topic" {
    var it: TestIterator = .{ .items = &.{ "rover", "help", "routes" } };
    const args = switch (parseWith(&it)) {
        .command => |args| switch (args) {
            .help => |help_args| help_args,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(?Command, .routes), args.topic);
}

test "unknown options are rejected" {
    var it: TestIterator = .{ .items = &.{ "rover", "run", "--bogus" } };
    switch (parseWith(&it)) {
        .invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "help text includes every option" {
    try std.testing.expect(std.mem.indexOf(u8, help_run, "--lua_threads") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_routes, "--config") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_general, "migrations") == null);
}
