const std = @import("std");
const env = @import("env.zig");
const ref = @import("reference.zig");

pub fn Config(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Config spec must be a struct");
    return struct {
        pub const Spec = T;
        pub const lazy: ref.References(Spec) = .{};

        pub const Instance = struct {
            value: Spec,
            isAlloc: bool,
        };
    };
}

pub inline fn isConfigType(comptime T: type) bool {
    return @hasDecl(T, "Spec") and @hasDecl(T, "lazy");
}

pub fn Loaded(comptime T: type) type {
    if (isConfigType(T)) return T.Instance;
    @compileError("Not a config type");
}

pub fn loadEnv(comptime T: type, allocator: std.mem.Allocator) env.LoadValueError!Loaded(T) {
    return .{ .value = try env.loadEnv(T.Spec, allocator), .isAlloc = true };
}

pub const LoadDotEnvError = error{Unimplemented};

pub fn loadDotEnv(
    comptime T: type,
    allocator: std.mem.Allocator,
    envFileContent: []const u8,
) LoadDotEnvError!Loaded(T) {
    _ = allocator;
    _ = envFileContent;
    return error.Unimplemented;
}

pub const LoadJsonError = error{Unimplemented};

pub fn loadJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    json: []const u8,
) LoadJsonError!Loaded(T) {
    _ = allocator;
    _ = json;
    return error.Unimplemented;
}

pub fn static(comptime T: type, value: T.Spec) Loaded(T) {
    return .{ .value = value, .isAlloc = false };
}

pub fn deinit(comptime T: type, allocator: std.mem.Allocator, instance: Loaded(T)) void {
    if (instance.isAlloc) deinitValue(T.Spec, allocator, instance.value);
}

fn deinitValue(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice, .many => {
                    for (value) |v| deinitValue(ptr.child, allocator, v);
                    allocator.free(value);
                },
                .one => {
                    const childInfo = @typeInfo(ptr.child);
                    if (childInfo != .@"opaque" and childInfo != .@"fn") {
                        allocator.destroy(value);
                    }
                },
                .c => @compileError("C pointers aren't allowed in the config spec"),
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| deinitValue(f.type, allocator, @field(value, f.name));
        },
        .@"union" => {
            deinitValue(@FieldType(T, @tagName(value)), allocator, @field(value, @tagName(value)));
        },
        .array => |arr| {
            for (value) |v| deinitValue(arr.child, allocator, v);
        },
        .optional => |opt| {
            if (value) |v| deinitValue(opt.child, allocator, v);
        },
        else => {},
    }
}

test Config {
    // Describe the shape
    const Conf = Config(struct { abc: u32 });
    // Load from your favorite source
    var cfg = static(Conf, .{ .abc = 42 });
    defer deinit(Conf, std.testing.allocator, cfg); // Required for some sources (optional for .static())
    // Use the loaded values
    try std.testing.expectEqual(42, cfg.value.abc);
}
