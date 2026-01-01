const std = @import("std");

pub fn run(comptime App: type, io: std.Io, config: anytype) !void {
    inline for (App.Spec.servers) |s| {
        var instance = try s.start(config);
        defer instance.stop();
    }
    _ = io;
}
