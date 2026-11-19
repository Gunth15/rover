//! Comptime command line argument parsing for Rover.
//!
//! Commands are declared with a small comptime builder:
//!
//! ```zig
//! var root = argparse.rootCommand("rover", "Rover web framework");
//! const run = root.subCommand("run", "Runs a Rover program");
//! run.optionValue(usize, 'm', "memory", "Memory limit", "bytes");
//!
//! const cli = argparse.define(&root);
//! ```
//!
//! `define` materialises the tree, at comptime, into:
//!
//! * the help text for every command (`cli.root.help`), and
//! * the final argument type (`cli.Args`), where the selected command is a
//!   tagged union and every value option is an optional struct field.

const std = @import("std");
const lang = std.lang;

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    UnknownOption,
    MissingValue,
    InvalidValue,
    UnexpectedArgument,
};

/// A single command line option.
pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    desc: []const u8,
    /// Type the value is parsed into. `void` and `bool` mean a boolean switch.
    meta: type = void,
    /// Text shown between `<...>` in the help output. `null` derives it from
    /// `meta`, an empty string hides it.
    value: ?[]const u8 = null,
};

/// One node in the command tree. The builder creates these lazily at comptime;
/// call `define` to turn one into a static tree that can be used at runtime.
pub const Command = struct {
    name: []const u8,
    desc: []const u8,
    /// How the command is shown in a parent's command list. Defaults to `name`.
    display: ?[]const u8 = null,
    /// Full command path, e.g. `rover migrations create`.
    path: []const u8 = "",
    flags: []const Flag = &.{},
    subs: []const *const Command = &.{},
    is_root: bool = false,

    /// Add a boolean switch or a value option.
    pub fn option(
        comptime cmd: *Command,
        comptime T: type,
        comptime short: u8,
        comptime long: []const u8,
        comptime desc: []const u8,
    ) void {
        cmd.optionValue(T, short, long, desc, null);
    }

    /// Like `option`, but with an explicit `<placeholder>` for the help text.
    /// Pass `""` to hide the placeholder.
    pub fn optionValue(
        comptime cmd: *Command,
        comptime T: type,
        comptime short: u8,
        comptime long: []const u8,
        comptime desc: []const u8,
        comptime value: ?[]const u8,
    ) void {
        comptime {
            const flag: Flag = .{
                .short = short,
                .long = long,
                .desc = desc,
                .meta = T,
                .value = value,
            };
            var flags: [cmd.flags.len + 1]Flag = undefined;
            for (cmd.flags, 0..) |item, i| flags[i] = item;
            flags[cmd.flags.len] = flag;
            cmd.flags = &flags;
        }
    }

    /// Add a subcommand and return it so it can be configured further.
    pub fn subCommand(
        comptime cmd: *Command,
        comptime name: []const u8,
        comptime desc: []const u8,
    ) *Command {
        return comptime blk: {
            var sub: Command = .{
                .name = name,
                .desc = desc,
                .path = cmd.path ++ " " ++ name,
            };
            var subs: [cmd.subs.len + 1]*const Command = undefined;
            for (cmd.subs, 0..) |item, i| subs[i] = item;
            subs[cmd.subs.len] = &sub;
            cmd.subs = &subs;
            break :blk &sub;
        };
    }

    /// Render this command's help text at comptime.
    pub fn help(comptime cmd: *const Command, comptime cfg: HelpConfig) []const u8 {
        return comptime blk: {
            var out: []const u8 = "";

            out = out ++ cfg.title ++ " " ++ cfg.version ++ "\n";
            if (cfg.author) |author| {
                if (author.len > 0) out = out ++ author ++ "\n";
            }
            out = out ++ "\n";

            if (cmd.is_root) {
                out = out ++ "Usage: " ++ cmd.path;
                if (cmd.subs.len > 0) out = out ++ " <command>";
                if (cmd.flags.len > 0 or cmd.subs.len > 0) out = out ++ " [options]";
                out = out ++ "\n\n";
            } else {
                out = out ++ "Usage:\n  " ++ cmd.path;
                if (cmd.flags.len > 0) out = out ++ " [options]";
                if (cmd.subs.len > 0) out = out ++ " <command>";
                out = out ++ "\n\n";
            }

            if (cmd.flags.len > 0) {
                out = out ++ "Options:\n";
                for (cmd.flags) |flag| {
                    const column = if (cfg.options_column > 2) cfg.options_column - 2 else 0;
                    out = out ++ "  " ++ padRight(flagLabel(flag), column) ++ flag.desc ++ "\n";
                }
                out = out ++ "\n";
            }

            if (cmd.subs.len > 0) {
                out = out ++ (if (cmd.is_root) "Commands:\n" else "Sub Commands:\n");
                for (cmd.subs) |sub| {
                    const column = if (cfg.commands_column > 2) cfg.commands_column - 2 else 0;
                    const display = sub.display orelse sub.name;
                    if (cmd.is_root) {
                        out = out ++ "  " ++ padRight(display, column) ++ sub.desc ++ "\n";
                    } else {
                        out = out ++ "  " ++ padRight(display ++ ":", column) ++ sub.desc ++ "\n";
                    }
                }
                out = out ++ "\n";
            }

            // Keep a single trailing newline instead of a blank line.
            if (out.len >= 2 and out[out.len - 1] == '\n' and out[out.len - 2] == '\n') {
                out = out[0 .. out.len - 1];
            }

            break :blk out;
        };
    }
};

