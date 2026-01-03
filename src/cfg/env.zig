const std = @import("std");
const val = @import("value.zig");

/// Spec is assumed to be a struct type
pub fn loadEnv(comptime Spec: type, allocator: std.mem.Allocator) LoadValueError!Spec {
    var value: Spec = undefined;
    inline for (std.meta.fields(Spec)) |field| {
        @field(value, field.name) = try loadValue(field.type, field.name, allocator);
    }
    return value;
}

pub const LoadValueError = std.process.GetEnvVarOwnedError || val.CoerceValueError;

fn loadValue(comptime T: type, comptime name: []const u8, allocator: std.mem.Allocator) LoadValueError!T {
    const typeInfo = @typeInfo(T);
    const value = std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => {
            if (typeInfo == .optional) return null;
            return e;
        },
        else => return e,
    };
    defer if (val.isAnyStr(T)) {
        if (typeInfo == .optional) {
            if (value) |v| allocator.free(v);
        } else {
            allocator.free(value);
        }
    };
    return try val.coerceValue(T, value, allocator);
}
