const std = @import("std");
const zio = @import("zio/root.zig");

fn ServerInstances(comptime tuple: anytype) type {
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

pub fn AppInstance(comptime AppType: type) type {
    return struct {
        pub const App = AppType;
        running: std.atomic.Value(bool) = .init(true),
        reactor: zio.Reactor,
        servers: ServerInstances(App.Spec.servers),
    };
}

pub const StartInstanceError = std.Io.ConcurrentError || zio.Reactor.InitError;

fn startInstance(
    comptime App: type,
    io: std.Io,
    ioGroup: *std.Io.Group,
    config: anytype,
    instance: *AppInstance(App),
) !void { // TODO Return `StartInstanceError!void` after server start() is updated to have a consistent interface
    instance.* = .{
        .reactor = try zio.Reactor.init(io),
        .servers = undefined,
    };
    errdefer instance.reactor.deinit();
    var numStarted: u32 = 0;
    errdefer inline for (&instance.servers, 0..) |*s, i| {
        if (i < numStarted) s.stop(&instance.reactor);
    };
    inline for (App.Spec.servers, 0..) |s, i| {
        try s.start(io, &instance.servers[i], config, &instance.reactor);
        numStarted += 1;
    }
    try ioGroup.concurrent(io, zio.Reactor.run, .{&instance.reactor});
}

fn stopInstance(comptime App: type, instance: *AppInstance(App)) void {
    if (!instance.running.rmw(.Xchg, false, .monotonic)) return;
    inline for (&instance.servers) |*s| {
        s.stop(&instance.reactor);
    }
    instance.reactor.deinit();
}

pub const RunOptions = struct {
    /// Determines how many I/O reactors and app instances are started concurrently. Each worker gets its own event
    /// loop, listening sockets, etc. ioWorkers > 1 requires listening sockets to use SO_REUSEPORT.
    /// Must be >= 1
    ioWorkers: u32 = 1,
};

pub const RunError = error{InvalidArgument} || StartInstanceError;

pub fn run(
    comptime App: type,
    io: std.Io,
    ioGroup: *std.Io.Group,
    config: anytype,
    /// `instances` must be at least `opts.ioWorkers` long
    instances: []AppInstance(App),
    opts: RunOptions,
) !void { // TODO Return `RunError!void`; see startInstance() TODO
    if (opts.ioWorkers < 1 or opts.ioWorkers > instances.len) {
        return error.InvalidArgument;
    }
    var numStarted: u32 = 0;
    errdefer for (0..numStarted) |i| {
        stopInstance(App, &instances[i]);
    };
    for (0..opts.ioWorkers) |i| {
        try startInstance(App, io, ioGroup, config, &instances[i]);
        numStarted += 1;
    }
}

/// Caller must guarantee all instances in the slice are instantiated i.e. not undefined
pub fn stop(comptime App: type, instances: []AppInstance(App)) void {
    for (instances) |*instance| stopInstance(App, instance);
}