pub const HelpConfig = struct {
    title: []const u8 = "Rover",
    version: []const u8 = "0.0.1",
    author: ?[]const u8 = null,
    /// Column where option descriptions start.
    options_column: usize = 28,
    /// Column where command descriptions start.
    commands_column: usize = 22,
};

/// Create the root of a command tree. `name` is the program name used in usage
/// lines, not a subcommand name.
pub fn rootCommand(comptime name: []const u8, comptime desc: []const u8) Command {
    return .{
        .name = name,
        .desc = desc,
        .path = name,
        .is_root = true,
    };
}

/// Materialise a builder tree into a regular type with a static `root` command.
/// The builder itself is comptime-only; everything reachable from `define`'s
/// result lives in static storage and can be used at runtime.
pub fn define(comptime cmd: *const Command) type {
    const materialized = materialize(
        cmd.name,
        cmd.desc,
        cmd.display,
        cmd.flags,
        cmd.subs,
        cmd.path,
        cmd.is_root,
    );
    return struct {
        pub const root: Command = materialized;
        pub const Args = argsType(&root);

        pub fn help(comptime cfg: HelpConfig) []const u8 {
            return root.help(cfg);
        }

        pub fn parse(argv: []const []const u8) ParseError!Args {
            return parseArgs(&root, argv);
        }
    };
}

/// Deep-copy a comptime builder tree into static arrays of values. The tree is
/// passed by value (rather than as a pointer) so the result does not reference
/// the comptime variables used to build it.
fn materialize(
    comptime name: []const u8,
    comptime desc: []const u8,
    comptime display: ?[]const u8,
    comptime flags_in: []const Flag,
    comptime subs_in: []const *const Command,
    comptime path: []const u8,
    comptime is_root: bool,
) Command {
    // Copy first so the generated holder only captures values, not slices that
    // point at the builder's comptime variables.
    const flags_copy = blk: {
        var items: [flags_in.len]Flag = undefined;
        for (flags_in, 0..) |flag, i| items[i] = flag;
        break :blk items;
    };

    const children = blk: {
        var items: [subs_in.len]Command = undefined;
        for (subs_in, 0..) |sub, i| {
            const child_path = if (path.len == 0) sub.name else path ++ " " ++ sub.name;
            items[i] = materialize(
                sub.name,
                sub.desc,
                sub.display,
                sub.flags,
                sub.subs,
                child_path,
                sub.is_root,
            );
        }
        break :blk items;
    };

    const Node = struct {
        const flags = flags_copy;
        const kids = children;
        const child_ptrs = blk: {
            var items: [kids.len]*const Command = undefined;
            for (0..kids.len) |i| items[i] = &kids[i];
            break :blk items;
        };

        const value: Command = .{
            .name = name,
            .desc = desc,
            .display = display,
            .path = path,
            .flags = &flags,
            .subs = &child_ptrs,
            .is_root = is_root,
        };
    };

    return Node.value;
}

