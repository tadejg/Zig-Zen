const std = @import("std");
const zio = @import("../zio/root.zig");
const cfg = @import("../cfg/root.zig");

pub const HandleConnectionCallback = *const fn (extra: ?*anyopaque, socket: zio.Socket, ip: std.Io.net.IpAddress) void;

pub fn Server(comptime spec: anytype) type {
    comptime validateSpec(spec);
    return struct {
        pub const Spec = spec;

        /// The instance needs a stable pointer as it registers it with the reactor for event notifications
        pub fn start(
            _: std.Io,
            _: *std.Io.Group,
            instance: *Instance,
            config: anytype,
            reactor: *zio.Reactor,
        ) Instance.InitError!void {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            try instance.init(.{ .listen = listen, .reactor = reactor });
        }

        pub const Instance = struct {
            const Self = @This();

            pub const StartOpts = struct {
                listen: []const u8,
                reactor: *zio.Reactor,
            };

            handler: zio.Reactor.Handler = .{ .extra = null, .callback = handleSocketEvent },
            socket: zio.Socket,
            handleConnectionExtra: ?*anyopaque = null,

            const InitZioSocketError = zio.Socket.BindError || zio.Socket.ListenError;
            pub const InitError = error{
                MissingHost,
                MissingPort,
                InvalidHost,
                MalformedUri,
            } || InitZioSocketError || std.posix.SocketError || std.fmt.ParseIntError || zio.Reactor.AddSocketError;

            pub fn init(self: *Self, opts: StartOpts) InitError!void {
                var it = std.mem.splitScalar(u8, opts.listen, ':');
                const host = it.next();
                const portStr = it.next();
                if (host == null) return error.MissingHost;
                if (portStr == null) return error.MissingPort;
                if (it.next() != null) return error.MalformedUri;
                const port = try std.fmt.parseInt(u16, portStr.?, 10);
                const ip = std.Io.net.IpAddress.parse(host.?, port) catch return error.InvalidHost;
                self.* = .{ .socket = try zio.Socket.init(std.meta.activeTag(ip)) };
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
                self.setHandleConnectionExtra(null);
            }

            pub fn setHandleConnectionExtra(self: *Self, extra: ?*anyopaque) void {
                self.handleConnectionExtra = extra;
            }

            const AcceptClientError = zio.Socket.AcceptError;

            fn acceptClient(self: *Self) AcceptClientError!void {
                var ip: std.Io.net.IpAddress = undefined;
                const clientSocket = try self.socket.accept(&ip);
                spec.handleConnection(self.handleConnectionExtra, clientSocket, ip);
            }

            fn handleSocketEvent(extra: ?*anyopaque, event: zio.Reactor.Handler.Event) void {
                const self: *Self = @ptrCast(@alignCast(extra.?));
                switch (event) {
                    .read => {
                        loop: while (true) {
                            self.acceptClient() catch |e| switch (e) {
                                error.WouldBlock => break :loop,
                                else => {
                                    // TODO log error
                                },
                            };
                        }
                    },
                    else => {
                        // TODO log unexpected event
                    },
                }
            }
        };
    };
}

fn validateListen(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    if (!@hasField(SpecType, "listen")) @compileError("TCP server spec missing .listen");
    const Type = @TypeOf(spec.listen);
    const typeInfo = @typeInfo(Type);
    const isSlice = typeInfo == .pointer and typeInfo.pointer.size == .slice;
    const isSliceStr = isSlice and typeInfo.pointer.child == u8;
    const isSinglePtr = typeInfo == .pointer and typeInfo.pointer.size == .one;
    const isArrayPtrStr = isSinglePtr and blk: {
        const childTypeInfo = @typeInfo(typeInfo.pointer.child);
        break :blk childTypeInfo == .array and childTypeInfo.array.child == u8;
    };
    const isStr = isSliceStr or isArrayPtrStr;
    if (!isStr and !cfg.ref.isRef(spec.listen)) {
        @compileError("TCP server spec .listen must be a string or cfg.ref.Reference(), got " ++ @typeName(Type));
    }
}

fn validateHandleConnection(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    if (!@hasField(SpecType, "handleConnection")) @compileError("TCP server spec missing .handleConnection");
    const CallbackFnType = @typeInfo(HandleConnectionCallback).pointer.child;
    const Type = @TypeOf(spec.handleConnection);
    if (Type != HandleConnectionCallback and Type != CallbackFnType) {
        @compileError("TCP server .handleConnection type doesn't match " ++ @typeName(HandleConnectionCallback));
    }
}

fn validateSpec(comptime spec: anytype) void {
    validateListen(spec);
    validateHandleConnection(spec);
}
