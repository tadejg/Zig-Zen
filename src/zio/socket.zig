//! Must be stateless, apart from the socket fd
const std = @import("std");

const net = std.Io.net;

const Self = @This();

fd: std.posix.socket_t,

pub const InitError = std.posix.SocketError;

pub fn init(family: std.meta.Tag(std.Io.net.IpAddress)) InitError!Self {
    const f: u32 = switch (family) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    };
    const fd = try std.posix.socket(f, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
    return .{ .fd = fd };
}

pub fn wrap(fd: std.posix.socket_t) Self {
    return .{ .fd = fd };
}

pub fn invalid() Self {
    return .{ .fd = -1 };
}

pub fn deinit(self: *Self) void {
    if (self.isValid()) std.posix.close(self.fd);
}

pub inline fn isValid(self: *Self) bool {
    return self.fd >= 0;
}

pub const BindError = InitError || std.posix.BindError || std.posix.SetSockOptError;

pub fn bind(self: *Self, ip: *const net.IpAddress) BindError!void {
    var in: std.posix.sockaddr.in = undefined;
    var in6: std.posix.sockaddr.in6 = undefined;
    var sockaddr: *std.posix.sockaddr = undefined;
    switch (ip.*) {
        .ip4 => |v| {
            in = std.posix.sockaddr.in{
                .port = std.mem.nativeToBig(u16, v.port),
                .addr = std.mem.bytesToValue(u32, &v.bytes),
            };
            sockaddr = @ptrCast(@alignCast(&in));
        },
        .ip6 => |v| {
            in6 = std.posix.sockaddr.in6{
                .addr = v.bytes,
                .port = std.mem.nativeToBig(u16, v.port),
                .flowinfo = v.flow,
                .scope_id = v.interface.index,
            };
            sockaddr = @ptrCast(@alignCast(&in6));
        },
    }
    if (!self.isValid()) self.* = try init(ip.*);
    try std.posix.setsockopt(
        self.fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try std.posix.setsockopt(
        self.fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEPORT,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try std.posix.bind(self.fd, sockaddr, @sizeOf(std.posix.sockaddr));
}

pub const ListenError = std.posix.ListenError;

pub fn listen(self: *Self, backlog: u31) ListenError!void {
    try std.posix.listen(self.fd, backlog);
}

pub const AcceptError = std.posix.AcceptError;

pub fn accept(self: *Self, ip: *std.Io.net.IpAddress) AcceptError!Self {
    var addr: std.posix.sockaddr.storage = undefined;
    var addrSize: u32 = @sizeOf(@TypeOf(addr));
    const clientSocket = try std.posix.accept(
        self.fd,
        @ptrCast(@alignCast(&addr)),
        &addrSize,
        std.posix.SOCK.NONBLOCK,
    );
    std.debug.assert(addrSize <= @sizeOf(@TypeOf(addr)));
    switch (addrSize) {
        @sizeOf(std.posix.sockaddr.in) => {
            const in: *std.posix.sockaddr.in = @ptrCast(@alignCast(&addr));
            std.debug.assert(in.family == std.posix.AF.INET);
            ip.* = std.Io.net.IpAddress{ .ip4 = .{
                .bytes = std.mem.toBytes(in.addr),
                .port = std.mem.bigToNative(u16, in.port),
            } };
        },
        @sizeOf(std.posix.sockaddr.in6) => {
            const in: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&addr));
            std.debug.assert(in.family == std.posix.AF.INET6);
            ip.* = std.Io.net.IpAddress{ .ip6 = .{
                .bytes = in.addr,
                .interface = .{ .index = in.scope_id },
                .flow = in.flowinfo,
                .port = std.mem.bigToNative(u16, in.port),
            } };
        },
        else => unreachable,
    }
    return wrap(clientSocket);
}

pub const ReadError = std.posix.ReadError;

pub fn read(self: *Self, buff: []u8) ReadError!usize {
    return std.posix.read(self.fd, buff);
}

pub const WriteError = std.posix.WriteError;

pub fn write(self: *Self, buff: []u8) WriteError!usize {
    return std.posix.write(self.fd, buff);
}
