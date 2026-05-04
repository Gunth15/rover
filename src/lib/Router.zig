const std = @import("std");
const Lua = @import("./lua/Lua.zig");
const Allocator = std.mem.Allocator;
pub const SearchError = error{
    DoesNotExist,
    InvalidMethod,
} || Allocator.Error;
pub const RegistrationError = error{
    AlreadyExist,
    WildCardConflict,
    MultipleWilCardsPerSegment,
    UnamedWildCard,
    WildCardChildNotAllowed,
    CatchAllIsNotTerminal,
    CatchAllConflict,
    InvalidMethod,
} || Allocator.Error;

const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    fn from(str: []const u8) ?Method {
        return std.meta.stringToEnum(Method, str);
    }
    fn to(m: Method) []const u8 {
        return @tagName(m);
    }
};
const Path = union(enum) {
    //root
    root: []const u8,
    //*name, catch all
    catch_all: []const u8,
    //:name, named_param
    named: []const u8,
    static: []const u8,
    pub inline fn slice(p: Path) []const u8 {
        return switch (p) {
            .root => |s| s,
            .catch_all => |s| s,
            .named => |s| s,
            .static => |s| s,
        };
    }
    inline fn lsplit(p: Path, i: usize) Path {
        return switch (p) {
            .root => |s| .{ .root = s[0..i] },
            .catch_all => |s| .{ .catch_all = s[0..i] },
            .named => |s| .{ .named = s[0..i] },
            .static => |s| .{ .static = s[0..i] },
        };
    }
    inline fn rsplit(p: Path, i: usize) Path {
        return switch (p) {
            .root => |s| .{ .root = s[i..] },
            .catch_all => |s| .{ .catch_all = s[i..] },
            .named => |s| .{ .named = s[i..] },
            .static => |s| .{ .static = s[i..] },
        };
    }
    pub inline fn len(p: Path) usize {
        return p.slice().len;
    }
};
pub fn Node(T: type) type {
    return struct {
        const Self = @This();
        path: Path,
        //used for optimizing traversal
        priority: u32 = 0,
        //optimization to get next node and avoid cache misses
        indices: std.ArrayList(u8) = .empty,
        wild_child: bool = false,
        children: std.ArrayList(*Self) = .empty,
        handles: std.AutoArrayHashMap(Method, T),
        //get next child
        fn next(n: *Self, path: []const u8) ?*Self {
            const cidx = path[0];
            if (n.wild_child) return n.children.items[0];
            const start_idx: usize = if (n.wild_child) 1 else 0;
            for (n.indices.items[start_idx..], start_idx..) |c, i| if (cidx == c) {
                const newpos = n.updatePrio(i);
                return n.children.items[newpos];
            };
            return null;
        }
        fn addChild(n: *Self, alloc: Allocator, full_path: []const u8) RegistrationError!*Self {
            var path = try alloc.dupe(u8, full_path);
            var node = n;
            walk: while (true) {
                var child = try alloc.create(Self);
                if (try findWildcard(path)) |w| {
                    const wildcard, const i = w;
                    if (wildcard.len < 2) return RegistrationError.UnamedWildCard;

                    //NOTE: router does not allow /path/:bank /path/chase at this time for simplicity
                    if (node.children.items.len > 0) return RegistrationError.WildCardChildNotAllowed;

                    //namespace wildcard found
                    if (wildcard[0] == ':') {
                        if (i > 0) {
                            //split path, so static prefix is a new node
                            child.* = .{
                                .path = .{ .static = path[0..i] },
                                .priority = 1,
                                .wild_child = true,
                                .children = try .initCapacity(alloc, 4),
                                .indices = try .initCapacity(alloc, 4),
                                .handles = .init(alloc),
                            };

                            try node.indices.append(alloc, path[0]);
                            try node.children.append(alloc, child);

                            path = path[i..];
                            node = child;
                            child = try alloc.create(Self);
                        }
                        //new node is named param path
                        child.* = .{
                            .path = .{ .named = wildcard },
                            .priority = 0,
                            .wild_child = false,
                            .children = try .initCapacity(alloc, 4),
                            .indices = try .initCapacity(alloc, 4),
                            .handles = .init(alloc),
                        };

                        try node.children.insert(alloc, 0, child);

                        if (wildcard.len < path.len) {
                            path = path[wildcard.len..];
                            node = child;
                            node.priority += 1;
                            continue :walk;
                        }

                        return child;
                    }
                    //assumed to be catch-all ATP
                    if (i + wildcard.len != path.len) return RegistrationError.CatchAllIsNotTerminal;
                    if (node.path.len() > 0 and node.path.slice()[node.path.len() - 1] == '/') return RegistrationError.CatchAllConflict;

                    const catch_idx = i - 1;
                    if (path[catch_idx] != '/') return RegistrationError.CatchAllIsNotTerminal;

                    child.* = .{
                        .path = .{ .static = path[0..i] },
                        .priority = 0,
                        .wild_child = true,
                        .children = try .initCapacity(alloc, 4),
                        .indices = try .initCapacity(alloc, 4),
                        .handles = .init(alloc),
                    };
                    try node.indices.append(alloc, path[0]);
                    try node.children.append(alloc, child);

                    node = child;
                    child = try alloc.create(Self);

                    child.* = .{
                        .path = .{ .catch_all = wildcard },
                        .priority = 0,
                        .wild_child = false,
                        .children = try .initCapacity(alloc, 4),
                        .indices = try .initCapacity(alloc, 4),
                        .handles = .init(alloc),
                    };
                    try node.children.append(alloc, child);

                    return child;
                } else {
                    //simple add static child
                    child.* = .{
                        .path = .{ .static = path },
                        .priority = 0,
                        .wild_child = false,
                        .children = try .initCapacity(alloc, 4),
                        .indices = try .initCapacity(alloc, 4),
                        .handles = .init(alloc),
                    };

                    try node.indices.append(alloc, path[0]);
                    try node.children.append(alloc, child);
                    return child;
                }
            }
            unreachable;
        }
        inline fn getHandle(n: *Self, method: []const u8) SearchError!T {
            const m = Method.from(method) orelse return SearchError.InvalidMethod;
            return n.handles.get(m) orelse SearchError.InvalidMethod;
        }
        //returns new position
        fn updatePrio(n: *Self, pos: usize) usize {
            const nodes = n.children.items;
            nodes[pos].priority += 1;

            const prio = nodes[pos].priority;
            var npos = pos;

            while (npos > 0 and nodes[npos - 1].priority < prio) : (npos -= 1) {
                //swap
                const temp = nodes[npos - 1];
                nodes[npos - 1] = nodes[npos];
                nodes[npos] = temp;
            }
            const start_idx: usize = if (n.wild_child) 1 else 0;
            for (start_idx..n.children.items.len) |i| {
                n.indices.items[i] = n.children.items[i].path.slice()[0];
            }
            return npos;
        }
        fn printNode(n: *Node(T), depth: usize) void {
            const kind = switch (n.path) {
                .root => "root",
                .static => "static",
                .named => "param",
                .catch_all => "catch_all",
            };

            std.debug.print(
                "- [{s}] \"{s}\" (prio={d}, children={d})",
                .{ kind, n.path.slice(), n.priority, n.children.items.len },
            );

            // print methods
            if (n.handles.count() > 0) {
                std.debug.print(" methods=[", .{});
                var it = n.handles.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) std.debug.print(", ", .{});
                    first = false;
                    std.debug.print("{s}", .{entry.key_ptr.*});
                }
                std.debug.print("]", .{});
            }

            std.debug.print("\n", .{});

            // children
            for (n.children.items) |child| {
                child.printNode(depth + 1);
            }
        }
    };
}

