const std = @import("std");

/// Spec is assumed to be a struct type
pub fn loadEnv(comptime Spec: type, allocator: std.mem.Allocator) LoadValueError!Spec {
    var value: Spec = undefined;
    inline for (std.meta.fields(Spec)) |field| {
        @field(value, field.name) = try loadValue(field.type, field.name, allocator);
    }
    return value;
}

pub const LoadValueError = std.process.GetEnvVarOwnedError || CoerceValueError;

fn loadValue(comptime T: type, comptime name: []const u8, allocator: std.mem.Allocator) LoadValueError!T {
    const typeInfo = @typeInfo(T);
    const value = std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => {
            if (typeInfo == .optional) return null;
            return e;
        },
        else => return e,
    };
    return try coerceValue(T, value, allocator);
}

pub const CoerceValueError = error{
    TooFewArrayElements,
    TooManyArrayElements,
    InvalidBool,
} || std.fmt.ParseIntError || std.fmt.ParseFloatError;

fn coerceValue(comptime T: type, value: []const u8, allocator: std.mem.Allocator) CoerceValueError!T {
    const typeInfo = @typeInfo(T);
    return switch (typeInfo) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .optional => |opt| try coerceValue(opt.child, value, allocator),
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
                    break :blk value;
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

fn freeValue(allocator: std.mem.Allocator, value: anytype) void {
    const ValueType = @TypeOf(value);
    switch (@typeInfo(ValueType)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                for (value) |v| freeValue(v);
                allocator.free(value);
            },
            else => @compileError("Unsupported value pointer size " ++ @tagName(ptr.size)),
        },
    }
}
