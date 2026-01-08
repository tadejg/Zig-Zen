const std = @import("std");
const Request = @import("../request.zig");
const Response = @import("../response.zig");
const Route = @import("route.zig");
const RequestHandler = @import("../server.zig").RequestHandler;
const RouteRadixTrie = @import("route_radix_trie.zig").RouteRadixTrie;
const route_radix_trie = @import("route_radix_trie.zig");

fn trieRoutesFromSpec(comptime routes: []const Route) []const route_radix_trie.RouteSpec {
    comptime var out: []const route_radix_trie.RouteSpec = &.{};
    inline for (routes) |r| {
        out = out ++ &[_]route_radix_trie.RouteSpec{.{ .pattern = r.pattern, .target = &r.handlers }};
    }
    return out;
}

pub fn ParamRouter(comptime spec: anytype, comptime wildcardMode: route_radix_trie.WildcardMode) type {
    comptime validateSpec(spec);
    return struct {
        const Self = @This();

        pub const Trie = RouteRadixTrie(trieRoutesFromSpec(&spec.routes), wildcardMode);

        pub fn handleRequest(req: *const Request, res: *Response) !void {
            res.statusCode = .notFound;
            const handlerPtr = Trie.match(req.path);
            if (handlerPtr == null) return;
            const handlers: *const Route.MethodHandlers = @ptrCast(@alignCast(handlerPtr.?));
            const activeTag = @intFromEnum(req.method);
            inline for (std.meta.fields(Request.Method)) |field| {
                if (activeTag == field.value) {
                    if (@field(handlers, field.name)) |handler| {
                        return handler(req, res);
                    } else return;
                }
            }
        }
    };
}

fn validateSpec(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    if (!@hasField(SpecType, "routes")) @compileError("ParamRouter spec missing field .routes");
    const typeInfo = @typeInfo(@TypeOf(spec.routes));
    if (typeInfo != .array and typeInfo.array.child != Route) {
        @compileError("ParamRouter spec .routes must be an array of Route");
    }
}
