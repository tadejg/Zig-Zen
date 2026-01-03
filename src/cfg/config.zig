const std = @import("std");
const env = @import("env.zig");
const ref = @import("reference.zig");

pub fn Config(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Config spec must be a struct");
    return struct {
        pub const Spec = T;
        pub const lazy: ref.References(Spec) = .{};

        pub fn loadEnv(allocator: std.mem.Allocator) env.LoadValueError!Instance {
            return .{ .value = try env.loadEnv(Spec, allocator), .isAlloc = true };
        }

        pub fn loadEnvFile(allocator: std.mem.Allocator, envFileContent: []const u8) !Instance {
            _ = allocator;
            _ = envFileContent;
            @compileError("Unimplemented");
        }

        pub fn loadJson(allocator: std.mem.Allocator, json: []const u8) !Instance {
            _ = allocator;
            _ = json;
            @compileError("Unimplemented");
        }

        pub fn static(value: Spec) Instance {
            return .{ .value = value, .isAlloc = false };
        }

        pub const Instance = struct {
            value: Spec,
            isAlloc: bool,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                if (self.isAlloc) deinitValue(allocator, self.value);
            }
        };
    };
}

fn deinitValue(allocator: std.mem.Allocator, value: anytype) void {
    const typeInfo = @typeInfo(@TypeOf(value));
    switch (typeInfo) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice, .many => {
                    for (value) |v| deinitValue(allocator, v);
                    allocator.free(value);
                },
                .one => {
                    allocator.destroy(value);
                },
                .c => @compileError("C pointers aren't allowed in the config spec"),
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| deinitValue(allocator, @field(value, f.name));
        },
        .@"union" => {
            deinitValue(allocator, @field(value, @tagName(value)));
        },
        .array => {
            for (value) |v| deinitValue(allocator, v);
        },
        .optional => {
            if (value) |v| deinitValue(allocator, v);
        },
        else => {},
    }
}
