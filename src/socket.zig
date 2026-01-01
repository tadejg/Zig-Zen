const std = @import("std");

const net = std.Io.net;

const Self = @This();

fd: std.posix.socket_t,

pub fn init() std.posix.SocketError!Self {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    return .{ .fd = fd };
}

pub fn deinit(self: *Self) void {
    std.posix.close(self.fd);
}

pub const BindError = std.posix.BindError;

pub fn bind(self: *Self, ip: *const net.IpAddress) BindError!void {
    var in: std.posix.sockaddr.in = undefined;
    var in6: std.posix.sockaddr.in6 = undefined;
    var sockaddr: *std.posix.sockaddr = undefined;
    switch (ip.*) {
        .ip4 => |v| {
            in = std.posix.sockaddr.in{
                .port = v.port,
                .addr = std.mem.bytesToValue(u32, &v.bytes),
            };
            sockaddr = @ptrCast(@alignCast(&in));
        },
        .ip6 => |v| {
            in6 = std.posix.sockaddr.in6{
                .addr = v.bytes,
                .port = v.port,
                .flowinfo = v.flow,
                .scope_id = v.interface.index,
            };
            sockaddr = @ptrCast(@alignCast(&in6));
        },
    }
    try std.posix.bind(self.fd, sockaddr, @sizeOf(std.posix.sockaddr));
}
