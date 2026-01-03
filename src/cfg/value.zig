const std = @import("std");

pub const CoerceValueError = error{
    TooFewArrayElements,
    TooManyArrayElements,
    InvalidBool,
} || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.mem.Allocator.Error;

pub fn coerceValue(comptime T: type, value: []const u8, allocator: std.mem.Allocator) CoerceValueError!T {
    const typeInfo = @typeInfo(T);
    return switch (typeInfo) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .optional => |opt| blk: {
            if (std.ascii.eqlIgnoreCase(value, "null") or std.mem.trim(u8, value, &std.ascii.whitespace).len == 0) {
                break :blk null;
            }
            break :blk try coerceValue(opt.child, value, allocator);
        },
        .bool => blk: {
            if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) {
                break :blk true;
            } else if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) {
                break :blk false;
            } else {
                return error.InvalidBool;
            }
        },
        .array => |a| blk: {
            var out = [_]a.child{undefined} ** a.len;
            var it = std.mem.splitScalar(u8, value, ',');
            for (0..out.len) |i| {
                const v = it.next();
                if (v == null) return error.TooFewArrayElements;
                errdefer for (0..i) |j| freeValue(allocator, out[j]);
                out[i] = try coerceValue(a.child, v.?, allocator);
            }
            if (it.next() != null) return error.TooManyArrayElements;
            break :blk out;
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => blk: {
                // TODO Allow slices of u8 ints instead of strings
                if (ptr.child == u8) { // Special case for strings
                    break :blk try allocator.dupe(u8, value);
                }
                var list: std.ArrayList(ptr.child) = .empty;
                defer list.deinit(allocator);
                errdefer for (list.items) |item| freeValue(allocator, item);
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |v| {
                    const coerced = try coerceValue(ptr.child, v, allocator);
                    errdefer freeValue(allocator, coerced);
                    try list.append(allocator, coerced);
                }
                break :blk list.toOwnedSlice(allocator);
            },
            else => @compileError("Unsupported Spec field pointer size " ++ @tagName(ptr.size)),
        },
        else => @compileError("Unsupported Spec field type " ++ @typeName(T)),
    };
}

pub fn freeValue(allocator: std.mem.Allocator, value: anytype) void {
    const ValueType = @TypeOf(value);
    switch (@typeInfo(ValueType)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                for (value) |v| freeValue(allocator, v);
                allocator.free(value);
            },
            else => @compileError("Unsupported value pointer size " ++ @tagName(ptr.size)),
        },
        else => {},
    }
}

pub fn isAnyStr(comptime T: type) bool {
    const typeInfo = @typeInfo(T);
    if (typeInfo == .optional) return isAnyStr(typeInfo.optional.child);
    return typeInfo == .pointer and typeInfo.pointer.size == .slice and typeInfo.pointer.child == u8;
}

test coerceValue {
    const allocator = std.testing.allocator;
    // Strings
    {
        const out = try coerceValue([]const u8, "foobar", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqualStrings("foobar", out);
    }
    // Numbers
    {
        const out = try coerceValue(u32, "42", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqual(42, out);
    }
    {
        const out = try coerceValue(f64, "3.14159", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqual(3.14159, out);
    }
    // Arrays
    {
        const out = try coerceValue([3]f32, "1,2,3", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqualDeep([_]f32{ 1, 2, 3 }, out);
    }
    // Slices
    {
        const out = try coerceValue([]u32, "1,2,3", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqualDeep(&[_]u32{ 1, 2, 3 }, out);
    }
    // Optional
    {
        const out = try coerceValue(?u32, "42", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqual(42, out);
    }
    {
        const out = try coerceValue(?u32, "null", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqual(null, out);
    }
    {
        const out = try coerceValue(?u32, "", allocator);
        defer freeValue(allocator, out);
        try std.testing.expectEqual(null, out);
    }
}

test isAnyStr {
    // Strings
    try std.testing.expect(comptime isAnyStr([]u8));
    try std.testing.expect(comptime isAnyStr([]const u8));
    try std.testing.expect(comptime isAnyStr(?[]u8));
    try std.testing.expect(comptime isAnyStr(?[]const u8));
    // Not strings
    try std.testing.expect(!comptime isAnyStr(*[]u8));
    try std.testing.expect(!comptime isAnyStr(*[3]u8));
}
