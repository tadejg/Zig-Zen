const std = @import("std");
const zio = @import("../zio/root.zig");
const cfg = @import("../cfg/root.zig");
const tcp = @import("../tcp/root.zig");
const Request = @import("request.zig");

pub const ClientBuffers = struct {
    readBuffer: Buffer,
    writeBuffer: Buffer,

    pub const Buffer = struct {
        data: []u8,
        freeStack: []u32,
        chunkSize: u32,
    };
};

pub const Connection = struct {
    socket: zio.Socket,
    ip: std.Io.net.IpAddress,
    readBuffer: []u8,
    writeBuffer: []u8,
    writeBufferStart: usize = 0,
    writeBufferEnd: usize = 0,
    handler: zio.Reactor.Handler,
    server: *anyopaque,
    node: std.SinglyLinkedList.Node = .{},
    req: Request = .{},
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
        pub fn start(_: std.Io, instance: *Instance, config: anytype, reactor: *zio.Reactor) !void {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            const buffers: ClientBuffers = cfg.ref.resolveIfRef(spec.buffers, config.value);
            const connectionPool: []Connection = cfg.ref.resolveIfRef(spec.connectionPool, config.value);
            try instance.init(.{
                .listen = listen,
                .reactor = reactor,
                .buffers = buffers,
                .connectionPool = connectionPool,
            });
        }

        pub const Instance = struct {
            const Self = @This();

            pub const StartOpts = struct {
                listen: []const u8,
                reactor: *zio.Reactor,
                buffers: ClientBuffers,
                connectionPool: []Connection,
            };

            server: TcpServer.Instance,
            reactor: *zio.Reactor,
            readBuffer: zio.FixedBufferPool,
            writeBuffer: zio.FixedBufferPool,
            maxConnections: u32,
            connectionPool: []Connection,
            freeConnectionList: std.SinglyLinkedList = .{},

            pub const InitError = zio.FixedBufferPool.InitError || TcpServer.Instance.InitError;

            pub fn init(self: *Self, opts: StartOpts) InitError!void {
                const readBuffer = try zio.FixedBufferPool.init(
                    opts.buffers.readBuffer.data,
                    opts.buffers.readBuffer.freeStack,
                    opts.buffers.readBuffer.chunkSize,
                );
                const writeBuffer = try zio.FixedBufferPool.init(
                    opts.buffers.writeBuffer.data,
                    opts.buffers.writeBuffer.freeStack,
                    opts.buffers.writeBuffer.chunkSize,
                );
                const maxConns = @min(@min(opts.connectionPool.len, readBuffer.numChunks), writeBuffer.numChunks);
                self.* = .{
                    .reactor = opts.reactor,
                    .readBuffer = readBuffer,
                    .writeBuffer = writeBuffer,
                    .connectionPool = opts.connectionPool,
                    .maxConnections = maxConns,
                    .server = undefined,
                };
                for (self.connectionPool[0..maxConns]) |*c| {
                    c.* = .{
                        .socket = .invalid(),
                        .ip = undefined,
                        .readBuffer = undefined,
                        .writeBuffer = undefined,
                        .handler = .{ .extra = c, .callback = handleSocketEvent },
                        .server = self,
                    };
                    self.freeConnectionList.prepend(&c.node);
                }
                try TcpServer.Instance.init(&self.server, .{
                    .listen = opts.listen,
                    .reactor = opts.reactor,
                });
                self.server.setHandleConnectionExtra(self);
            }

            pub fn stop(self: *Self, reactor: *zio.Reactor) void {
                self.server.stop(reactor);
            }

            const AcceptConnectionError = error{
                ConnectionLimitReached,
            } || zio.FixedBufferPool.AllocError || zio.Reactor.AddSocketError;

            fn acceptConnection(self: *Self, socket: zio.Socket, ip: std.Io.net.IpAddress) AcceptConnectionError!void {
                var s = socket;
                errdefer s.deinit();
                const node = self.freeConnectionList.popFirst();
                if (node == null) {
                    // TODO Log no empty connection slots
                    return error.ConnectionLimitReached;
                }
                errdefer self.freeConnectionList.prepend(node.?);
                const conn: *Connection = @fieldParentPtr("node", node.?);
                const readBuffer = try self.readBuffer.alloc();
                errdefer self.readBuffer.free(readBuffer);
                const writeBuffer = try self.readBuffer.alloc();
                errdefer self.writeBuffer.free(writeBuffer);
                conn.socket = socket;
                conn.ip = ip;
                conn.readBuffer = readBuffer;
                conn.writeBuffer = writeBuffer;
                conn.writeBufferStart = 0;
                conn.writeBufferEnd = 0;
                conn.req = .{};
                try self.reactor.addSocket(socket, &conn.handler);
            }

            fn closeConnection(self: *Self, conn: *Connection) void {
                self.reactor.removeSocket(conn.socket) catch {
                    // TODO Log error
                };
                conn.socket.deinit();
                self.readBuffer.free(conn.readBuffer);
                self.writeBuffer.free(conn.writeBuffer);
                self.freeConnectionList.prepend(&conn.node);
            }

            fn handleConnection(extra: ?*anyopaque, socket: zio.Socket, ip: std.Io.net.IpAddress) void {
                const self: *Self = @ptrCast(@alignCast(extra orelse return));
                self.acceptConnection(socket, ip) catch {
                    // TODO Log error
                };
            }

            const HandleReadError = error{EndOfFile} || zio.Socket.ReadError;

            fn handleRead(_: *Self, conn: *Connection) HandleReadError!void {
                loop: while (true) {
                    const read = conn.socket.read(conn.readBuffer) catch |e| switch (e) {
                        error.WouldBlock => break :loop,
                        else => return e,
                    };
                    if (read == 0) return error.EndOfFile;
                    // TODO Update parser
                }
            }

            const HandleWriteError = zio.Socket.WriteError;

            fn handleWrite(_: *Self, conn: *Connection) HandleWriteError!void {
                // TODO While response serializer has more
                while (true) {
                    loop: while (conn.writeBufferStart < conn.writeBufferEnd) {
                        const buff = conn.writeBuffer[conn.writeBufferStart..conn.writeBufferEnd];
                        const written = conn.socket.write(buff) catch |e| switch (e) {
                            error.WouldBlock => break :loop,
                            else => return e,
                        };
                        conn.writeBufferStart += written;
                    }
                    // TODO Update serializer
                    conn.writeBufferStart = 0;
                    conn.writeBufferEnd = 0; // TODO Set based on serializer output
                }
            }

            fn handleSocketEvent(extra: ?*anyopaque, event: zio.Reactor.Handler.Event) void {
                const conn: *Connection = @ptrCast(@alignCast(extra.?));
                const self: *Self = @ptrCast(@alignCast(conn.server));
                switch (event) {
                    .read => self.handleRead(conn) catch {
                        // TODO Log error
                        self.closeConnection(conn);
                    },
                    .write => self.handleWrite(conn) catch {
                        // TODO Log error
                        self.closeConnection(conn);
                    },
                    .hangup => self.closeConnection(conn),
                    .err => {
                        // TODO Log error
                        self.closeConnection(conn);
                    },
                }
            }
        };
    };
}

fn validateSpec(comptime spec: anytype) void {
    const SpecType = @TypeOf(spec);
    {
        if (!@hasField(SpecType, "buffers")) @compileError("HTTP server spec missing .buffers");
        const FieldType = @TypeOf(spec.buffers);
        if (FieldType != ClientBuffers and !cfg.ref.isStructRefOf(spec.buffers, ClientBuffers)) {
            @compileError("HTTP server .buffers must be a ClientBuffers or a lazy config reference");
        }
    }
    {
        if (!@hasField(SpecType, "connectionPool")) @compileError("HTTP server spec missing .connectionPool");
        const FieldType = @TypeOf(spec.connectionPool);
        if (FieldType != []Connection and !cfg.ref.isRefOf(spec.connectionPool, []Connection)) {
            @compileError("HTTP server .connectionPool must be a []Connection or a lazy config reference");
        }
    }
}
