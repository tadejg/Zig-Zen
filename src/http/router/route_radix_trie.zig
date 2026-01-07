//! Implements a comptime-built radix trie used for http routing. Routes may contain zero or more params (using the
//! colon syntax e.g. `:param_name`) and up to one wildcard (*), which must be the last segment of the route.
//!
//! Valid route examples:
//!
//! ```
//! /
//! /foo/bar
//! /foo/bar/
//! /foo/:param
//! /foo/:param1/bar/:param2/baz
//! /foo/*
//!```
//!
//! Invalid route examples:
//!
//! ```
//! /foo/*/bar
//! /foo/*/bar/*
//! ```
const std = @import("std");

pub const WILDCARD_CHAR = '*';
pub const PARAM_MARKER = ':';
pub const PATH_SEPARATOR = '/';

pub const Node = struct {
    type: Type,
    value: []const u8,
    target: ?*const anyopaque,
    children: []const *Node,

    pub const root = @This(){
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{},
    };

    /// Order of this enum determines the node priority!!
    /// We want static nodes to match first, then param nodes, and finally, fallback to wildcards
    /// @see insert()
    pub const Type = enum {
        static,
        param,
        wildcard,
    };
};

pub const WildcardMode = enum {
    oneOrMore,
    zeroOrMore,
};

pub const RouteSpec = struct {
    pattern: []const u8,
    target: *const anyopaque,
};

pub fn RouteRadixTrie(comptime routes: []const RouteSpec, comptime _wildcardMode: WildcardMode) type {
    comptime var _root: Node = .root;
    inline for (routes) |*r| comptime addRoute(&_root, r);
    return struct {
        const root: Node = _root;
        pub const wildcardMode = _wildcardMode;

        pub fn match(path: []const u8) ?*const anyopaque {
            const normalizedPath = normalize(path);
            return matchPath(wildcardMode, &root, normalizedPath);
        }
    };
}

fn matchPath(comptime wildcardMode: WildcardMode, comptime node: *const Node, path: []const u8) ?*const anyopaque {
    // Special case for root pattern
    if (path.len == 0) return node.target;
    inline for (node.children) |child| {
        switch (child.type) {
            .static => {
                const childHasLen = child.value.len > 0;
                const childEndsWithPathSep = childHasLen and child.value[child.value.len - 1] == PATH_SEPARATOR;
                const maybeWildcard = childHasLen and std.mem.eql(u8, child.value[0 .. child.value.len - 1], path);
                if (wildcardMode == .zeroOrMore and childEndsWithPathSep and maybeWildcard) {
                    // \r has no special meaning. It's there to prevent the remaining slice from reaching len of 0,
                    // triggering root path special case
                    return matchPath(wildcardMode, child, "\t");
                }
                if (std.mem.startsWith(u8, path, child.value)) {
                    const remainingPath = path[child.value.len..];
                    if (remainingPath.len == 0) return child.target;
                    return matchPath(wildcardMode, child, remainingPath);
                }
            },
            .param => {
                const paramEndIdx = std.mem.findScalarPos(u8, path, 0, PATH_SEPARATOR) orelse path.len;
                const remainingPath = path[paramEndIdx..];
                if (remainingPath.len == 0) {
                    if (wildcardMode == .zeroOrMore and child.target == null) {
                        // Is there a wildcard node one path separator away?
                        // \r has no special meaning. It's there to prevent the remaining slice from reaching len of 0,
                        // breaking zeroOrMore condition for static nodes
                        return matchPath(wildcardMode, child, "/\r");
                    }
                    return child.target;
                }
                // We can't be sure this is the right node to take, because the rest of the path may still not match
                if (matchPath(wildcardMode, child, remainingPath)) |t| return t;
            },
            .wildcard => return child.target,
        }
    }
    return null;
}

