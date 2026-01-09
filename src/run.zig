const std = @import("std");
const zio = @import("zio/root.zig");

fn Instances(comptime tuple: anytype) type {
    const T = @TypeOf(tuple);
    const typeInfo = @typeInfo(T);
    if (typeInfo != .@"struct" or !typeInfo.@"struct".is_tuple) {
        @compileError("Type must be a tuple, got " ++ @typeName(T));
    }
    var fieldTypes: []const type = &.{};
    inline for (tuple) |v| {
        fieldTypes = fieldTypes ++ .{v.Instance};
    }
    return @Tuple(fieldTypes);
}

pub fn sync(comptime App: type, io: std.Io, config: anytype) !void {
    var instances: Instances(App.Spec.servers) = undefined;
    var numStarted: u32 = 0;
    var reactor = try zio.Reactor.init(io);
    defer reactor.deinit();
    defer inline for (&instances, 0..) |*v, i| {
        if (i < numStarted) v.stop(&reactor); // Avoid undefined instances
    };
    inline for (App.Spec.servers, 0..) |s, i| {
        try s.start(io, &instances[i], config, &reactor);
        numStarted += 1;
    }
    reactor.run();
}
