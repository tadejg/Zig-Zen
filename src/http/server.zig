const std = @import("std");
const zio = @import("../zio/root.zig");
const cfg = @import("../cfg/root.zig");
const tcp = @import("../tcp/root.zig");

pub const ClientBuffers = struct {
    readBuffer: Buffer,
    writeBuffer: Buffer,

    pub const Buffer = struct {
        data: []u8,
        freeStack: []u32,
        chunkSize: u32,
    };
};

pub fn Server(comptime spec: anytype) type {
    comptime validateSpec(spec);
    return struct {
        pub const Spec = spec;
        pub const TcpServer = tcp.Server(.{
            .listen = spec.listen,
            .handleConnection = Instance.handleConnection,
        });

        /// The instance needs a stable pointer as it registers it with the TCP server for event notifications
        pub fn start(instance: *Instance, config: anytype, reactor: *zio.Reactor) !void {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            const buffers: ClientBuffers = cfg.ref.resolveIfRef(spec.buffers, config.value);
            try instance.init(.{
                .listen = listen,
                .reactor = reactor,
                .buffers = buffers,
            });
        }

        pub const Instance = struct {
            const Self = @This();

            pub const StartOpts = struct {
                listen: []const u8,
                reactor: *zio.Reactor,
                buffers: ClientBuffers,
            };

            server: TcpServer.Instance,
            reactor: *zio.Reactor,
            readBuffer: zio.FixedBufferPool,
            writeBuffer: zio.FixedBufferPool,

            pub const InitError = zio.FixedBufferPool.InitError || TcpServer.Instance.InitError;

            pub fn init(self: *Self, opts: StartOpts) InitError!void {
                self.* = .{
                    .reactor = opts.reactor,
                    .readBuffer = try zio.FixedBufferPool.init(
                        opts.buffers.readBuffer.data,
                        opts.buffers.readBuffer.freeStack,
                        opts.buffers.readBuffer.chunkSize,
                    ),
                    .writeBuffer = try zio.FixedBufferPool.init(
                        opts.buffers.writeBuffer.data,
                        opts.buffers.writeBuffer.freeStack,
                        opts.buffers.writeBuffer.chunkSize,
                    ),
                    .server = undefined,
                };
                try TcpServer.Instance.init(&self.server, .{
                    .listen = opts.listen,
                    .reactor = opts.reactor,
                });
                self.server.setHandleConnectionExtra(self);
            }

            pub fn stop(self: *Self, reactor: *zio.Reactor) void {
                self.server.stop(reactor);
            }

            fn handleConnection(extra: ?*anyopaque, socket: zio.Socket, ip: std.Io.net.IpAddress) void {
                const self: *Self = @ptrCast(@alignCast(extra orelse return));
                _ = self;
                // self.reactor.addSocket(socket, handler: *Handler);
                _ = socket;
                _ = ip;
            }
        };
    };
}

fn validateSpec(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    if (!@hasField(SpecType, "buffers")) @compileError("HTTP server spec missing .buffers");
    const FieldType = @TypeOf(spec.buffers);
    if (FieldType != ClientBuffers and !cfg.ref.isStructRefOf(spec.buffers, ClientBuffers)) {
        @compileError("HTTP server .buffers must be a ClientBuffers or a lazy config reference");
    }
}
