const std = @import("std");
const RequestHandler = @import("../server.zig").RequestHandler;
const Request = @import("../request.zig");

pub const MethodHandlers = blk: {
    const methods = std.meta.fields(Request.Method);
    var fieldNames: []const []const u8 = &.{};
    var fieldTypes: [methods.len]type = .{?RequestHandler} ** methods.len;
    const default: ?*const anyopaque = null;
    var fieldAttrs: [methods.len]std.builtin.Type.StructField.Attributes = .{
        std.builtin.Type.StructField.Attributes{ .default_value_ptr = @ptrCast(@alignCast(&default)) },
    } ** methods.len;
    for (methods) |method| fieldNames = fieldNames ++ &[_][]const u8{method.name};
    break :blk @Struct(.auto, null, fieldNames, &fieldTypes, &fieldAttrs);
};

pattern: []const u8,
handlers: MethodHandlers,
