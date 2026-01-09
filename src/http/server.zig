const std = @import("std");
const zio = @import("../zio/root.zig");
const cfg = @import("../cfg/root.zig");
const tcp = @import("../tcp/root.zig");
const Connection = @import("connection.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const RequestParser = @import("request_parser.zig");

// TODO Replace with custom logger
pub const log = std.log.scoped(.http_server);

pub const RequestHandler = *const fn (req: *const Request, res: *Response) anyerror!void;

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
        pub fn start(io: std.Io, instance: *Instance, config: anytype, reactor: *zio.Reactor) !void {
            const listen = cfg.ref.resolveIfRef(spec.listen, config.value);
            const buffers: ClientBuffers = cfg.ref.resolveIfRef(spec.buffers, config.value);
            const connectionPool: []Connection = cfg.ref.resolveIfRef(spec.connectionPool, config.value);
            try instance.init(.{
                .io = io,
                .listen = listen,
                .reactor = reactor,
                .buffers = buffers,
                .connectionPool = connectionPool,
            });
        }

        pub const Instance = struct {
            const Self = @This();

            pub const StartOpts = struct {
                io: std.Io,
                listen: []const u8,
                reactor: *zio.Reactor,
                buffers: ClientBuffers,
                connectionPool: []Connection,
            };

            io: std.Io,
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
                    .io = opts.io,
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
                        .req = .{ .connection = c },
                        .res = .{ .statusCode = .ok },
                        .resSerializer = .init(&c.res, c.writeBuffer),
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
            } || zio.FixedBufferPool.AllocError || zio.Reactor.AddSocketError || HandleReadError || std.Io.Writer.Error;

            fn acceptConnection(
                self: *Self,
                socket: zio.Socket,
                ip: std.Io.net.IpAddress,
            ) AcceptConnectionError!*Connection {
                var s = socket;
                errdefer s.deinit();
                const node = self.freeConnectionList.popFirst();
                var addr = [_]u8{0} ** 64;
                var writer = std.Io.Writer.fixed(&addr);
                try ip.format(&writer);
                if (node == null) {
                    log.warn("Connection limit reached. No empty slot for client {s}. Closing", .{writer.buffered()});
                    return error.ConnectionLimitReached;
                }
                errdefer self.freeConnectionList.prepend(node.?);
                const conn: *Connection = @fieldParentPtr("node", node.?);
                const readBuffer = try self.readBuffer.alloc();
                errdefer self.readBuffer.free(readBuffer);
                const writeBuffer = try self.writeBuffer.alloc();
                errdefer self.writeBuffer.free(writeBuffer);
                conn.socket = socket;
                conn.ip = ip;
                conn.readBuffer = readBuffer;
                conn.writeBuffer = writeBuffer;
                conn.req = .{ .connection = conn };
                conn.res = .{ .statusCode = .ok };
                conn.reqParser = .init;
                conn.resSerializer = .init(&conn.res, conn.writeBuffer);
                try self.reactor.addSocket(socket, &conn.handler);
                log.debug("Client accepted {s}", .{writer.buffered()});
                return conn;
            }

            fn closeConnection(self: *Self, conn: *Connection) void {
                {
                    var addr = [_]u8{0} ** 64;
                    var writer = std.Io.Writer.fixed(&addr);
                    conn.ip.format(&writer) catch {};
                    log.debug("Closing connection {s}, open={}", .{ writer.buffered(), conn.socket.isValid() });
                }
                if (!conn.socket.isValid()) return;
                self.reactor.removeSocket(conn.socket) catch |e| {
                    var addr = [_]u8{0} ** 64;
                    var writer = std.Io.Writer.fixed(&addr);
                    conn.ip.format(&writer) catch |ee| {
                        log.err("Failed to format client IP, err={}", .{ee});
                    };
                    log.err("Failed to remove socket for client {s}, err={}", .{ writer.buffered(), e });
                };
                conn.socket.deinit();
                self.readBuffer.free(conn.readBuffer);
                self.writeBuffer.free(conn.writeBuffer);
                self.freeConnectionList.prepend(&conn.node);
            }

            fn handleConnection(extra: ?*anyopaque, socket: zio.Socket, ip: std.Io.net.IpAddress) void {
                const self: *Self = @ptrCast(@alignCast(extra orelse return));
                const conn = self.acceptConnection(socket, ip) catch |e| {
                    var addr = [_]u8{0} ** 64;
                    var writer = std.Io.Writer.fixed(&addr);
                    ip.format(&writer) catch |ee| {
                        log.err("Failed to format client IP, err={}", .{ee});
                    };
                    log.err("Failed accept client {s}, err={}", .{ writer.buffered(), e });
                    return;
                };
                self.handleRead(conn) catch |e| {
                    var addr = [_]u8{0} ** 64;
                    var writer = std.Io.Writer.fixed(&addr);
                    ip.format(&writer) catch |ee| {
                        log.err("Failed to format client IP, err={}", .{ee});
                    };
                    log.err("Failed read client {s}, err={}", .{ writer.buffered(), e });
                    return;
                };
            }

            const HandleReadError = error{
                EndOfFile,
            } || RequestParser.UpdateError || zio.Socket.ReadError || HandleWriteError || zio.Reactor.WriteModeError;

            fn handleRead(self: *Self, conn: *Connection) HandleReadError!void {
                loop: while (true) {
                    const read = conn.socket.read(conn.readBuffer) catch |e| switch (e) {
                        error.WouldBlock => break :loop,
                        error.NotOpenForReading => return, // TODO Figure out why we even see this error
                        else => return e,
                    };
                    if (read == 0) return error.EndOfFile;
                    try conn.reqParser.update(&conn.req, conn.readBuffer[0..read]);
                    if (conn.reqParser.isDone()) {
                        try self.reactor.writeMode(conn.socket, &conn.handler);
                        // TODO Create context and call `io.concurrent(spec.handleRequest, .{ &conn.req, &conn.res })`
                        // TODO We need a way for the reactor to notify us when the future completes
                        const future = self.io.async(spec.handleRequest, .{ &conn.req, &conn.res });
                        errdefer future.cancel(self.io) catch |e| {
                            var addr = [_]u8{0} ** 64;
                            var writer = std.Io.Writer.fixed(&addr);
                            conn.ip.format(&writer) catch |ee| {
                                log.err("Failed to format client IP, err={}", .{ee});
                            };
                            log.err("Request handler failed for client {s}, err={}", .{ writer.buffered(), e });
                        };
                        // TODO Add future to reactor
                        // this will now be called after the reactor reports the future completed
                        // try self.handleWrite(conn);
                    }
                }
            }

            const HandleWriteError = std.Io.Reader.Error || zio.Socket.WriteError;

            fn handleWrite(self: *Self, conn: *Connection) HandleWriteError!void {
                loop: while (true) {
                    const reader: *std.Io.Reader = &conn.resSerializer.reader;
                    var end = false;
                    reader.fillMore() catch |e| switch (e) {
                        error.EndOfStream => end = true,
                        else => return e,
                    };
                    const written = conn.socket.write(reader.buffered()) catch |e| switch (e) {
                        error.WouldBlock => break :loop,
                        else => return e,
                    };
                    reader.toss(written);
                    if (end and reader.bufferedLen() == 0) {
                        self.closeConnection(conn);
                        break :loop;
                    }
                }
            }

            fn handleSocketEvent(extra: ?*anyopaque, event: zio.Reactor.Handler.Event) void {
                const conn: *Connection = @ptrCast(@alignCast(extra.?));
                const self: *Self = @ptrCast(@alignCast(conn.server));
                switch (event) {
                    .read => self.handleRead(conn) catch |e| {
                        var addr = [_]u8{0} ** 64;
                        var writer = std.Io.Writer.fixed(&addr);
                        conn.ip.format(&writer) catch |ee| {
                            log.err("Failed to format client IP, err={}", .{ee});
                        };
                        log.err(
                            "Handle read notification failed for client {s}. Closing, err={}",
                            .{ writer.buffered(), e },
                        );
                        self.closeConnection(conn);
                    },
                    .write => self.handleWrite(conn) catch |e| {
                        var addr = [_]u8{0} ** 64;
                        var writer = std.Io.Writer.fixed(&addr);
                        conn.ip.format(&writer) catch |ee| {
                            log.err("Failed to format client IP, err={}", .{ee});
                        };
                        log.err(
                            "Handle write notification failed for client {s}. Closing, err={}",
                            .{ writer.buffered(), e },
                        );
                        self.closeConnection(conn);
                    },
                    .hangup => self.closeConnection(conn),
                    .err => {
                        var addr = [_]u8{0} ** 64;
                        var writer = std.Io.Writer.fixed(&addr);
                        conn.ip.format(&writer) catch |ee| {
                            log.err("Failed to format client IP, err={}", .{ee});
                        };
                        log.err(
                            "Error notification received for client {s}. Closing",
                            .{writer.buffered()},
                        );
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
