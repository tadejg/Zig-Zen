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

        pub const LoadDotEnvError = error{};

        pub fn loadDotEnv(allocator: std.mem.Allocator, envFileContent: []const u8) LoadDotEnvError!Instance {
            _ = allocator;
            _ = envFileContent;
            @compileError("Unimplemented");
        }

        pub const LoadJsonError = error{};

        pub fn loadJson(allocator: std.mem.Allocator, json: []const u8) LoadJsonError!Instance {
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

test Config {
    // Describe the shape
    const Conf = Config(struct { abc: u32 });
    // Load from your favorite source
    var cfg = Conf.static(.{ .abc = 42 });
    defer cfg.deinit(std.testing.allocator); // Required for some sources (optional for .static())
    // Use the loaded values
    try std.testing.expectEqual(42, cfg.value.abc);
}
