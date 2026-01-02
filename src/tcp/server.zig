const std = @import("std");
const zio = @import("../zio/root.zig");
const cfg = @import("../cfg/root.zig");

pub fn Server(comptime spec: anytype) type {
    comptime validateSpec(spec);
    return struct {
        pub const Spec = spec;

        pub const StartOpts = struct {
            listen: []const u8,
            reactor: *zio.Reactor,
        };

        /// The instance needs a stable pointer as it registers it with the reactor for event notifications
        pub fn start(instance: *Instance, config: anytype, reactor: *zio.Reactor) !void {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            try instance.init(.{ .listen = listen, .reactor = reactor });
        }

        pub const Instance = struct {
            const Self = @This();

            handler: zio.Reactor.Handler = .{ .extra = null, .callback = handleSocketEvent },
            socket: zio.Socket = .{ .fd = -1 },

            pub const InitError = error{
                MissingHost,
                MissingPort,
                InvalidHost,
                MalformedUri,
            } || zio.Socket.BindError || zio.Socket.ListenError || std.posix.SocketError || std.fmt.ParseIntError || zio.Reactor.AddSocketError;

            pub fn init(self: *Self, opts: StartOpts) InitError!void {
                var it = std.mem.splitScalar(u8, opts.listen, ':');
                const host = it.next();
                const portStr = it.next();
                if (host == null) return error.MissingHost;
                if (portStr == null) return error.MissingPort;
                if (it.next() != null) return error.MalformedUri;
                const port = try std.fmt.parseInt(u16, portStr.?, 10);
                const ip = std.Io.net.IpAddress.parse(host.?, port) catch return error.InvalidHost;
                self.socket = try zio.Socket.init();
                errdefer self.socket.deinit();
                try self.socket.bind(&ip);
                try self.socket.listen(128); // TODO configurable backlog
                self.handler.extra = self;
                try opts.reactor.addSocket(self.socket, &self.handler);
            }

            pub fn stop(self: *Self, reactor: *zio.Reactor) void {
                reactor.removeSocket(self.socket) catch {
                    // TODO log
                };
                self.socket.deinit();
            }

            fn handleSocketEvent(extra: ?*anyopaque, event: zio.Reactor.Handler.Event) void {
                const self: *Self = @ptrCast(@alignCast(extra.?));
                _ = self;
                _ = event; // TODO
            }
        };
    };
}

fn validateSpec(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    if (!@hasField(SpecType, "listen")) @compileError("TCP server spec missing .listen");
    const ListenType = @TypeOf(spec.listen);
    const listenTypeInfo = @typeInfo(ListenType);
    const isSlice = listenTypeInfo == .pointer and listenTypeInfo.pointer.size == .slice;
    const isSliceStr = isSlice and listenTypeInfo.pointer.child == u8;
    const isSinglePtr = listenTypeInfo == .pointer and listenTypeInfo.pointer.size == .one;
    const isArrayPtrStr = isSinglePtr and blk: {
        const childTypeInfo = @typeInfo(listenTypeInfo.pointer.child);
        break :blk childTypeInfo == .array and childTypeInfo.array.child == u8;
    };
    const isStr = isSliceStr or isArrayPtrStr;
    if (!isStr and !cfg.ref.isRef(spec.listen)) {
        @compileError("TCP server spec .listen must be a string or cfg.ref.Reference(), got " ++ @typeName(ListenType));
    }
}
