const std = @import("std");
const Request = @import("../request.zig");
const Response = @import("../response.zig");
const Route = @import("route.zig");
const RequestHandler = @import("../server.zig").RequestHandler;
const RouteRadixTrie = @import("route_radix_trie.zig");

pub fn ParamRouter(comptime spec: anytype) type {
    comptime validateSpec(spec);
    return struct {
        const Self = @This();

        pub const trie: RouteRadixTrie(spec.routes) = .init;

        pub fn handleRequest(req: *const Request) !Response {
            const handlerPtr = trie.match(req.path);
            if (handlerPtr == null) return .{ .statusCode = .notFound };
            const handler: RequestHandler = @ptrCast(@alignCast(handlerPtr.?));
            return handler(req);
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
