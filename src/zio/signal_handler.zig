const std = @import("std");

pub const Callback = *const fn () void;

var _io: std.Io = undefined;
var _ioGroup: *std.Io.Group = undefined;
var _callback: Callback = undefined;
var semaphore: std.Thread.Semaphore = .{};

pub const RegisterError = std.Io.ConcurrentError;

pub fn register(io: std.Io, ioGroup: *std.Io.Group, callback: Callback) RegisterError!void {
    _callback = callback;
    _io = io;
    _ioGroup = ioGroup;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    try _ioGroup.concurrent(io, run, .{});
}

fn run() void {
    semaphore.wait();
    _callback();
}

pub fn trigger() void {
    semaphore.post();
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    trigger();
}
