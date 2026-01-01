const std = @import("std");
const Socket = @import("../socket.zig");
const cfg = @import("../cfg/root.zig");

pub fn Server(comptime spec: anytype) type {
    comptime validateSpec(spec);
    return struct {
        pub const Spec = spec;

        pub const StartOpts = struct {
            listen: []const u8,
        };

        pub fn start(config: anytype) !Instance {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            return Instance.init(.{ .listen = listen });
        }

        pub const Instance = struct {
            const Self = @This();

            socket: Socket,

            pub const InitError = error{
                MissingHost,
                MissingPort,
                InvalidHost,
                MalformedUri,
            } || Socket.BindError || std.posix.SocketError || std.fmt.ParseIntError;

            pub fn init(opts: StartOpts) InitError!Self {
                var it = std.mem.splitScalar(u8, opts.listen, ':');
                const host = it.next();
                const portStr = it.next();
                if (host == null) return error.MissingHost;
                if (portStr == null) return error.MissingPort;
                if (it.next() != null) return error.MalformedUri;
                const port = try std.fmt.parseInt(u16, portStr.?, 10);
                const ip = std.Io.net.IpAddress.parse(host.?, port) catch return error.InvalidHost;
                var socket = try Socket.init();
                errdefer socket.deinit();
                try socket.bind(&ip);
                return .{
                    .socket = socket,
                };
            }

            pub fn stop(self: *Self) void {
                self.socket.deinit();
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
    const isArrayPtrStr = isSinglePtr and @typeInfo(listenTypeInfo.pointer.child) == .array and @typeInfo(listenTypeInfo.pointer.child).array.child == u8;
    const isStr = isSliceStr or isArrayPtrStr;
    if (!isStr and !cfg.ref.isRef(spec.listen)) {
        @compileError("TCP server spec .listen must be a string or cfg.ref.Reference(), got " ++ @typeName(ListenType));
    }
}