fn insert(
    comptime node: *Node,
    comptime pattern: []const u8,
    comptime target: ?*const anyopaque,
) error{ Duplicate, Unsupported }!void {
    // Special case for root pattern
    if (pattern.len == 0) {
        if (node.target == null) {
            node.target = target;
        } else return error.Duplicate;
        return;
    }
    comptime var nextParamIdx: ?comptime_int = null;
    const wildcardIdx: comptime_int = std.mem.findScalarPos(u8, pattern, 0, WILDCARD_CHAR) orelse pattern.len;
    if (wildcardIdx < pattern.len - 1) return error.Unsupported;
    if (pattern.len > 0 and pattern[0] == PARAM_MARKER) {
        nextParamIdx = 0;
    } else if (std.mem.findPos(u8, pattern, 0, &.{ PATH_SEPARATOR, PARAM_MARKER })) |i| {
        nextParamIdx = i + 1;
    }
    const nextParamEnd: comptime_int = if (nextParamIdx) |n| blk: {
        break :blk std.mem.findScalarPos(u8, pattern, n, PATH_SEPARATOR) orelse pattern.len;
    } else pattern.len;
    inline for (node.children) |child| {
        // child.value is irrelevant for non-static nodes
        switch (child.type) {
            .static => {
                if (child.value.len < pattern.len) {
                    if (std.mem.startsWith(u8, pattern, child.value)) {
                        return insert(child, pattern[child.value.len..], target);
                    }
                } else {
                    const prefixLen = std.mem.findDiff(u8, child.value, pattern);
                    if (prefixLen) |len| {
                        if (len != 0) {
                            comptime var splitNode = Node{
                                .value = child.value[len..],
                                .type = child.type,
                                .target = child.target,
                                .children = child.children,
                            };
                            child.value = child.value[0..len];
                            child.children = &.{&splitNode};
                            child.target = null;
                            return insert(child, pattern[len..], target);
                        }
                    } else return error.Duplicate;
                }
            },
            .param => {
                if (nextParamIdx == 0 and nextParamEnd == pattern.len) {
                    if (child.target == null) {
                        child.target = target;
                        return;
                    } else return error.Duplicate;
                } else if (nextParamIdx == 0) {
                    return insert(child, pattern[nextParamEnd..], target);
                }
            },
            .wildcard => {
                if (wildcardIdx == 0) return error.Duplicate;
            },
        }
    }
    const staticValueEnd = @min(nextParamIdx orelse pattern.len, wildcardIdx);
    const isFinalParam = nextParamIdx == 0 and nextParamEnd == pattern.len;
    const isEnd = (nextParamIdx == null and wildcardIdx == pattern.len) or wildcardIdx == 0 or isFinalParam;
    comptime var newNode = Node{
        .value = if (nextParamIdx == 0) "" else pattern[0..staticValueEnd],
        .type = if (nextParamIdx == 0) .param else if (wildcardIdx == 0) .wildcard else .static,
        .target = if (isEnd) target else null,
        .children = &.{},
    };
    insertChild(&node.children, &newNode);
    if (nextParamIdx != null or wildcardIdx != pattern.len) {
        const remainingPattern = if (nextParamIdx == 0) blk: {
            break :blk pattern[nextParamEnd..];
        } else if (pattern.len == 1 and wildcardIdx == 0) blk: {
            break :blk "";
        } else blk: {
            break :blk pattern[staticValueEnd..];
        };
        if (remainingPattern.len > 0) {
            return insert(&newNode, remainingPattern, target);
        }
    }
}

fn insertChild(comptime children: *[]const *Node, comptime newNode: *Node) void {
    const score = @intFromEnum(newNode.type);
    comptime var out: []const *Node = &.{};
    comptime var inserted = false;
    inline for (children.*) |child| {
        if (score < @intFromEnum(child.type) and !inserted) {
            out = out ++ &[_]*Node{ newNode, child };
            inserted = true;
        } else {
            out = out ++ &[_]*Node{child};
        }
    }
    if (!inserted) {
        out = out ++ &[_]*Node{newNode};
    }
    children.* = out;
}

fn normalize(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, &(std.ascii.whitespace ++ .{PATH_SEPARATOR}));
}

fn addRoute(comptime root: *Node, comptime route: *const RouteSpec) void {
    const normalizedPattern = normalize(route.pattern);
    insert(root, normalizedPattern, @ptrCast(@alignCast(route.target))) catch |e| switch (e) {
        error.Duplicate => @compileError("Duplicate route pattern: \"" ++ route.pattern ++ "\""),
        error.Unsupported => @compileError("Unsupported route pattern: \"" ++ route.pattern ++ "\""),
    };
}

