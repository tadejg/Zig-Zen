pub const Server = @import("server.zig").Server;
pub const RequestUriParser = @import("request_uri_parser.zig");
pub const RequestParser = @import("request_parser.zig");
pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const server = struct {
    pub const ClientBuffers = @import("server.zig").ClientBuffers;
    pub const Connection = @import("connection.zig");

    pub const BUFF_LEN = 8 * 1024;
    pub const MAX_CONN = 128;
    var readBuff = [_]u8{0} ** (MAX_CONN * BUFF_LEN);
    var readBuffFreeStack = [_]u32{0} ** MAX_CONN;
    var writeBuff = [_]u8{0} ** (MAX_CONN * BUFF_LEN);
    var writeBuffFreeStack = [_]u32{0} ** MAX_CONN;
    var connectionPool = [_]Connection{undefined} ** MAX_CONN;
    const cfg = @import("../cfg/root.zig");
    pub const DefaultConfig = cfg.Config(struct {
        buffers: ClientBuffers,
        connectionPool: []Connection,
    });
    pub const defaultCfg = cfg.static(DefaultConfig, .{
        .buffers = .{
            .readBuffer = .{ .data = &readBuff, .freeStack = &readBuffFreeStack, .chunkSize = BUFF_LEN },
            .writeBuffer = .{ .data = &writeBuff, .freeStack = &writeBuffFreeStack, .chunkSize = BUFF_LEN },
        },
        .connectionPool = &connectionPool,
    });
};
pub const router = @import("router/root.zig");
pub const status = @import("status.zig");