/// The struct containing the parsed options for one command.
pub fn Options(comptime cmd: *const Command) type {
    const n = cmd.flags.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]lang.Type.Struct.FieldAttributes = undefined;

    for (cmd.flags, 0..) |flag, i| {
        names[i] = fieldName(flag.long);
        if (isSwitch(flag)) {
            types[i] = bool;
            attrs[i] = defaultAttr(bool, false);
        } else {
            types[i] = ?flag.meta;
            attrs[i] = defaultAttr(?flag.meta, null);
        }
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The payload stored in the generated command union for `cmd`: its options,
/// plus a nested `command` union when it has subcommands.
pub fn Payload(comptime cmd: *const Command) type {
    if (cmd.subs.len == 0) return Options(cmd);

    const opts = Options(cmd);
    const info = @typeInfo(opts).@"struct";
    const n = info.field_names.len;

    var names: [n + 1][]const u8 = undefined;
    var types: [n + 1]type = undefined;
    var attrs: [n + 1]lang.Type.Struct.FieldAttributes = undefined;

    for (0..n) |i| {
        names[i] = info.field_names[i];
        types[i] = info.field_types[i];
        attrs[i] = info.field_attrs[i];
    }
    names[n] = "command";
    types[n] = Union(cmd);
    attrs[n] = .{};

    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The tagged union of all subcommands of `cmd`.
pub fn Union(comptime cmd: *const Command) type {
    if (cmd.subs.len == 0) @compileError("a command union needs at least one subcommand");

    const n = cmd.subs.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]lang.Type.Union.FieldAttributes = undefined;
    var values: [n]u16 = undefined;

    for (cmd.subs, 0..) |sub, i| {
        names[i] = fieldName(sub.name);
        types[i] = Payload(sub);
        attrs[i] = .{};
        values[i] = @intCast(i);
    }

    const Tag = @Enum(u16, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &attrs);
}

/// The final generated argument type. `command` is a tagged union with one
/// variant per top-level command; each variant's payload holds that command's
/// options (as optional fields) and, recursively, its own subcommand union.
pub fn argsType(comptime root: *const Command) type {
    if (root.subs.len == 0) @compileError("the root command needs at least one subcommand");
    const names = [_][]const u8{"command"};
    const types = [_]type{Union(root)};
    const attrs = [_]lang.Type.Struct.FieldAttributes{.{}};
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Parse `argv` with an explicit root command. `argv[0]` is the program name
/// and is skipped. Prefer `define(...).parse` for normal use.
pub fn parseArgs(comptime root: *const Command, argv: []const []const u8) ParseError!argsType(root) {
    if (argv.len == 0) return error.MissingCommand;
    var index: usize = 1;
    const command = try parseUnion(root, argv, &index);
    if (index != argv.len) return error.UnexpectedArgument;
    return .{ .command = command };
}

fn parseUnion(
    comptime cmd: *const Command,
    argv: []const []const u8,
    index: *usize,
) ParseError!Union(cmd) {
    if (index.* >= argv.len) return error.MissingCommand;
    const token = argv[index.*];
    index.* += 1;

    inline for (cmd.subs) |sub| {
        if (std.mem.eql(u8, token, sub.name)) {
            var payload = initPayload(sub);
            try parseOptions(sub, argv, index, &payload);
            if (comptime sub.subs.len > 0) {
                @field(payload, "command") = try parseUnion(sub, argv, index);
            }
            return @unionInit(Union(cmd), fieldName(sub.name), payload);
        }
    }

    return error.UnknownCommand;
}

fn parseOptions(
    comptime cmd: *const Command,
    argv: []const []const u8,
    index: *usize,
    payload: *Payload(cmd),
) ParseError!void {
    while (index.* < argv.len) {
        const token = argv[index.*];
        if (token.len == 0 or token[0] != '-') break;
        index.* += 1;

        var matched = false;
        inline for (cmd.flags) |flag| {
            if (!matched and matchFlag(flag, token)) {
                matched = true;
                const name = comptime fieldName(flag.long);
                if (comptime isSwitch(flag)) {
                    @field(payload.*, name) = true;
                } else {
                    const raw = try optionValue(token, argv, index);
                    @field(payload.*, name) = try parseValue(flag.meta, raw);
                }
            }
        }
        if (!matched) return error.UnknownOption;
    }
}

fn initPayload(comptime cmd: *const Command) Payload(cmd) {
    var payload: Payload(cmd) = undefined;
    inline for (cmd.flags) |flag| {
        const name = comptime fieldName(flag.long);
        if (comptime isSwitch(flag)) {
            @field(payload, name) = false;
        } else {
            @field(payload, name) = null;
        }
    }
    return payload;
}

fn matchFlag(comptime flag: Flag, token: []const u8) bool {
    if (token.len > 2 and token[0] == '-' and token[1] == '-') {
        const name = token[2..];
        const end = std.mem.indexOfScalar(u8, name, '=') orelse name.len;
        return std.mem.eql(u8, name[0..end], flag.long);
    }
    if (flag.short) |short| {
        return token.len == 2 and token[0] == '-' and token[1] == short;
    }
    return false;
}

fn optionValue(token: []const u8, argv: []const []const u8, index: *usize) ParseError![]const u8 {
    if (std.mem.startsWith(u8, token, "--")) {
        if (std.mem.indexOfScalar(u8, token, '=')) |eq| return token[eq + 1 ..];
    }
    if (index.* >= argv.len) return error.MissingValue;
    const value = argv[index.*];
    index.* += 1;
    return value;
}

fn parseValue(comptime T: type, raw: []const u8) ParseError!T {
    if (T == []const u8) return raw;
    if (T == [:0]const u8) return raw[0..raw.len :0];
    if (T == std.Io.net.IpAddress) return std.Io.net.IpAddress.parseLiteral(raw) catch error.InvalidValue;

    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, raw, 0) catch error.InvalidValue,
        .float => std.fmt.parseFloat(T, raw) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidValue,
        else => @compileError("argparse does not know how to parse " ++ @typeName(T)),
    };
}