/// Only for use in tests
const ExpectedNode = struct {
    type: Node.Type,
    value: []const u8,
    target: ?*const anyopaque,
    children: []const *const ExpectedNode,
};

/// Only for use in tests
fn expectTrie(comptime expected: *const ExpectedNode, comptime actual: *const Node) !void {
    try std.testing.expectEqualStrings(expected.value, actual.value);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    try std.testing.expectEqual(expected.target, actual.target);
    try std.testing.expectEqual(expected.type, actual.type);
    inline for (expected.children, actual.children) |expectedChild, actualChild| {
        comptime try expectTrie(expectedChild, actualChild);
    }
}

/// For debugging only
/// JS oneliner to prettify the output, since control characters don't get interpreted with @comptimeLog():
/// ```
/// console.log(
///     fs.readFileSync("/tmp/test.txt").toString('utf8').split("\n").filter(v => !!v).map(
///         v => v.split('"')[1].replace(/\\n/g, "\n").replace(/\\t/g, "\t")
///     ).join("\n")
/// )
/// ```
/// Save the output into `/tmp/test.txt` and run the script.
/// Output example:
/// ```
/// @as(*const [50:0]u8, "Type: static\nValue: '/'\nHas target: no\nChildren: 1")
/// @as(*const [61:0]u8, "\tType: static\n\tValue: 'foo/bar/'\n\tHas target: no\n\tChildren: 3")
/// @as(*const [61:0]u8, "\t\tType: static\n\t\tValue: 'baz/'\n\t\tHas target: no\n\t\tChildren: 1")
/// @as(*const [64:0]u8, "\t\t\tType: wildcard\n\t\t\tValue: ''\n\t\t\tHas target: yes\n\t\t\tChildren: 0")
/// @as(*const [56:0]u8, "\t\tType: param\n\t\tValue: ''\n\t\tHas target: no\n\t\tChildren: 1")
/// @as(*const [62:0]u8, "\t\t\tType: static\n\t\t\tValue: '/'\n\t\t\tHas target: no\n\t\t\tChildren: 1")
/// @as(*const [68:0]u8, "\t\t\t\tType: wildcard\n\t\t\t\tValue: ''\n\t\t\t\tHas target: yes\n\t\t\t\tChildren: 0")
/// @as(*const [60:0]u8, "\t\tType: wildcard\n\t\tValue: ''\n\t\tHas target: yes\n\t\tChildren: 0")
/// ```
fn printTrie(comptime node: *const Node, comptime offset: comptime_int) void {
    @compileLog(std.fmt.comptimePrint(
        "{[padding]s}Type: {[type]s}\n{[padding]s}Value: '{[value]s}'\n{[padding]s}Has target: {[hasTarget]s}\n" ++
            "{[padding]s}Children: {[nChildren]d}",
        .{
            .padding = &[_]u8{'\t'} ** offset,
            .type = @tagName(node.type),
            .value = node.value,
            .hasTarget = if (node.target == null) "no" else "yes",
            .nChildren = node.children.len,
        },
    ));
    inline for (node.children) |child| {
        printTrie(child, offset + 1);
    }
}

test addRoute {
    const Request = @import("../request.zig");
    const Response = @import("../response.zig");
    comptime var root: Node = .root;
    const barHandler = struct {
        fn handler(_: *const Request) !Response {
            return .{ .statusCode = .ok };
        }
    }.handler;
    comptime addRoute(&root, &RouteSpec{
        .pattern = "/foo/bar",
        .target = barHandler,
    });
    try std.testing.expectEqual(1, root.children.len);
    try std.testing.expectEqualStrings("foo/bar", root.children[0].value);
    try std.testing.expect(root.children[0].target != null);
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/bar",
                .target = barHandler,
                .children = &.{},
            },
        },
    }, &root);
    const bazHandler = struct {
        fn handler(_: *const Request) !Response {
            return .{ .statusCode = .ok };
        }
    }.handler;
    comptime addRoute(&root, &RouteSpec{
        .pattern = "/foo/baz",
        .target = bazHandler,
    });
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/ba",
                .target = null,
                .children = &.{
                    &.{
                        .type = .static,
                        .value = "r",
                        .target = barHandler,
                        .children = &.{},
                    },
                    &.{
                        .type = .static,
                        .value = "z",
                        .target = bazHandler,
                        .children = &.{},
                    },
                },
            },
        },
    }, &root);
}

