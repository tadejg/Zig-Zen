const std = @import("std");
const RequestHandler = @import("../server.zig").RequestHandler;
const Request = @import("../request.zig");

pub const MethodHandlers = blk: {
    const methods = std.meta.fields(Request.Method);
    var fieldNames: []const []const u8 = &.{};
    const default: ?*const anyopaque = null;
    for (methods) |method| fieldNames = fieldNames ++ &[_][]const u8{method.name};
    break :blk @Struct(
        .auto,
        null,
        fieldNames,
        &@splat(?RequestHandler),
        &@splat(.{ .default_value_ptr = @ptrCast(@alignCast(&default)) }),
    );
};

pattern: []const u8,
handlers: MethodHandlers,