fn isSwitch(comptime flag: Flag) bool {
    return flag.meta == void or flag.meta == bool;
}

fn flagLabel(comptime flag: Flag) []const u8 {
    var out: []const u8 = "";
    if (flag.short) |short| out = out ++ "-" ++ oneChar(short) ++ ", ";
    out = out ++ "--" ++ flag.long;

    if (flag.value) |value| {
        if (value.len > 0) out = out ++ " <" ++ value ++ ">";
    } else if (defaultPlaceholder(flag.meta)) |value| {
        out = out ++ " <" ++ value ++ ">";
    }

    return out;
}

fn defaultPlaceholder(comptime T: type) ?[]const u8 {
    if (T == void or T == bool) return null;
    return @typeName(T);
}

fn fieldName(comptime name: []const u8) []const u8 {
    const Holder = struct {
        const value = blk: {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |c, i| out[i] = if (c == '-') '_' else c;
            break :blk out;
        };
    };
    return &Holder.value;
}

fn oneChar(comptime char: u8) []const u8 {
    const Holder = struct {
        const value = [1]u8{char};
    };
    return &Holder.value;
}

fn padRight(comptime text: []const u8, comptime width: usize) []const u8 {
    if (text.len >= width) return text ++ " ";
    return text ++ spaces(width - text.len);
}

fn spaces(comptime count: usize) []const u8 {
    const Holder = struct {
        const value = blk: {
            var out: [count]u8 = undefined;
            @memset(&out, ' ');
            break :blk out;
        };
    };
    return &Holder.value;
}