test "should insert a root pattern" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
        .children = &.{},
    }, &root);
}

test "should insert a static pattern" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/bar",
                .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                .children = &.{},
            },
        },
    }, &root);
}

test "should split static pattern on insert" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime insert(&root, "foo/baz", @ptrCast(@alignCast(FOOBAZ_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/ba",
                .target = null,
                .children = &.{
                    &.{
                        .type = .static,
                        .value = "r",
                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                        .children = &.{},
                    },
                    &.{
                        .type = .static,
                        .value = "z",
                        .target = @ptrCast(@alignCast(FOOBAZ_TARGET)),
                        .children = &.{},
                    },
                },
            },
        },
    }, &root);
}

test "should reject duplicate patterns" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const err = comptime insert(&root, "foo/bar", @ptrCast(@alignCast(@constCast(FOOBAZ_TARGET))));
    try std.testing.expectError(error.Duplicate, err);
}

test "should insert a pattern with a param" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .param,
                        .value = "",
                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                        .children = &.{},
                    },
                },
            },
        },
    }, &root);
}

test "should insert a pattern with multiple params" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/abc/:baz", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .param,
                        .value = "",
                        .target = null,
                        .children = &.{
                            &.{
                                .type = .static,
                                .value = "/abc/",
                                .target = null,
                                .children = &.{
                                    &.{
                                        .type = .param,
                                        .value = "",
                                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                                        .children = &.{},
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }, &root);
}

test "should insert a pattern with multiple consecutive params" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/:bar/:baz", @ptrCast(@alignCast(FOOBAR_TARGET)));
    comptime try expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .param,
                        .value = "",
                        .target = null,
                        .children = &.{
                            &.{
                                .type = .static,
                                .value = "/",
                                .target = null,
                                .children = &.{
                                    &.{
                                        .type = .param,
                                        .value = "",
                                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                                        .children = &.{},
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }, &root);
}

test "should insert multiple patterns with overlapping params" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/:bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    comptime try insert(&root, "foo/:baz/abc", @ptrCast(@alignCast(FOOBAZ_TARGET)));
    comptime try expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .param,
                        .value = "",
                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                        .children = &.{
                            &.{
                                .type = .static,
                                .value = "/abc",
                                .target = @ptrCast(@alignCast(FOOBAZ_TARGET)),
                                .children = &.{},
                            },
                        },
                    },
                },
            },
        },
    }, &root);
}

test "should reject duplicate pattern with param irregardles of the name" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/:bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const err = comptime insert(&root, "foo/:baz", @ptrCast(@alignCast(FOOBAZ_TARGET)));
    try std.testing.expectError(error.Duplicate, err);
}

test "should insert a root pattern with a wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .wildcard,
                .value = "",
                .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                .children = &.{},
            },
        },
    }, &root);
}

test "should insert a pattern with a wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    comptime try expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .wildcard,
                        .value = "",
                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                        .children = &.{},
                    },
                },
            },
        },
    }, &root);
}