pub fn Router(T: type) type {
    return struct {
        root: Node(T),
        //if route can't be matched, but a path exist without the trailing slash exist
        //It is redirected to that one
        redirect_trailing_slash: bool,

        //returned when no route is found
        not_found_handler: ?T,

        //returned when no route is found
        invalid_method_handler: ?T,

        //allocators
        arena: std.heap.ArenaAllocator,

        const Self = @This();
        pub const RNode = Node(T);
        pub fn init(alloc: Allocator, redirect_trailing_slash: bool, invalid_method_handler: ?T, not_found_handler: ?T) Allocator.Error!Self {
            var arena = std.heap.ArenaAllocator.init(alloc);
            const nalloc = arena.allocator();
            return .{
                .root = .{
                    .path = .{ .static = "" },
                    .priority = 0,
                    .wild_child = false,
                    .children = try .initCapacity(nalloc, 4),
                    .indices = try .initCapacity(nalloc, 4),
                    .handles = .init(nalloc),
                },
                .arena = arena,
                .not_found_handler = not_found_handler,
                .redirect_trailing_slash = redirect_trailing_slash,
                .invalid_method_handler = invalid_method_handler,
            };
        }
        pub fn deinit(r: *Self) void {
            r.arena.deinit();
        }
        pub fn regiser(r: *Self, method: []const u8, full_path: []const u8, handle: T) RegistrationError!void {
            const alloc = r.arena.allocator();
            var path = full_path;
            var n: *Node(T) = &r.root;
            walk: while (true) {
                const i = std.mem.indexOfDiff(u8, path, n.path.slice()) orelse {
                    const m = Method.from(method) orelse return RegistrationError.InvalidMethod;
                    return if (n.handles.contains(m)) RegistrationError.AlreadyExist else {
                        try n.handles.put(m, handle);
                    };
                };
                if (i < n.path.len()) {
                    const child = try alloc.create(Node(T));
                    child.* = .{
                        .path = n.path.rsplit(i),
                        .priority = @max(n.priority, 1) - 1,
                        .indices = n.indices,
                        .children = n.children,
                        .wild_child = n.wild_child,
                        .handles = n.handles,
                    };
                    n.* = .{
                        .path = .{ .static = n.path.lsplit(i).slice() },
                        .indices = .empty,
                        .children = .empty,
                        .wild_child = false,
                        .handles = .init(alloc),
                    };
                    try n.indices.append(alloc, path[i]);
                    try n.children.append(alloc, child);
                    _ = n.updatePrio(n.children.items.len - 1);
                }

                if (i < path.len) {
                    path = path[i..];
                    if (n.wild_child) {
                        n = n.children.items[0];
                        n.priority += 1;
                        if (
                        //catch alls can't have children
                        n.path != .catch_all and
                            //make sure path conatins wildcard
                            path.len >= n.path.len() and std.mem.eql(u8, path[0..n.path.len()], n.path.slice()) and
                            //check if there is a longer wildcard
                            (n.path.len() >= path.len or path[n.path.len()] == '/')) continue :walk else return RegistrationError.WildCardConflict;
                    }

                    n = n.next(path) orelse {
                        const child = try n.addChild(alloc, path);
                        const m = Method.from(method) orelse return RegistrationError.InvalidMethod;
                        try child.handles.put(m, handle);
                        return;
                    };
                    continue :walk;
                }
            }
            unreachable;
        }
        //uses notfound handler if it one exist.
        pub fn search(r: *Self, assigns: *std.StringArrayHashMap([]const u8), method: []const u8, full_path: []const u8) SearchError!T {
            var path = full_path;
            const alloc = r.arena.allocator();

            var prefix = std.ArrayList(u8).empty;
            defer prefix.deinit(alloc);

            var n: *Node(T) = &r.root;
            while (true) {
                switch (n.path) {
                    .catch_all => |edge| {
                        try assigns.put(edge[1..], path);
                        try prefix.appendSlice(alloc, path);
                    },
                    .named => |edge| {
                        var iter = std.mem.splitAny(u8, path, "/");
                        const value = iter.first();
                        try assigns.put(edge[1..], value);
                        try prefix.appendSlice(alloc, value);
                    },
                    .root, .static => |edge| try prefix.appendSlice(alloc, edge),
                }

                if (full_path.len - prefix.items.len <= 0) {
                    if (std.mem.eql(u8, full_path, prefix.items)) {
                        const m = Method.from(method) orelse return SearchError.InvalidMethod;
                        return n.handles.get(m) orelse if (r.invalid_method_handler) |handle| handle else SearchError.InvalidMethod;
                    } else {
                        //prefix is longer, no node found
                        return if (r.not_found_handler) |handle| handle else SearchError.DoesNotExist;
                    }
                }

                path = path[prefix.items.len..];

                //Go deeper
                n = n.next(path) orelse {
                    //No you won't
                    return if (r.not_found_handler) |handle| handle else SearchError.DoesNotExist;
                };
            }
            unreachable;
        }
        pub fn debugPrint(r: *Self) void {
            std.debug.print("=== ROUTER TREE ===\n", .{});
            r.root.printNode(0);
        }
    };
}
fn findWildcard(path: []const u8) RegistrationError!?struct { []const u8, usize } {
    for (path, 0..) |start, start_idx| {
        switch (start) {
            '*', ':' => {
                for (path[start_idx + 1 ..], start_idx + 1..) |end, end_idx| {
                    switch (end) {
                        '/' => return .{ path[start_idx .. start_idx + 1 + end_idx], start_idx },
                        '*', ':' => return RegistrationError.MultipleWilCardsPerSegment,
                        else => continue,
                    }
                }
                return .{ path[start_idx..], start_idx };
            },
            else => continue,
        }
    }
    return null;
}

