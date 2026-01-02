const std = @import("std");

const Self = @This();

/// When an event has data.ptr equal to this value, notify() has been called
pub const NOTIFY_SIGNAL_PTR = 0;

efd: std.posix.fd_t,
readyList: [128]std.os.linux.epoll_event = undefined,
notifySignal: std.posix.socket_t,

pub const InitError = std.posix.EpollCreateError || std.posix.EventFdError || AddFdError;

pub fn init() InitError!Self {
    const epollFd = try std.posix.epoll_create1(0);
    errdefer std.posix.close(epollFd);
    const eventFd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK);
    errdefer std.posix.close(eventFd);
    var self = Self{
        .efd = epollFd,
        .notifySignal = eventFd,
    };
    try self.addFd(eventFd, 0);
    return self;
}

pub fn deinit(self: *Self) void {
    std.posix.close(self.notifySignal);
    std.posix.close(self.efd);
}

pub const NotifyError = std.posix.WriteError;

pub fn notify(self: *Self) NotifyError!void {
    const foo: u64 = 1;
    _ = try std.posix.write(self.notifySignal, std.mem.asBytes(&foo));
}

pub fn wait(self: *Self, timeout: i32) []std.os.linux.epoll_event {
    const count = std.posix.epoll_wait(self.efd, &self.readyList, timeout);
    return self.readyList[0..count];
}

pub const AddFdError = std.posix.EpollCtlError;

pub fn addFd(self: *Self, socket: std.posix.socket_t, ptr: usize) AddFdError!void {
    var event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
        .data = .{ .ptr = ptr },
    };
    try std.posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_ADD, socket, &event);
}

pub const RemoveFdError = std.posix.EpollCtlError;

pub fn removeFd(self: *Self, socket: std.posix.socket_t) RemoveFdError!void {
    try std.posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_DEL, socket, null);
}

pub const ReadModeError = std.posix.EpollCtlError;

pub fn readMode(self: *Self, socket: std.posix.socket_t, ptr: usize) ReadModeError!void {
    var event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
        .data = .{ .ptr = ptr },
    };
    try std.posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_MOD, socket, &event);
}

pub const WriteModeError = std.posix.EpollCtlError;

pub fn writeMode(self: *Self, socket: std.posix.socket_t, ptr: usize) WriteModeError!void {
    var event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
        .data = .{ .ptr = ptr },
    };
    try std.posix.epoll_ctl(self.efd, std.os.linux.EPOLL.CTL_MOD, socket, &event);
}