fn defaultAttr(comptime T: type, comptime value: T) lang.Type.Struct.FieldAttributes {
    const Holder = struct {
        const stored: T = value;
    };
    return .{ .default_value_ptr = @ptrCast(&Holder.stored) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const rover = struct {
    fn build() type {
        return comptime blk: {
            var root = rootCommand("rover", "Rover web framework");

            const run = root.subCommand("run", "Runs a Rover program(defaults to main.lua)");
            run.optionValue(usize, 'm', "memory", "Limits memory allocations made by the entire process.", "bytes");
            run.optionValue([]const u8, 'c', "config", "Specify config file", "path");
            run.optionValue(usize, 'r', "read", "Max read buffer per connection (rounded to power of two)", "bytes");
            run.optionValue([]const u8, 'f', "file", "Lua script to execute", "path");
            run.optionValue(std.Io.net.IpAddress, 'a', "addr", "Address to bind (e.g. 127.0.0.1:8080)", "addr:port");
            run.option(bool, 's', "single_threaded", "Runs server in single threaded mode");
            run.optionValue(usize, 'l', "lua_threads", "Number of threads dedicated to lua workers", "");
            run.option(bool, 'h', "help", "Show this help message");

            _ = root.subCommand("help", "Show all commands");

            const routes = root.subCommand("routes", "Displays all routes");
            routes.optionValue([]const u8, 'f', "file", "Lua script to execute", "path");
            routes.option(bool, 'h', "help", "Show this help message");

            const tests = root.subCommand("tests", "Runs test out of the test directory(defaults to ./test)");
            tests.optionValue([]const u8, 'd', "dir", "Directory to look for test", "dir");
            tests.option(bool, 'h', "help", "Show this help message");

            const config = root.subCommand("config", "Print the current configuration");
            config.optionValue([]const u8, 'c', "config", "Specify config file", "path");

            const migrations = root.subCommand("migrations", "Migrations hub");
            _ = migrations.subCommand("create", "Create a new migration");
            const up = migrations.subCommand("up-to", "Upgrades database to given version");
            up.display = "up-to   <version>";
            const down = migrations.subCommand("down-to", "Downgrades database to given version");
            down.display = "down-to <version>";
            _ = migrations.subCommand("status", "Prints status of all migrations");
            _ = migrations.subCommand("version", "Prints current database version");

            break :blk define(&root);
        };
    }
};

const Cli = rover.build();

const expected_root =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage: rover <command> [options]
    \\
    \\Commands:
    \\  run                 Runs a Rover program(defaults to main.lua)
    \\  help                Show all commands
    \\  routes              Displays all routes
    \\  tests               Runs test out of the test directory(defaults to ./test)
    \\  config              Print the current configuration
    \\  migrations          Migrations hub
    \\
;

const expected_run =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover run [options]
    \\
    \\Options:
    \\  -m, --memory <bytes>      Limits memory allocations made by the entire process.
    \\  -c, --config <path>       Specify config file
    \\  -r, --read <bytes>        Max read buffer per connection (rounded to power of two)
    \\  -f, --file <path>         Lua script to execute
    \\  -a, --addr <addr:port>    Address to bind (e.g. 127.0.0.1:8080)
    \\  -s, --single_threaded     Runs server in single threaded mode
    \\  -l, --lua_threads         Number of threads dedicated to lua workers
    \\  -h, --help                Show this help message
    \\
;

const expected_migrations =
    \\Rover 0.0.1
    \\Cameron W.
    \\
    \\Usage:
    \\  rover migrations <command>
    \\
    \\Sub Commands:
    \\  create:                   Create a new migration
    \\  up-to   <version>:        Upgrades database to given version
    \\  down-to <version>:        Downgrades database to given version
    \\  status:                   Prints status of all migrations
    \\  version:                  Prints current database version
    \\
;

test "comptime help matches the shapes used by rover" {
    const cfg: HelpConfig = .{ .author = "Cameron W." };

    try std.testing.expectEqualStrings(expected_root, Cli.root.help(cfg));
    try std.testing.expectEqualStrings(expected_run, Cli.root.subs[0].help(cfg));
    try std.testing.expectEqualStrings(
        expected_migrations,
        Cli.root.subs[5].help(.{
            .author = "Cameron W.",
            .commands_column = 28,
        }),
    );
}

test "generated args type is a tagged union with optional option fields" {
    const parsed = try Cli.parse(&.{ "rover", "run", "--memory", "4096", "-f", "main.lua", "-s" });
    try std.testing.expectEqual(@as(?usize, 4096), parsed.command.run.memory);
    try std.testing.expectEqual(@as(?[]const u8, "main.lua"), parsed.command.run.file);
    try std.testing.expect(parsed.command.run.single_threaded);
    try std.testing.expectEqual(@as(?usize, null), parsed.command.run.read);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.command.run.config);

    // The full command tree is reflected in the generated type.
    const info = @typeInfo(@TypeOf(parsed.command)).@"union";
    try std.testing.expectEqual(@as(usize, 6), info.field_names.len);
    try std.testing.expectEqualStrings("migrations", info.field_names[5]);

    const migrations = try Cli.parse(&.{ "rover", "migrations", "up-to" });
    try std.testing.expectEqual(
        std.meta.Tag(Union(Cli.root.subs[5])).up_to,
        std.meta.activeTag(migrations.command.migrations.command),
    );
}

test "parses values, rejects bad input" {
    const Tool = comptime blk: {
        var root = rootCommand("tool", "test tool");
        const run = root.subCommand("run", "run it");
        run.optionValue(usize, 'n', "number", "a number", "n");
        run.optionValue([]const u8, 'o', "output", "output path", "path");
        break :blk define(&root);
    };

    const parsed = try Tool.parse(&.{ "tool", "run", "--number=7", "-o", "out.txt" });
    try std.testing.expectEqual(@as(?usize, 7), parsed.command.run.number);
    try std.testing.expectEqual(@as(?[]const u8, "out.txt"), parsed.command.run.output);

    try std.testing.expectError(error.UnknownCommand, Tool.parse(&.{ "tool", "nope" }));
    try std.testing.expectError(error.UnknownOption, Tool.parse(&.{ "tool", "run", "--wat" }));
    try std.testing.expectError(error.MissingValue, Tool.parse(&.{ "tool", "run", "--number" }));
    try std.testing.expectError(error.InvalidValue, Tool.parse(&.{ "tool", "run", "--number", "nope" }));
}

test "builder links subcommands and flags" {
    comptime {
        var root = rootCommand("tool", "test tool");
        root.option(bool, 'v', "verbose", "verbose output");
        const sub = root.subCommand("sub", "a subcommand");
        sub.option(u8, 'x', "xray", "xray flag");

        if (root.flags.len != 1) @compileError("root flag was not added");
        if (root.subs.len != 1) @compileError("subcommand was not linked");
        if (root.subs[0].flags.len != 1) @compileError("subcommand flag was not added");
        if (!std.mem.eql(u8, root.subs[0].path, "tool sub")) @compileError("bad command path");
    }
}