test "register and find static route" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/home", 1);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    const res = try router.search(&assigns, "GET", "/home");
    try std.testing.expectEqual(@as(usize, 1), res);
}

test "invalid method" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/home", 1);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    try std.testing.expectError(
        SearchError.InvalidMethod,
        router.search(&assigns, "POST", "/home"),
    );
}

test "path splitting works" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/cat", 1);
    try router.regiser("GET", "/car", 2);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    try std.testing.expectEqual(@as(usize, 1), try router.search(&assigns, "GET", "/cat"));
    try std.testing.expectEqual(@as(usize, 2), try router.search(&assigns, "GET", "/car"));
}

test "named parameter extraction" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/user/:id", 1);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    _ = try router.search(&assigns, "GET", "/user/42");

    try std.testing.expectEqualStrings("42", assigns.get("id").?);
}

test "catch all route" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/static/*filepath", 1);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    _ = try router.search(&assigns, "GET", "/static/js/app.js");

    try std.testing.expectEqualStrings("js/app.js", assigns.get("filepath").?);
}

test "wildcard conflict" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/user/:id", 1);

    try std.testing.expectError(
        RegistrationError.WildCardConflict,
        router.regiser("GET", "/user/*path", 2),
    );
}

test "catch all cannot have children" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/files/*path", 1);

    try std.testing.expectError(
        RegistrationError.WildCardConflict,
        router.regiser("GET", "/files/*path/more", 2),
    );
}

test "not found" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    try std.testing.expectError(
        SearchError.DoesNotExist,
        router.search(&assigns, "GET", "/nope"),
    );
}

test "trailing slash mismatch" {
    const R = Router(usize);

    var router = try R.init(std.testing.allocator, false, null, null);
    defer router.deinit();

    try router.regiser("GET", "/home", 1);

    var assigns = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer assigns.deinit();

    try std.testing.expectError(
        SearchError.DoesNotExist,
        router.search(&assigns, "GET", "/home/"),
    );
}