test "should insert multiple patterns with a wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    comptime try insert(&root, "bar/*", @ptrCast(@alignCast(FOOBAZ_TARGET)));
    comptime try expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .wildcard,
                        .value = "",
                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                        .children = &.{},
                    },
                },
            },
            &.{
                .type = .static,
                .value = "bar/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .wildcard,
                        .value = "",
                        .target = @ptrCast(@alignCast(FOOBAZ_TARGET)),
                        .children = &.{},
                    },
                },
            },
        },
    }, &root);
}

test "should insert a pattern with params and wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    comptime try insert(&root, "foo/:bar/abc/:baz/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    comptime try expectTrie(&.{
        .type = .static,
        .value = "/",
        .target = null,
        .children = &.{
            &.{
                .type = .static,
                .value = "foo/",
                .target = null,
                .children = &.{
                    &.{
                        .type = .param,
                        .value = "",
                        .target = null,
                        .children = &.{
                            &.{
                                .type = .static,
                                .value = "/abc/",
                                .target = null,
                                .children = &.{
                                    &.{
                                        .type = .param,
                                        .value = "",
                                        .target = null,
                                        .children = &.{
                                            &.{
                                                .type = .static,
                                                .value = "/",
                                                .target = null,
                                                .children = &.{
                                                    &.{
                                                        .type = .wildcard,
                                                        .value = "",
                                                        .target = @ptrCast(@alignCast(FOOBAR_TARGET)),
                                                        .children = &.{},
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }, &root);
}

test "should reject a pattern with a wildcard in the middle" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    const err = comptime insert(&root, "foo/*/bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try std.testing.expectError(error.Unsupported, err);
}

test "should reject a pattern with a duplicate wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const err = comptime insert(&root, "foo/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try std.testing.expectError(error.Duplicate, err);
}

test "should match root pattern" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.oneOrMore, &root, "");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should match a static pattern" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.zeroOrMore, &root, "foo/bar");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should match a pattern with a param" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    var target = comptime matchPath(.zeroOrMore, &root, "foo/bar");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
    target = comptime matchPath(.zeroOrMore, &root, "foo/baz");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should match a pattern with multiple params" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/abc/:baz/123", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.zeroOrMore, &root, "foo/boo/abc/ccc/123");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should fail to match a pattern with a param" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.zeroOrMore, &root, "foo/bar/123");
    try std.testing.expectEqual(null, target);
}

test "should fail to match a pattern with multiple params" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/abc/:baz/123", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.zeroOrMore, &root, "foo/boo/abc/123");
    try std.testing.expectEqual(null, target);
}

test "should match a pattern with a zeroOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    var target = comptime matchPath(.zeroOrMore, &root, "foo/bar");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
    target = comptime matchPath(.zeroOrMore, &root, "foo/bar/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should match a pattern with a param and zeroOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    var target = comptime matchPath(.zeroOrMore, &root, "foo/bar");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
    target = comptime matchPath(.zeroOrMore, &root, "foo/bar/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should match a pattern with a oneOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.oneOrMore, &root, "foo/bar/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should fail to match a pattern with a oneOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.oneOrMore, &root, "foo/bar");
    try std.testing.expectEqual(null, target);
}

test "should match a pattern with a param and oneOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.oneOrMore, &root, "foo/bar/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
}

test "should fail to match a pattern with a param and oneOrMore wildcard" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/:bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    const target = comptime matchPath(.oneOrMore, &root, "foo/bar");
    try std.testing.expectEqual(null, target);
}

test "should match nodes in order of priority (static, param, wildcard)" {
    const FOOBAR_TARGET: *const [6]u8 = "foobar";
    const FOOBAZ_TARGET: *const [6]u8 = "foobaz";
    const FOOBOO_TARGET: *const [6]u8 = "fooboo";
    const FOOBAA_TARGET: *const [6]u8 = "foobaa";
    comptime var root: Node = .root;
    try comptime insert(&root, "foo/bar/*", @ptrCast(@alignCast(FOOBAR_TARGET)));
    try comptime insert(&root, "foo/bar/baz/*", @ptrCast(@alignCast(FOOBAZ_TARGET)));
    try comptime insert(&root, "foo/bar/:baz", @ptrCast(@alignCast(FOOBOO_TARGET)));
    try comptime insert(&root, "foo/bar/baa/123/456", @ptrCast(@alignCast(FOOBAA_TARGET)));
    var target = comptime matchPath(.oneOrMore, &root, "foo/bar/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAR_TARGET))), target);
    target = comptime matchPath(.oneOrMore, &root, "foo/bar/baz/anything/else/here");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAZ_TARGET))), target);
    target = comptime matchPath(.oneOrMore, &root, "foo/bar/boo");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBOO_TARGET))), target);
    target = comptime matchPath(.oneOrMore, &root, "foo/bar/baa/123/456");
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(@alignCast(FOOBAA_TARGET))), target);
}
