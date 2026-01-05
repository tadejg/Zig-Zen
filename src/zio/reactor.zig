//! Servers and clients can register their sockets with the I/O reactor to get notified when an event occurs. If
//! concurrency is required, a separate reactor instance should be created for each thread and servers that wish to
//! utilize concurrency should open and register a new listening socket for each reactor instance with the SO_REUSEPORT
//! socket option set
const std = @import("std");
const Socket = @import("socket.zig");
const Epoll = @import("epoll.zig");

const Self = @This();

pub const Handler = struct {
    extra: ?*anyopaque,
    callback: Callback,

    pub const Callback = *const fn (extra: ?*anyopaque, event: Event) void;

    pub const Event = enum {
        read,
        write,
        hangup,
        err,
    };
};

epoll: Epoll,

pub const InitError = Epoll.InitError;

pub fn init() InitError!Self {
    var epoll = try Epoll.init();
    errdefer epoll.deinit();
    return .{
        .epoll = epoll,
    };
}

pub fn deinit(self: *Self) void {
    self.epoll.notify() catch {
        // TODO Log
    };
    self.epoll.deinit();
}

pub const AddSocketError = Epoll.AddFdError;

/// Handler ptr must remain stable until removeSocket() is called
pub fn addSocket(self: *Self, socket: Socket, handler: *Handler) AddSocketError!void {
    try self.epoll.addFd(socket.fd, @intFromPtr(handler));
}

pub const RemoveSocketError = Epoll.RemoveFdError;

pub fn removeSocket(self: *Self, socket: Socket) RemoveSocketError!void {
    try self.epoll.removeFd(socket.fd);
}

pub fn run(self: *Self) void {
    var running = true;
    while (running) {
        const events = self.epoll.wait(-1);
        for (events) |event| {
            if (event.data.ptr == Epoll.NOTIFY_SIGNAL_PTR) {
                running = false;
            } else {
                const handler: *Handler = @ptrFromInt(event.data.ptr);
                if ((event.events & std.os.linux.EPOLL.IN) > 0) {
                    handler.callback(handler.extra, .read);
                }
                if ((event.events & std.os.linux.EPOLL.OUT) > 0) {
                    handler.callback(handler.extra, .write);
                }
                if ((event.events & std.os.linux.EPOLL.HUP) > 0) {
                    handler.callback(handler.extra, .hangup);
                }
                if ((event.events & std.os.linux.EPOLL.ERR) > 0) {
                    handler.callback(handler.extra, .err);
                }
            }
        }
    }
    std.log.info("Reactor shutdown", .{});
}
