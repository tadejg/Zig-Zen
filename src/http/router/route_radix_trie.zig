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
const Route = @import("route.zig");

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

    pub const Type = enum {
        static,
        param,
        wildcard,
    };
};

pub fn RouteRadixTrie(comptime routes: []const Route) type {
    comptime var _root: Node = .root;
    inline for (routes) |*r| comptime addRoute(&_root, r);
    return struct {
        const Self = @This();
        const root: *const Node = &_root;

        pub const init: Self = .{};

        pub fn match(self: *const Self, path: []const u8) ?*anyopaque {
            _ = self;
            _ = path;
            return null;
        }
    };
}

fn insert(
    comptime node: *Node,
    comptime pattern: []const u8,
    comptime target: ?*const anyopaque,
) error{ Duplicate, Unsupported }!void {
    comptime var nextParamIdx: ?comptime_int = null;
    const wildcardIdx: comptime_int = std.mem.findScalarPos(u8, pattern, 0, '*') orelse pattern.len;
    if (wildcardIdx < pattern.len - 1) return error.Unsupported;
    if (pattern.len > 0 and pattern[0] == ':') {
        nextParamIdx = 0;
    } else if (std.mem.findPos(u8, pattern, 0, "/:")) |i| {
        nextParamIdx = i + 1;
    }
    const nextParamEnd: comptime_int = if (nextParamIdx) |n| blk: {
        break :blk std.mem.findScalarPos(u8, pattern, n, '/') orelse pattern.len;
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
    node.children = node.children ++ &[_]*Node{&newNode};
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

fn addRoute(comptime root: *Node, comptime route: *const Route) void {
    const normalizedPattern = std.mem.trim(u8, route.pattern, &(std.ascii.whitespace ++ .{'/'}));
    insert(root, normalizedPattern, @ptrCast(@alignCast(route.handler))) catch {
        @compileError("Duplicate route pattern: \"" ++ route.pattern ++ "\"");
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

test addRoute {
    const Request = @import("../request.zig");
    const Response = @import("../response.zig");
    comptime var root: Node = .root;
    const barHandler = struct {
        fn handler(_: *const Request) !Response {
            return .{ .statusCode = .ok };
        }
    }.handler;
    comptime addRoute(&root, &Route{
        .method = .unknown,
        .pattern = "/foo/bar",
        .handler = barHandler,
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
    comptime addRoute(&root, &Route{
        .method = .unknown,
        .pattern = "/foo/baz",
        .handler = bazHandler,
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
